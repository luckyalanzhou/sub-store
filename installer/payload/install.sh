#!/bin/sh
set -eu

PACKAGE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ "$(id -u)" != "0" ]; then
    printf '%s\n' "Run the .run installer as root." >&2
    exit 1
fi

prepare_install_log() {
    log_dir="$1"
    current_uid="$(id -u)" || return 1
    [ ! -L "$log_dir" ] || return 1
    if [ ! -e "$log_dir" ]; then
        mkdir -m 700 "$log_dir" || return 1
    fi
    [ -d "$log_dir" ] && [ ! -L "$log_dir" ] || return 1
    directory_uid="$(stat -c '%u' "$log_dir" 2>/dev/null)" || return 1
    [ "$directory_uid" = "$current_uid" ] || return 1
    chmod 700 "$log_dir" || return 1
    rm -f "$log_dir"/install.log.* || return 1

    log_path="$log_dir/install.log"
    [ ! -L "$log_path" ] || return 1
    if [ -e "$log_path" ]; then
        [ -f "$log_path" ] || return 1
        file_metadata="$(stat -c '%u:%h' "$log_path" 2>/dev/null)" || return 1
        file_uid="${file_metadata%%:*}"
        link_count="${file_metadata#*:}"
        [ "$file_uid" = "$current_uid" ] && [ "$link_count" = "1" ] || return 1
    fi
    : > "$log_path" || return 1
    chmod 600 "$log_path" || return 1
    printf '%s\n' "$log_path"
}

if ! LOG="$(prepare_install_log /tmp/sub-store-run-install)"; then
    printf '%s\n' "Cannot safely prepare the installer log at /tmp/sub-store-run-install/install.log." >&2
    exit 1
fi
LOG_MAX_BYTES=1048576
INSTALL_STEP="准备安装"
INSTALL_OK=0
PLUGIN_BACKUP_DIR=""
PLUGIN_UPDATE_ACTIVE=0
PLUGIN_TARGET_PREFIX=""
FULL_INSTALL_ACTIVE=0
SERVICE_WAS_ENABLED=0
PACKAGE_VERSION=dev
if [ -r "$PACKAGE_DIR/build-version" ]; then
    PACKAGE_VERSION="$(cat "$PACKAGE_DIR/build-version")"
fi

say() {
    printf '%s\n' "$*" | tee -a "$LOG"
    log_size="$(wc -c < "$LOG" | tr -d '[:space:]')"
    if [ -n "$log_size" ] && [ "$log_size" -gt "$LOG_MAX_BYTES" ]; then
        trimmed_log="$(umask 077; mktemp "$LOG.XXXXXX")"
        tail -c "$LOG_MAX_BYTES" "$LOG" > "$trimmed_log"
        mv "$trimmed_log" "$LOG"
    fi
}

fail() {
    say "ERROR: $*"
    exit 1
}

is_supported_release() {
    case "$1" in
        24.10*|25.12*) return 0 ;;
        *) return 1 ;;
    esac
}

detect_package_manager() {
    if command -v opkg >/dev/null 2>&1; then
        PACKAGE_MANAGER=opkg
    elif command -v apk >/dev/null 2>&1; then
        PACKAGE_MANAGER=apk
    else
        fail "This installer requires iStoreOS/OpenWrt with opkg or apk."
    fi
}

package_manager_update() {
    case "$PACKAGE_MANAGER" in
        opkg) opkg update ;;
        apk) apk update ;;
        *) fail "No supported package manager has been selected." ;;
    esac
}

package_manager_install() {
    case "$PACKAGE_MANAGER" in
        opkg) opkg install "$@" ;;
        apk) apk add "$@" ;;
        *) fail "No supported package manager has been selected." ;;
    esac
}

package_is_installed() {
    case "$PACKAGE_MANAGER" in
        opkg) opkg status "$1" 2>/dev/null | grep -q 'Status:.*installed' ;;
        apk) apk info 2>/dev/null | grep -Fxq -- "$1" ;;
        *) fail "No supported package manager has been selected." ;;
    esac
}

ensure_jsonfilter() {
    command -v jsonfilter >/dev/null 2>&1 && return 0
    say "Installing required jsonfilter package..."
    package_manager_update || fail "Could not refresh package feeds to install jsonfilter."
    package_manager_install jsonfilter || fail "Could not install jsonfilter from the configured package feeds."
    command -v jsonfilter >/dev/null 2>&1 || fail "jsonfilter is still unavailable after package installation."
}

step() {
    INSTALL_STEP="$2"
    say "[$1/6] $INSTALL_STEP"
}

plugin_target_path() {
    printf '%s/%s\n' "${PLUGIN_TARGET_PREFIX%/}" "$1"
}

refresh_luci_cache() {
    rm -f /tmp/luci-indexcache* || { say "WARNING: Could not clear the LuCI index cache." || true; }
    rm -rf /tmp/luci-modulecache || { say "WARNING: Could not clear the LuCI module cache." || true; }
    if [ -x /etc/init.d/rpcd ] && ! /etc/init.d/rpcd reload >/dev/null 2>&1; then
        say "WARNING: Could not reload rpcd; reload the LuCI page manually." || true
    fi
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
    PLUGIN_BACKUP_DIR=""
    refresh_luci_cache
    say "LuCI 插件文件已恢复到更新前状态。"
}

