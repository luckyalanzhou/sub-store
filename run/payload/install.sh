#!/bin/sh
set -eu

PACKAGE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$PACKAGE_DIR/lib/package-manager.sh"
. "$PACKAGE_DIR/lib/install-log.sh"
. "$PACKAGE_DIR/lib/install-lock.sh"
LOG=/tmp/sub-store-run-install.log
LOG_MAX_BYTES=1048576
INSTALL_STEP="准备安装"
INSTALL_OK=0
PLUGIN_BACKUP_DIR=""
PLUGIN_UPDATE_ACTIVE=0
PLUGIN_TARGET_PREFIX=""
FULL_INSTALL_ACTIVE=0
SERVICE_WAS_ENABLED=0
INSTALL_TRANSACTION_DIR=/etc/sub-store/install-transaction
initialize_install_log "$LOG" || {
    echo "Could not safely initialize the installer log at $LOG." >&2
    exit 1
}
PACKAGE_VERSION=dev
if [ -r "$PACKAGE_DIR/build-version" ]; then
    PACKAGE_VERSION="$(cat "$PACKAGE_DIR/build-version")"
fi

say() {
    printf '%s\n' "$*" | tee -a "$LOG"
    log_size="$(wc -c < "$LOG" | tr -d '[:space:]')"
    if [ -n "$log_size" ] && [ "$log_size" -gt "$LOG_MAX_BYTES" ]; then
        trimmed_log="$(umask 077; mktemp /tmp/sub-store-run-install.XXXXXX)"
        tail -c "$LOG_MAX_BYTES" "$LOG" > "$trimmed_log"
        mv "$trimmed_log" "$LOG"
    fi
}

fail() {
    say "ERROR: $*"
    exit 1
}

step() {
    INSTALL_STEP="$2"
    say "[$1/6] $INSTALL_STEP"
}

plugin_target_path() {
    printf '%s/%s\n' "${PLUGIN_TARGET_PREFIX%/}" "$1"
}

is_versioned_luci_view() {
    printf '%s\n' "$1" | grep -Eq '^manage_[0-9]+_[0-9]+_[0-9]+\.js$'
}

cleanup_stale_luci_views() {
    view_dir="$(plugin_target_path www/luci-static/resources/view/sub-store)"
    current_view="manage_$(printf '%s' "$PACKAGE_VERSION" | tr '.' '_').js"
    legacy_view="$view_dir/manage.js"
    [ ! -f "$legacy_view" ] || rm -f "$legacy_view" || return 1
    for view_path in "$view_dir"/manage_*.js; do
        [ -f "$view_path" ] || continue
        view_name="${view_path##*/}"
        [ "$view_name" = "$current_view" ] && continue
        if is_versioned_luci_view "$view_name"; then
            rm -f "$view_path" || return 1
        fi
    done
}

refresh_luci_cache() {
    rm -f /tmp/luci-indexcache*
    rm -rf /tmp/luci-modulecache
    [ ! -x /etc/init.d/rpcd ] || /etc/init.d/rpcd reload >/dev/null 2>&1 || true
}

rollback_plugin_update() {
    [ "$PLUGIN_UPDATE_ACTIVE" = "1" ] || return 0
    restore_failed=0
    while IFS=' ' read -r prior_state relative_path; do
        [ -n "$relative_path" ] || continue
        target_path="$(plugin_target_path "$relative_path")"
        case "$prior_state" in
            present)
                mkdir -p "$(dirname "$target_path")" || restore_failed=1
                cp -p "$PLUGIN_BACKUP_DIR/files/$relative_path" "$target_path" 2>/dev/null || restore_failed=1
                ;;
            absent)
                rm -f "$target_path" || restore_failed=1
                ;;
        esac
    done < "$PLUGIN_BACKUP_DIR/states"
    if [ "$restore_failed" = "1" ]; then
        say "ERROR: LuCI 回滚未能完整完成；旧文件备份保留在 $PLUGIN_BACKUP_DIR。"
        return 1
    fi
    PLUGIN_UPDATE_ACTIVE=0
    rm -rf "$PLUGIN_BACKUP_DIR"
    if [ "${FULL_INSTALL_ACTIVE:-0}" = "1" ]; then
        rm -rf "$INSTALL_TRANSACTION_DIR"
    fi
    PLUGIN_BACKUP_DIR=""
    refresh_luci_cache
    say "LuCI 插件文件已恢复到更新前状态。"
}

