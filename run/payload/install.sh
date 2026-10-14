#!/bin/sh
set -eu

PACKAGE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LOG=/tmp/sub-store-run-install.log
LOG_MAX_BYTES=524288
INSTALL_STEP="准备安装"
INSTALL_OK=0
: > "$LOG"
chmod 600 "$LOG"
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
finish() {
    result=$?
    if [ "$INSTALL_OK" != "1" ]; then
        say "安装未完成，阶段：$INSTALL_STEP；退出码：$result"
        say "安装阶段日志：$LOG。修复原因后可以重新上传安装包重试。"
    fi
}
trap finish EXIT
step 1 "检查系统与安装依赖"
[ "$(id -u)" = "0" ] || fail "Run the .run installer as root."
command -v opkg >/dev/null 2>&1 || fail "This build requires an opkg-based iStoreOS/OpenWrt 24.10.x system."
[ -d /etc ] || fail "Cannot find the system configuration directory."
PLUGIN_ONLY="${SUB_STORE_PLUGIN_ONLY:-0}"

if [ -r /etc/openwrt_release ]; then
    . /etc/openwrt_release
    case "${DISTRIB_RELEASE:-}" in
        24.10*) ;;
        *) say "WARNING: built for 24.10.x; detected ${DISTRIB_RELEASE:-unknown}. Continuing with best-effort compatibility." ;;
    esac
fi

if [ "$PLUGIN_ONLY" = "1" ]; then
    [ -f /www/luci-static/resources/form.js ] || fail "LuCI is unavailable; reinstall the full package."
    command -v lua >/dev/null 2>&1 || fail "Lua is unavailable; reinstall the full package."
    lua -e 'require "luci.sys"; require "luci.jsonc"' >/dev/null 2>&1 ||
        fail "LuCI status dependencies are unavailable; reinstall the full package."
else
    if ! command -v docker >/dev/null 2>&1; then
        say "Installing Docker from the configured opkg feeds..."
        opkg update
        opkg install dockerd docker
    fi

    command -v docker >/dev/null 2>&1 || fail "Docker CLI is still unavailable after package installation."
    [ -x /etc/init.d/dockerd ] || fail "The dockerd init service is missing."

    if [ ! -f /www/luci-static/resources/form.js ] || ! command -v lua >/dev/null 2>&1 ||
        ! lua -e 'require "luci.sys"; require "luci.jsonc"' >/dev/null 2>&1 ||
        ! command -v curl >/dev/null 2>&1 ||
        ! opkg status rpcd-mod-file 2>/dev/null | grep -q 'Status:.*installed'; then
        say "Installing native LuCI and RPC dependencies..."
        opkg update
        opkg install luci-base lua luci-lib-base luci-lib-jsonc rpcd-mod-file curl
    fi
    [ -f /www/luci-static/resources/form.js ] || fail "LuCI JavaScript form support is unavailable."
    lua -e 'require "luci.sys"; require "luci.jsonc"' >/dev/null 2>&1 || fail "LuCI status dependencies are unavailable."
fi

if [ "$PLUGIN_ONLY" = "1" ]; then
    step 2 "只更新 LuCI 插件"
    RUNNING_DIR="$PACKAGE_DIR/.running"
    mkdir -p "$RUNNING_DIR/usr/bin" "$RUNNING_DIR/usr/lib/sub-store"
    for active_file in \
        usr/bin/sub-storectl \
        usr/lib/sub-store/job.sh \
        usr/lib/sub-store/plugin-update; do
        if [ -f "/$active_file" ]; then
            mv "/$active_file" "$RUNNING_DIR/$active_file"
        fi
    done
    (umask 022; cp -R "$PACKAGE_DIR/root/." /)
    . /usr/lib/sub-store/permissions.sh
    sub_store_public_permissions "" || fail "Cannot set LuCI public asset permissions."
    chmod 755 /usr/bin/sub-storectl /usr/lib/sub-store/job.sh /usr/lib/sub-store/status \
        /usr/lib/sub-store/plugin-update /etc/init.d/sub-store
    rm -f /usr/lib/lua/luci/controller/sub_store.lua /usr/lib/lua/luci/model/cbi/sub_store.lua \
        /usr/lib/sub-store/check-update
    mkdir -p /etc/sub-store
    printf '%s\n' "$PACKAGE_VERSION" >/etc/sub-store/version
    chmod 644 /etc/sub-store/version
    rm -f /tmp/luci-indexcache*
    rm -rf /tmp/luci-modulecache
    [ ! -x /etc/init.d/rpcd ] || /etc/init.d/rpcd reload
    say "LuCI plugin updated to $PACKAGE_VERSION. The Docker image, container, and data were not changed."
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
(umask 022; cp -R "$PACKAGE_DIR/root/." /)
. /usr/lib/sub-store/permissions.sh
sub_store_public_permissions "" || fail "Cannot set LuCI public asset permissions."
chmod 755 /usr/bin/sub-storectl /usr/lib/sub-store/job.sh /usr/lib/sub-store/status \
    /usr/lib/sub-store/plugin-update /etc/init.d/sub-store
# Remove only the obsolete files shipped by this package.
rm -f /usr/lib/lua/luci/controller/sub_store.lua /usr/lib/lua/luci/model/cbi/sub_store.lua /usr/lib/sub-store/check-update
rm -f /tmp/luci-indexcache*
rm -rf /tmp/luci-modulecache

mkdir -p /etc/config
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

step 5 "拉取或复用官方镜像、启动容器并检查服务（首次下载可能较慢）"
MANAGED_UPGRADE=0
if [ "$EXISTING" = "1" ] && [ -f /etc/sub-store/installed ]; then
    MANAGED_UPGRADE=1
    say "Updating the managed sub-store container..."
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

rm -f /tmp/luci-indexcache
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache
[ ! -x /etc/init.d/rpcd ] || /etc/init.d/rpcd reload
say "LuCI 页面已更新；如入口未刷新，请重新登录路由器管理页面。"

say "sub-store package installed."
say "Container status: $(/usr/bin/sub-storectl status 2>/dev/null || echo unknown)"
say "Management URL: $(/usr/bin/sub-storectl url)"
say "Docker storage: $(/usr/bin/sub-storectl storage 2>/dev/null || echo unavailable)"
say "Package version: $PACKAGE_VERSION"
say "The first install and image pull require Internet access. No WAN firewall rule or port forward was added."

INSTALL_OK=1