prepare_plugin_rollback() {
    PLUGIN_BACKUP_DIR="$(umask 077; mktemp -d /tmp/sub-store-plugin-rollback.XXXXXX)"
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
    PLUGIN_UPDATE_ACTIVE=1
}

commit_plugin_update() {
    rm -rf "$PLUGIN_BACKUP_DIR"
    PLUGIN_BACKUP_DIR=""
    PLUGIN_UPDATE_ACTIVE=0
}

finish() {
    result=$?
    if [ "$INSTALL_OK" != "1" ]; then
        if [ "$FULL_INSTALL_ACTIVE" = "1" ] && [ "$SERVICE_WAS_ENABLED" = "0" ] && [ -x /etc/init.d/sub-store ]; then
            /etc/init.d/sub-store disable >/dev/null 2>&1 || true
        fi
        rollback_plugin_update || true
        say "安装未完成，阶段：$INSTALL_STEP；退出码：$result"
        say "安装阶段日志：$LOG。修复原因后可以重新上传安装包重试。"
    fi
}
trap finish EXIT
step 1 "检查系统与安装依赖"
detect_package_manager
ensure_jsonfilter
[ -d /etc ] || fail "Cannot find the system configuration directory."
PLUGIN_ONLY="${SUB_STORE_PLUGIN_ONLY:-0}"

if [ -r /etc/openwrt_release ]; then
    . /etc/openwrt_release
    is_supported_release "${DISTRIB_RELEASE:-}" ||
        say "WARNING: tested on iStoreOS 24.10.x and 25.12.x; detected ${DISTRIB_RELEASE:-unknown}. Continuing with best-effort compatibility."
fi

if [ "$PLUGIN_ONLY" = "1" ]; then
    [ -f /www/luci-static/resources/form.js ] || fail "LuCI is unavailable; reinstall the full package."
    command -v lua >/dev/null 2>&1 || fail "Lua is unavailable; reinstall the full package."
    lua -e 'require "luci.sys"; require "luci.jsonc"' >/dev/null 2>&1 ||
        fail "LuCI status dependencies are unavailable; reinstall the full package."
else
    if ! command -v docker >/dev/null 2>&1; then
        say "Installing Docker from the configured package feeds..."
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
        usr/lib/sub-store/job.sh \
        usr/lib/sub-store/plugin-update; do
        active_path="$(plugin_target_path "$active_file")"
        if [ -f "$active_path" ]; then
            mv "$active_path" "$RUNNING_DIR/$active_file"
        fi
    done
    PLUGIN_DEST="${PLUGIN_TARGET_PREFIX:-/}"
    (umask 022; cp -R "$PACKAGE_DIR/root/." "$PLUGIN_DEST") || fail "Cannot copy updated LuCI plugin files."
    . /usr/lib/sub-store/permissions.sh
    sub_store_public_permissions "" || fail "Cannot set LuCI public asset permissions."
    chmod 755 /usr/bin/sub-storectl /usr/lib/sub-store/job.sh /usr/lib/sub-store/status \
        /usr/lib/sub-store/plugin-update /etc/init.d/sub-store
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
(umask 022; cp -R "$PACKAGE_DIR/root/." /)
. /usr/lib/sub-store/permissions.sh
sub_store_public_permissions "" || fail "Cannot set LuCI public asset permissions."
chmod 755 /usr/bin/sub-storectl /usr/lib/sub-store/job.sh /usr/lib/sub-store/status \
    /usr/lib/sub-store/plugin-update /etc/init.d/sub-store
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
    if /etc/init.d/sub-store enable && /usr/bin/sub-storectl update; then
        touch /etc/sub-store/installed
        chmod 600 /etc/sub-store/installed
    else
        fail "sub-store update failed; the previous container was restored when possible."
    fi
elif [ "$EXISTING" = "1" ]; then
    if /etc/init.d/sub-store enable && /usr/bin/sub-storectl restart; then
        touch /etc/sub-store/installed
        chmod 600 /etc/sub-store/installed
    else
        fail "Existing sub-store migration failed; the previous container was restored when possible."
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

uci -q delete sub-store.main.data_dir >/dev/null 2>&1 || true
uci -q delete sub-store.main.port >/dev/null 2>&1 || true
uci commit sub-store
chmod 600 /etc/config/sub-store

step 6 "完成安装并输出访问入口"
printf '%s\n' "$PACKAGE_VERSION" >/etc/sub-store/version
chmod 644 /etc/sub-store/version

# The managed container, UCI settings, plugin files, and package version now
# describe the same successful installation. Later cache refreshes are not part
# of the rollback boundary because the previous container has already been
# retired by sub-storectl.
commit_plugin_update
FULL_INSTALL_ACTIVE=0
INSTALL_OK=1
refresh_luci_cache || true
say "LuCI 页面已更新；如入口未刷新，请重新登录路由器管理页面。"

say "sub-store package installed."
say "Container status: $(/usr/bin/sub-storectl status 2>/dev/null || echo unknown)"
say "Management URL: $(/usr/bin/sub-storectl url)"
say "Docker storage: $(/usr/bin/sub-storectl storage 2>/dev/null || echo unavailable)"
say "Package version: $PACKAGE_VERSION"
say "The first install and image pull require Internet access. No WAN firewall rule or port forward was added."