prepare_plugin_rollback() {
    if [ "${FULL_INSTALL_ACTIVE:-0}" = "1" ]; then
        [ ! -e "$INSTALL_TRANSACTION_DIR" ] && [ ! -L "$INSTALL_TRANSACTION_DIR" ] ||
            fail "An unfinished installer transaction exists; recover it before installing again."
        (umask 077; mkdir "$INSTALL_TRANSACTION_DIR") ||
            fail "Cannot create persistent installer recovery storage."
        chmod 700 "$INSTALL_TRANSACTION_DIR"
        printf '%s\n' preparing > "$INSTALL_TRANSACTION_DIR/state"
        printf '%s-%s\n' "$(date +%s)" "$$" > "$INSTALL_TRANSACTION_DIR/new-container-token"
        chmod 600 "$INSTALL_TRANSACTION_DIR/state" "$INSTALL_TRANSACTION_DIR/new-container-token"
        mkdir "$INSTALL_TRANSACTION_DIR/plugin" ||
            fail "Cannot create persistent installer recovery storage."
        PLUGIN_BACKUP_DIR="$INSTALL_TRANSACTION_DIR/plugin"
    else
        PLUGIN_BACKUP_DIR="$(umask 077; mktemp -d /tmp/sub-store-plugin-rollback.XXXXXX)"
    fi
    [ -n "$PLUGIN_BACKUP_DIR" ] && [ -d "$PLUGIN_BACKUP_DIR" ] || fail "Cannot create a temporary rollback directory."
    : > "$PLUGIN_BACKUP_DIR/states"
    (cd "$PACKAGE_DIR/root" && find . -type f -print) > "$PLUGIN_BACKUP_DIR/manifest" ||
        fail "Cannot list plugin package files for rollback protection."
    printf '%s\n' \
        ./etc/config/sub-store \
        ./etc/sub-store/installed \
        ./etc/sub-store/version \
        ./usr/lib/lua/luci/controller/sub_store.lua \
        ./usr/lib/lua/luci/model/cbi/sub_store.lua \
        ./usr/lib/sub-store/check-update >> "$PLUGIN_BACKUP_DIR/manifest"
    existing_view_dir="$(plugin_target_path www/luci-static/resources/view/sub-store)"
    for existing_view in "$existing_view_dir"/manage_*.js; do
        [ -f "$existing_view" ] || continue
        existing_view_name="${existing_view##*/}"
        if is_versioned_luci_view "$existing_view_name"; then
            printf './www/luci-static/resources/view/sub-store/%s\n' "$existing_view_name" \
                >> "$PLUGIN_BACKUP_DIR/manifest"
        fi
    done
    sort -u "$PLUGIN_BACKUP_DIR/manifest" -o "$PLUGIN_BACKUP_DIR/manifest"
    while IFS= read -r package_path; do
        relative_path="${package_path#./}"
        target_path="$(plugin_target_path "$relative_path")"
        if [ -f "$target_path" ]; then
            mkdir -p "$PLUGIN_BACKUP_DIR/files/$(dirname "$relative_path")" ||
                fail "Cannot prepare rollback storage for $relative_path."
            cp -p "$target_path" "$PLUGIN_BACKUP_DIR/files/$relative_path" ||
                fail "Cannot back up the current $relative_path before updating."
            printf 'present %s\n' "$relative_path" >> "$PLUGIN_BACKUP_DIR/states"
        else
            printf 'absent %s\n' "$relative_path" >> "$PLUGIN_BACKUP_DIR/states"
        fi
    done < "$PLUGIN_BACKUP_DIR/manifest"
    if [ "${FULL_INSTALL_ACTIVE:-0}" = "1" ]; then
        chmod 600 "$PLUGIN_BACKUP_DIR/states" "$PLUGIN_BACKUP_DIR/manifest"
        printf '%s\n' prepared > "$INSTALL_TRANSACTION_DIR/state"
        chmod 600 "$INSTALL_TRANSACTION_DIR/state"
    fi
    PLUGIN_UPDATE_ACTIVE=1
}

install_recovery_hook() {
    mkdir -p /usr/lib/sub-store /etc/rc.d
    cp "$PACKAGE_DIR/root/usr/lib/sub-store/install-recovery" /usr/lib/sub-store/install-recovery ||
        fail "Cannot install persistent recovery support."
    cp "$PACKAGE_DIR/root/etc/init.d/sub-store-install-recovery" /etc/init.d/sub-store-install-recovery ||
        fail "Cannot install the recovery startup hook."
    chmod 755 /usr/lib/sub-store/install-recovery /etc/init.d/sub-store-install-recovery
    ln -sf ../init.d/sub-store-install-recovery /etc/rc.d/S99sub-store-install-recovery
}

commit_plugin_update() {
    if [ "${FULL_INSTALL_ACTIVE:-0}" = "1" ] && [ -d "$INSTALL_TRANSACTION_DIR" ] &&
        [ "$(cat "$INSTALL_TRANSACTION_DIR/state" 2>/dev/null || true)" = prepared ]; then
        printf '%s\n' committed > "$INSTALL_TRANSACTION_DIR/state.tmp.$$"
        chmod 600 "$INSTALL_TRANSACTION_DIR/state.tmp.$$"
        mv -f "$INSTALL_TRANSACTION_DIR/state.tmp.$$" "$INSTALL_TRANSACTION_DIR/state"
    fi
    if ! rm -rf "$PLUGIN_BACKUP_DIR"; then
        say "WARNING: Could not remove the temporary LuCI rollback files." || true
    fi
    if [ "${FULL_INSTALL_ACTIVE:-0}" = "1" ]; then
        rm -rf "$INSTALL_TRANSACTION_DIR"
    fi
    PLUGIN_BACKUP_DIR=""
    PLUGIN_UPDATE_ACTIVE=0
}

finish() {
    result=$?
    if [ "$INSTALL_OK" != "1" ]; then
        if [ "$FULL_INSTALL_ACTIVE" = "1" ] && [ "$SERVICE_WAS_ENABLED" = "0" ] && [ -x /etc/init.d/sub-store ]; then
            /etc/init.d/sub-store disable >/dev/null 2>&1 || true
        fi
        if [ "$FULL_INSTALL_ACTIVE" = "1" ] && [ -x /usr/lib/sub-store/install-recovery ] &&
            [ -d "$INSTALL_TRANSACTION_DIR" ]; then
            if SUB_STORE_INSTALL_RECOVERY_FORCE=1 /usr/lib/sub-store/install-recovery; then
                PLUGIN_UPDATE_ACTIVE=0
                PLUGIN_BACKUP_DIR=""
                refresh_luci_cache
            else
                say "ERROR: Installer recovery data was retained at $INSTALL_TRANSACTION_DIR for the next startup."
            fi
        else
            rollback_plugin_update || true
        fi
    fi
    release_install_operation_lock || true
    if [ "$INSTALL_OK" != "1" ]; then
        say "安装未完成，阶段：$INSTALL_STEP；退出码：$result"
        say "安装阶段日志：$LOG。修复原因后可以重新上传安装包重试。"
    fi
}
trap finish EXIT
step 1 "检查系统与安装依赖"
[ "$(id -u)" = "0" ] || fail "Run the .run installer as root."
[ -d /etc ] || fail "Cannot find the system configuration directory."
PLUGIN_ONLY="${SUB_STORE_PLUGIN_ONLY:-0}"

if [ -r /etc/openwrt_release ]; then
    . /etc/openwrt_release
    case "${DISTRIB_RELEASE:-}" in
        24.10*|25.12*) ;;
        *) say "WARNING: intended for iStoreOS 24.10.x and 25.12.x; detected ${DISTRIB_RELEASE:-unknown}. Continuing with best-effort compatibility." ;;
    esac
fi

if ! detect_package_manager; then
    fail "This installer requires iStoreOS/OpenWrt with opkg or apk."
fi

acquire_install_operation_lock || fail "Another sub-store operation may be running; retry after it finishes."

if [ -x /usr/lib/sub-store/install-recovery ]; then
    SUB_STORE_INSTALL_RECOVERY_FORCE=1 /usr/lib/sub-store/install-recovery ||
        fail "An earlier installer transaction could not be recovered."
fi

if [ "$PLUGIN_ONLY" = "1" ]; then
    [ -f /www/luci-static/resources/form.js ] || fail "LuCI is unavailable; reinstall the full package."
    command -v lua >/dev/null 2>&1 || fail "Lua is unavailable; reinstall the full package."
    lua -e 'require "luci.sys"; require "luci.jsonc"' >/dev/null 2>&1 ||
        fail "LuCI status dependencies are unavailable; reinstall the full package."
else
    if ! command -v jsonfilter >/dev/null 2>&1; then
        say "Installing required jsonfilter package..."
        package_manager_update || fail "Could not refresh package feeds to install jsonfilter."
        package_manager_install jsonfilter || fail "Could not install jsonfilter from the configured package feeds."
        command -v jsonfilter >/dev/null 2>&1 || fail "jsonfilter is still unavailable after package installation."
    fi

    if ! command -v docker >/dev/null 2>&1; then
        say "Installing Docker from the configured $PACKAGE_MANAGER feeds..."
        package_manager_update || fail "Could not refresh package feeds to install Docker."
        package_manager_install dockerd docker || fail "Could not install Docker from the configured package feeds."
    fi

    command -v docker >/dev/null 2>&1 || fail "Docker CLI is still unavailable after package installation."
    [ -x /etc/init.d/dockerd ] || fail "The dockerd init service is missing."

    if [ ! -f /www/luci-static/resources/form.js ] || ! command -v lua >/dev/null 2>&1 ||
        ! lua -e 'require "luci.sys"; require "luci.jsonc"' >/dev/null 2>&1 ||
        ! command -v curl >/dev/null 2>&1 ||
        ! package_is_installed rpcd-mod-file; then
        say "Installing native LuCI and RPC dependencies..."
        package_manager_update || fail "Could not refresh package feeds to install LuCI dependencies."
        package_manager_install luci-base lua luci-lib-base luci-lib-jsonc rpcd-mod-file curl ||
            fail "Could not install LuCI dependencies from the configured package feeds."
    fi
    [ -f /www/luci-static/resources/form.js ] || fail "LuCI JavaScript form support is unavailable."
    lua -e 'require "luci.sys"; require "luci.jsonc"' >/dev/null 2>&1 || fail "LuCI status dependencies are unavailable."
fi

if [ "$PLUGIN_ONLY" = "1" ]; then
    step 2 "只更新 LuCI 插件"
    prepare_plugin_rollback

    RUNNING_DIR="$PLUGIN_BACKUP_DIR/running"
    mkdir -p "$RUNNING_DIR/usr/bin" "$RUNNING_DIR/usr/lib/sub-store"
    for active_file in \
        usr/bin/sub-storectl \
        usr/lib/sub-store/export-data \
        usr/lib/sub-store/registry-image.sh \
        usr/lib/sub-store/job.sh \
        usr/lib/sub-store/plugin-update; do
        active_path="$(plugin_target_path "$active_file")"
        if [ -f "$active_path" ]; then
            mv "$active_path" "$RUNNING_DIR/$active_file"
        fi
    done
    PLUGIN_DEST="${PLUGIN_TARGET_PREFIX:-/}"
    (umask 022; cp -R "$PACKAGE_DIR/root/." "$PLUGIN_DEST") || fail "Cannot copy updated LuCI plugin files."
    cleanup_stale_luci_views || fail "Cannot remove outdated LuCI view files."
    . /usr/lib/sub-store/permissions.sh
    sub_store_public_permissions "" || fail "Cannot set LuCI public asset permissions."
    chmod 755 /usr/bin/sub-storectl /usr/lib/sub-store/export-data /usr/lib/sub-store/job.sh /usr/lib/sub-store/status \
        /usr/lib/sub-store/plugin-update /etc/init.d/sub-store
    chmod 644 /usr/lib/sub-store/registry-image.sh
    chmod 644 /usr/lib/sub-store/app-version.js
    rm -f /usr/lib/lua/luci/controller/sub_store.lua /usr/lib/lua/luci/model/cbi/sub_store.lua \
        /usr/lib/sub-store/check-update
    if command -v uci >/dev/null 2>&1 && ! uci -q get sub-store.main.backend_lan_access >/dev/null 2>&1; then
        BACKEND_LAN_DEFAULT=0
        if command -v docker >/dev/null 2>&1 && docker inspect sub-store >/dev/null 2>&1; then
            CURRENT_MERGE="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' sub-store 2>/dev/null \
                | sed -n 's/^SUB_STORE_BACKEND_MERGE=//p' | head -n 1)"
            CURRENT_BACKEND_HOST="$(docker inspect -f '{{with (index .NetworkSettings.Ports "3000/tcp")}}{{(index . 0).HostIp}}{{end}}' sub-store 2>/dev/null || true)"
            if [ -z "$CURRENT_MERGE" ]; then
                case "$CURRENT_BACKEND_HOST" in 127.0.0.1|::1) ;; *) BACKEND_LAN_DEFAULT=1 ;; esac
            fi
        fi
        uci set "sub-store.main.backend_lan_access=$BACKEND_LAN_DEFAULT"
        uci commit sub-store
        chmod 600 /etc/config/sub-store
    fi
    mkdir -p /etc/sub-store
    printf '%s\n' "$PACKAGE_VERSION" >/etc/sub-store/version
    chmod 644 /etc/sub-store/version
    rm -f /tmp/luci-indexcache*
    rm -rf /tmp/luci-modulecache
    [ ! -x /etc/init.d/rpcd ] || /etc/init.d/rpcd reload
    say "LuCI plugin updated to $PACKAGE_VERSION. The Docker image, container, and data were not changed."
    commit_plugin_update
    INSTALL_OK=1
    exit 0
fi

step 2 "启动并检查 Docker"
/etc/init.d/dockerd enable
/etc/init.d/dockerd start
n=0
until docker info >/dev/null 2>&1; do
    n=$((n + 1))
    [ "$n" -lt 31 ] || fail "Docker daemon did not become ready."
    sleep 2
done

say "Docker 数据根目录：$(docker info --format '{{.DockerRootDir}}')"
step 3 "识别已有部署"
EXISTING=0
OLD_IMAGE=""
OLD_API_PATH=""
OLD_FRONTEND_PORT=""
OLD_BACKEND_PORT=""
OLD_BACKEND_HOST=""
OLD_MERGE=""
if docker inspect sub-store >/dev/null 2>&1; then
    EXISTING=1
    OLD_IMAGE="$(docker inspect -f '{{.Config.Image}}' sub-store)"
    case "$OLD_IMAGE" in
        xream/sub-store|xream/sub-store:*|xream/sub-store@sha256:*|\
        docker.io/xream/sub-store|docker.io/xream/sub-store:*|docker.io/xream/sub-store@sha256:*) ;;
        *) fail "A different container already uses the name sub-store: $OLD_IMAGE" ;;
    esac
    OLD_API_PATH="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' sub-store \
        | sed -n 's/^SUB_STORE_FRONTEND_BACKEND_PATH=//p' | head -n 1)"
    OLD_API_PATH="${OLD_API_PATH#/}"
    OLD_API_PATH="${OLD_API_PATH%/}"
    OLD_FRONTEND_PORT="$(docker port sub-store 3001/tcp 2>/dev/null | awk -F: 'NR == 1 {print $NF}')"
    OLD_BACKEND_PORT="$(docker port sub-store 3000/tcp 2>/dev/null | awk -F: 'NR == 1 {print $NF}')"
    OLD_BACKEND_HOST="$(docker inspect -f '{{with (index .NetworkSettings.Ports "3000/tcp")}}{{(index . 0).HostIp}}{{end}}' sub-store 2>/dev/null || true)"
    OLD_MERGE="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' sub-store \
        | sed -n 's/^SUB_STORE_BACKEND_MERGE=//p' | head -n 1)"
    if [ -n "$OLD_MERGE" ]; then
        [ -z "$OLD_BACKEND_PORT" ] || OLD_FRONTEND_PORT="$OLD_BACKEND_PORT"
        OLD_BACKEND_PORT=""
    fi

    if docker inspect sub-store-previous >/dev/null 2>&1; then
        fail "Both sub-store and sub-store-previous already exist; resolve the previous migration before installing."
    fi
fi

step 4 "安装管理界面并准备配置"
[ -e /etc/rc.d/S99sub-store ] && SERVICE_WAS_ENABLED=1
FULL_INSTALL_ACTIVE=1
prepare_plugin_rollback
install_recovery_hook
(umask 022; cp -R "$PACKAGE_DIR/root/." /)
cleanup_stale_luci_views || fail "Cannot remove outdated LuCI view files."
. /usr/lib/sub-store/permissions.sh
sub_store_public_permissions "" || fail "Cannot set LuCI public asset permissions."
chmod 755 /usr/bin/sub-storectl /usr/lib/sub-store/install-recovery /etc/init.d/sub-store-install-recovery \
    /usr/lib/sub-store/export-data /usr/lib/sub-store/job.sh /usr/lib/sub-store/status \
    /usr/lib/sub-store/plugin-update /etc/init.d/sub-store
chmod 644 /usr/lib/sub-store/registry-image.sh
chmod 644 /usr/lib/sub-store/app-version.js
# Remove only the obsolete files shipped by this package.
rm -f /usr/lib/lua/luci/controller/sub_store.lua /usr/lib/lua/luci/model/cbi/sub_store.lua /usr/lib/sub-store/check-update
rm -f /tmp/luci-indexcache*
rm -rf /tmp/luci-modulecache

mkdir -p /etc/config
mkdir -p /etc/sub-store
touch /etc/config/sub-store

if ! uci -q get sub-store.main >/dev/null 2>&1; then
    uci set sub-store.main=settings
fi

initialize_port() {
    port_key="$1"
    port_default="$2"
    port_candidate="$3"
    if uci -q get "sub-store.main.$port_key" >/dev/null 2>&1; then
        return 0
    fi
    case "$port_candidate" in
        ''|*[!0-9]*) port_candidate="$port_default" ;;
        *)
            if [ "$port_candidate" -lt 1 ] || [ "$port_candidate" -gt 65535 ]; then
                port_candidate="$port_default"
            fi
            ;;
    esac
    uci set "sub-store.main.$port_key=$port_candidate"
}

LEGACY_PORT="$(uci -q get sub-store.main.port 2>/dev/null || true)"
[ -z "$LEGACY_PORT" ] || OLD_FRONTEND_PORT="$LEGACY_PORT"
initialize_port frontend_port 3001 "$OLD_FRONTEND_PORT"
BACKEND_DEFAULT=3000
if [ "$(uci -q get sub-store.main.frontend_port)" = "3000" ]; then
    BACKEND_DEFAULT=3002
fi
initialize_port backend_port "$BACKEND_DEFAULT" "$OLD_BACKEND_PORT"
if ! uci -q get sub-store.main.backend_lan_access >/dev/null 2>&1; then
    BACKEND_LAN_DEFAULT=0
    if [ "$EXISTING" = "1" ] && [ -z "$OLD_MERGE" ]; then
        case "$OLD_BACKEND_HOST" in 127.0.0.1|::1) ;; *) BACKEND_LAN_DEFAULT=1 ;; esac
    fi
    uci set "sub-store.main.backend_lan_access=$BACKEND_LAN_DEFAULT"
fi
uci -q get sub-store.main.sync_cron >/dev/null 2>&1 || uci set sub-store.main.sync_cron='55 23 * * *'
uci -q delete sub-store.main.log_max_size_mb >/dev/null 2>&1 || true
uci -q delete sub-store.main.log_max_files >/dev/null 2>&1 || true

if [ "$EXISTING" = "1" ] && [ ! -f /etc/sub-store/installed ]; then
    case "$OLD_API_PATH" in
        *[!0123456789abcdefABCDEF]*|'') ;;
        *)
            if [ "${#OLD_API_PATH}" -eq 48 ]; then
                uci set "sub-store.main.api_path=$OLD_API_PATH"
            fi
            ;;
    esac
fi

if ! uci -q get sub-store.main.api_path >/dev/null 2>&1; then
    API_PATH="$(dd if=/dev/urandom bs=2048 count=1 2>/dev/null \
        | LC_ALL=C tr -dc '0123456789abcdef' \
        | cut -c1-48)"
    [ "${#API_PATH}" -eq 48 ] || fail "Could not generate an API path."
    uci set "sub-store.main.api_path=$API_PATH"
fi

uci commit sub-store
chmod 600 /etc/config/sub-store
/usr/bin/sub-storectl render

step 5 "部署官方镜像、启动容器并检查服务"
MANAGED_UPGRADE=0
if [ "$EXISTING" = "1" ] && [ -f /etc/sub-store/installed ]; then
    MANAGED_UPGRADE=1
    say "Updating the managed sub-store container..."
fi

if [ "$EXISTING" != "1" ]; then
    say "首次安装，联网拉取官方最新镜像..."
    /usr/bin/sub-storectl pull || fail "Could not pull the official image; installation was stopped before deploying the container."
    uci set sub-store.main.image_ref='xream/sub-store:latest'
    uci commit sub-store
    chmod 600 /etc/config/sub-store
fi

if [ "$MANAGED_UPGRADE" = "1" ]; then
    if ! /etc/init.d/sub-store enable || ! /usr/bin/sub-storectl install-deploy update "$PACKAGE_VERSION"; then
        fail "sub-store update failed; the previous container and installer state were restored when possible."
    fi
elif [ "$EXISTING" = "1" ]; then
    if ! /etc/init.d/sub-store enable || ! /usr/bin/sub-storectl install-deploy restart "$PACKAGE_VERSION"; then
        fail "Existing sub-store migration failed; the previous container and installer state were restored when possible."
    fi
elif [ -n "$(uci -q get sub-store.main.data_dir 2>/dev/null || true)" ]; then
    LEGACY_DATA_DIR="$(uci -q get sub-store.main.data_dir)"
    say "Importing legacy data into the Docker-managed volume..."
    /usr/bin/sub-storectl import-legacy "$LEGACY_DATA_DIR"
    uci -q delete sub-store.main.data_dir >/dev/null 2>&1 || true
    uci commit sub-store
    if /etc/init.d/sub-store enable && /etc/init.d/sub-store start; then
        touch /etc/sub-store/installed
        chmod 600 /etc/sub-store/installed
    else
        fail "sub-store failed to start after importing legacy data."
    fi
elif /etc/init.d/sub-store enable && /etc/init.d/sub-store start; then
    touch /etc/sub-store/installed
    chmod 600 /etc/sub-store/installed
else
    say "New deployment failed."
    exit 1
fi

if [ "$EXISTING" = "1" ]; then
    commit_plugin_update
    FULL_INSTALL_ACTIVE=0
fi

if [ "$EXISTING" != "1" ]; then
    container_status="$(/usr/bin/sub-storectl status 2>/dev/null || true)"
    [ "$container_status" = "running" ] ||
        fail "sub-store did not start successfully (container status: ${container_status:-unknown})."
fi

if [ "$EXISTING" != "1" ]; then
    uci -q delete sub-store.main.data_dir >/dev/null 2>&1 || true
    uci -q delete sub-store.main.port >/dev/null 2>&1 || true
    uci commit sub-store
    chmod 600 /etc/config/sub-store
    printf '%s\n' "$PACKAGE_VERSION" >/etc/sub-store/version
    chmod 644 /etc/sub-store/version
fi

# The container, UCI settings, plugin files, and package version now describe
# the same successful installation.
if [ "$EXISTING" != "1" ]; then
    commit_plugin_update
    FULL_INSTALL_ACTIVE=0
fi
INSTALL_OK=1

step 6 "完成安装并输出访问入口"

rm -f /tmp/luci-indexcache || say "WARNING: Could not remove the LuCI index cache; refresh the page after installation." || true
rm -f /tmp/luci-indexcache.* || say "WARNING: Could not remove the LuCI index cache; refresh the page after installation." || true
rm -rf /tmp/luci-modulecache || say "WARNING: Could not remove the LuCI module cache; refresh the page after installation." || true
if [ -x /etc/init.d/rpcd ] && ! /etc/init.d/rpcd reload; then
    say "WARNING: Could not reload rpcd; refresh the LuCI page after installation." || true
fi
say "LuCI 页面已更新；如入口未刷新，请重新登录路由器管理页面。"

say "sub-store package installed."
say "Container status: $(/usr/bin/sub-storectl status 2>/dev/null || echo unknown)"
say "Management URL: $(/usr/bin/sub-storectl url)"
say "Docker storage: $(/usr/bin/sub-storectl storage 2>/dev/null || echo unavailable)"
say "Package version: $PACKAGE_VERSION"
say "The first install and image pull require Internet access. No WAN firewall rule or port forward was added."
