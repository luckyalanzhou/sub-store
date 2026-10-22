#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CTL="$ROOT/run/payload/root/usr/bin/sub-storectl"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
awk '/^fail\(\) \{/ {copy=1} /^ACTION=/ {exit} copy {print}' "$CTL" > "$TEST_DIR/functions.sh"
. "$TEST_DIR/functions.sh"
. "$ROOT/run/payload/root/usr/lib/sub-store/registry-image.sh"
. "$ROOT/run/payload/root/usr/lib/sub-store/cron.sh"
render_config() { valid_config; }

FRONTEND_PORT=3001
BACKEND_PORT=3000
BACKEND_LAN_ACCESS=1
ACCESS_HOST=""
PUBLIC_URL=""
API_PATH=0123456789abcdef0123456789abcdef0123456789abcdef
SYNC_CRON='55 23 * * *'
DATA_VOLUME=sub-store-data
HEALTHCHECK="$ROOT/run/payload/root/usr/lib/sub-store/healthcheck.js"
APP_VERSION_CHECK="$ROOT/run/payload/root/usr/lib/sub-store/app-version.js"
IMAGE_REF=xream/sub-store:latest
RUN_IMAGE_REF="$IMAGE_REF"
CONFIG="$TEST_DIR/sub-store.config"
INSTALL_TRANSACTION_DIR="$TEST_DIR/install-transaction"
touch "$CONFIG"
VOLUME_PATH="$TEST_DIR/volume"
mkdir -p "$VOLUME_PATH"
OLD_IMAGE_ID="sha256:$(printf '%064d' 1)"
NEW_IMAGE_ID="sha256:$(printf '%064d' 2)"
printf '%s\n' "$OLD_IMAGE_ID" > "$TEST_DIR/latest"
printf '%s\n' 'subscription data' > "$VOLUME_PATH/user-data"
: > "$TEST_DIR/docker.log"
PULL_RESULT=same
NEW_HEALTHY=0
CLEANUP_CASE=unused
REGISTRY_MODE=same
CONTAINER_STATE=running
IMAGE_ARCH=amd64
IMAGE_VARIANT=''
sleep() { :; }
commit_installer_metadata() {
    printf 'metadata %s\n' "$1" >> "$TEST_DIR/docker.log"
    [ "${INSTALL_METADATA_FAIL:-0}" != 1 ]
}

uci() {
    case "$*" in
        '-q get network.lan.ipaddr') echo 192.0.2.1 ;;
        *) return 0 ;;
    esac
}

docker() {
    printf '%s\n' "$*" >> "$TEST_DIR/docker.log"
    case "$1" in
        info) return 0 ;;
        ps)
            case "$*" in
                *ancestor=*)
                    [ "$CLEANUP_CASE" != usage-failed ] || return 1
                    [ "$CLEANUP_CASE" != shared ] || echo other-container
                    ;;
            esac
            return 0
            ;;
        pull)
            [ "$PULL_RESULT" = same ] || printf '%s\n' "$NEW_IMAGE_ID" > "$TEST_DIR/latest"
            echo pulled
            ;;
        image)
            case "$2" in
                inspect)
                    case "$*" in
                        *'{{json .}}'*) printf '{"Architecture":"%s","Os":"linux","Variant":"%s"}\n' "$IMAGE_ARCH" "$IMAGE_VARIANT" ;;
                        *RepoTags*)
                            [ "$CLEANUP_CASE" != inspect-failed ] || return 1
                            [ "$CLEANUP_CASE" = dangling ] || echo "xream/sub-store@$OLD_IMAGE_ID"
                            [ "$CLEANUP_CASE" != tagged ] || echo user/keep:backup
                            [ "$CLEANUP_CASE" != custom-tag ] || echo xream/sub-store:backup
                            [ "$CLEANUP_CASE" != latest-tag ] || echo xream/sub-store:latest
                            ;;
                        *) cat "$TEST_DIR/latest" ;;
                    esac
                    ;;
                tag) printf '%s\n' "$3" > "$TEST_DIR/latest" ;;
                rm)
                    [ "$CLEANUP_CASE" != remove-failed ] || return 1
                    touch "$TEST_DIR/image-removed"
                    ;;
            esac
            ;;
        volume)
            case "$2" in
                inspect)
                    if [ "${3:-}" = '-f' ]; then echo "$VOLUME_PATH"; fi
                    ;;
                create) echo "$DATA_VOLUME" ;;
                rm) return 0 ;;
            esac
            ;;
        port)
            case "$3" in
                3001/tcp) echo 0.0.0.0:3001 ;;
                3000/tcp) echo 0.0.0.0:3000 ;;
            esac
            ;;
        inspect)
            if [ "${2:-}" != '-f' ]; then
                case "${2:-}" in
                    sub-store) [ ! -f "$TEST_DIR/moved" ] || [ -f "$TEST_DIR/new" ] ;;
                    sub-store-rollback-*) [ -f "$TEST_DIR/moved" ] ;;
                    *) return 1 ;;
                esac
                return
            fi
            template="$3"
            target="$4"
            case "$template" in
                *Config.Image*) echo xream/sub-store:latest ;;
                *HostConfig.SecurityOpt*) echo '["no-new-privileges:true"]' ;;
                *NetworkSettings.Ports*) echo 0.0.0.0 ;;
                *State.Health*)
                    if [ -f "$TEST_DIR/health-starting" ]; then
                        health_checks="$(cat "$TEST_DIR/health-checks")"
                        health_checks=$((health_checks + 1))
                        printf '%s\n' "$health_checks" > "$TEST_DIR/health-checks"
                        if [ "$health_checks" -ge 3 ]; then echo healthy; else echo starting; fi
                    else
                        echo healthy
                    fi
                    ;;
                *State.Running*) [ "$CONTAINER_STATE" != running ] || echo true ;;
                *State.Status*)
                    if [ -n "${INSTALL_STATUS_OVERRIDE:-}" ] && [ -f "$TEST_DIR/install-status-checked" ]; then echo "$INSTALL_STATUS_OVERRIDE"
                    elif [ -f "$TEST_DIR/new" ] && [ "$NEW_HEALTHY" != 1 ]; then echo exited
                    else echo "$CONTAINER_STATE"; fi
                    ;;
                *Config.Env*)
                    cat <<EOF
SUB_STORE_FRONTEND_BACKEND_PATH=/$API_PATH
SUB_STORE_BACKEND_SYNC_CRON=$SYNC_CRON
SUB_STORE_CORS_ALLOWED_ORIGINS=http://192.0.2.1:3001,http://127.0.0.1:3001,http://localhost:3001
SUB_STORE_BACKEND_PREFIX=true
SUB_STORE_BACKEND_MERGE=
EOF
                    ;;
                *Mounts*Type*) echo volume ;;
                *Mounts*Name*) echo "$DATA_VOLUME" ;;
                *Mounts*Source*) echo "$VOLUME_PATH" ;;
                *'{{.Image}}'*)
                    if [ -f "$TEST_DIR/new" ]; then
                        [ "$CLEANUP_CASE" != current-inspect-failed ] || return 1
                        cat "$TEST_DIR/latest"
                    else
                        echo "$OLD_IMAGE_ID"
                    fi
                    ;;
                *) return 1 ;;
            esac
            ;;
        stop) return 0 ;;
        rename)
            if [ "$2" = sub-store ]; then touch "$TEST_DIR/moved"; else rm -f "$TEST_DIR/moved"; fi
            ;;
        run) touch "$TEST_DIR/new"; echo new-container ;;
        exec)
            [ "$NEW_HEALTHY" = 1 ] || return 1
            [ -z "${INSTALL_STATUS_OVERRIDE:-}" ] || touch "$TEST_DIR/install-status-checked"
            ;;
        logs) echo broken-container ;;
        rm)
            case "$2" in
                sub-store-rollback-*)
                    [ "$CLEANUP_CASE" != backup-failed ] || return 1
                    rm -f "$TEST_DIR/moved"
                    ;;
                *) rm -f "$TEST_DIR/new" ;;
            esac
            ;;
        start) return 0 ;;
        *) return 1 ;;
    esac
}

# Exercise the actual JSON paths against registry fixtures without requiring OpenWrt's binary on the host.
jsonfilter() {
    node -e '
        const fs = require("node:fs");
        try {
            const path = process.argv[1].slice(2).replace(/\[(\d+)\]/g, ".$1").split(".");
            const value = path.reduce((obj, key) => obj?.[key], JSON.parse(fs.readFileSync(0, "utf8")));
            if (value === undefined || value === null) process.exit(1);
            console.log(typeof value === "object" ? JSON.stringify(value) : value);
        } catch { process.exit(1); }
    ' "$2"
}

curl() {
    for registry_url in "$@"; do :; done
    printf '%s\n' "$registry_url" >> "$TEST_DIR/registry.log"
    [ "$REGISTRY_MODE" != unavailable ] || return 1
    case "$registry_url" in
        https://auth.docker.io/token*) echo '{"token":"test-token"}' ;;
        */manifests/latest)
            case "$REGISTRY_MODE" in
                malformed) echo '{}' ;;
                single) printf '{"config":{"digest":"%s"}}\n' "$NEW_IMAGE_ID" ;;
                ambiguous)
                    printf '{"manifests":[{"digest":"%s","platform":{"os":"linux","architecture":"arm","variant":"v6"}},{"digest":"%s","platform":{"os":"linux","architecture":"arm","variant":"v7"}}]}\n' "$OLD_IMAGE_ID" "$NEW_IMAGE_ID"
                    ;;
                *)
                    printf '{"manifests":[{"digest":"%s","platform":{"os":"linux","architecture":"arm64","variant":"v8"}},{"digest":"%s","platform":{"os":"linux","architecture":"amd64"}}]}\n' "$OLD_IMAGE_ID" "$NEW_IMAGE_ID"
                    ;;
            esac
            ;;
        */manifests/sha256:*)
            if [ "$REGISTRY_MODE" = same ]; then
                printf '{"config":{"digest":"%s"}}\n' "$OLD_IMAGE_ID"
            else
                printf '{"config":{"digest":"%s"}}\n' "$NEW_IMAGE_ID"
            fi
            ;;
        *) return 1 ;;
    esac
}

# Run the real command dispatcher with the host fixtures above. Only the
# OpenWrt config-loader and absolute library paths are adapted for this host.
config_load() { :; }
config_get() {
    case "$1" in
        FRONTEND_PORT) eval "$1=3001" ;;
        BACKEND_PORT) eval "$1=3000" ;;
        ACCESS_HOST|PUBLIC_URL) eval "$1=''" ;;
        API_PATH) eval "$1=0123456789abcdef0123456789abcdef0123456789abcdef" ;;
        SYNC_CRON) eval "$1='55 23 * * *'" ;;
        IMAGE_REF) eval "$1=xream/sub-store:latest" ;;
    esac
}
config_get_bool() { eval "$1=1"; }
sed \
    -e "s|^CONFIG=/etc/config/sub-store$|CONFIG='$CONFIG'|" \
    -e "s|/etc/config/sub-store|$CONFIG|g" \
    -e "s|/etc/sub-store|$TEST_DIR/etc-sub-store|g" \
    -e "s|/usr/lib/sub-store/healthcheck\.js|$ROOT/run/payload/root/usr/lib/sub-store/healthcheck.js|g" \
    -e "s|/usr/lib/sub-store/app-version\.js|$ROOT/run/payload/root/usr/lib/sub-store/app-version.js|g" \
    -e 's|^\. /lib/functions\.sh$|:|' \
    -e "s|^\. /usr/lib/sub-store/cron\.sh$|. '$ROOT/run/payload/root/usr/lib/sub-store/cron.sh'|" \
    -e "s|^\. /usr/lib/sub-store/registry-image\.sh$|. '$ROOT/run/payload/root/usr/lib/sub-store/registry-image.sh'|" \
    "$CTL" > "$TEST_DIR/sub-storectl"
mkdir -p "$TEST_DIR/etc-sub-store"
run_ctl() (
    set -- "$@"
    . "$TEST_DIR/sub-storectl"
)

# The public update command must dispatch into the no-op path without pulling
# or replacing a current container.
: > "$TEST_DIR/docker.log"
REGISTRY_MODE=same
run_ctl update > "$TEST_DIR/cli-update-output"
grep -Fq '镜像已是最新，无需拉取或重建。' "$TEST_DIR/cli-update-output"
if grep -Eq '^(pull|stop|rename|run|rm) ' "$TEST_DIR/docker.log"; then
    echo 'The update command pulled or rebuilt an unchanged image.' >&2
    exit 1
fi

# A changed image through the public command must replace the container,
# retire only its previous image, and keep the mounted user data intact.
: > "$TEST_DIR/docker.log"
REGISTRY_MODE=new
PULL_RESULT=new
NEW_HEALTHY=1
rm -f "$TEST_DIR/new" "$TEST_DIR/moved" "$TEST_DIR/image-removed"
printf '%s\n' "$OLD_IMAGE_ID" > "$TEST_DIR/latest"
run_ctl update > "$TEST_DIR/cli-image-update-output"
[ -f "$TEST_DIR/new" ]
[ ! -f "$TEST_DIR/moved" ]
[ -f "$TEST_DIR/image-removed" ]
[ "$(cat "$VOLUME_PATH/user-data")" = 'subscription data' ]
grep -Fq '发现新镜像，开始拉取并更新容器...' "$TEST_DIR/cli-image-update-output"
grep -q '^pull xream/sub-store@sha256:' "$TEST_DIR/docker.log"
grep -q '^run -d ' "$TEST_DIR/docker.log"
grep -Fq '旧镜像已清理，用户数据保留。' "$TEST_DIR/cli-image-update-output"

# The installer-facing command must validate its version, use the same
# no-op image path, then record successful deployment metadata.
: > "$TEST_DIR/docker.log"
run_ctl install-deploy update 0.0.24 > "$TEST_DIR/cli-install-deploy-output"
[ "$(cat "$TEST_DIR/etc-sub-store/version")" = '0.0.24' ]
[ -f "$TEST_DIR/etc-sub-store/installed" ]
if run_ctl install-deploy update invalid > "$TEST_DIR/cli-invalid-version-output" 2>&1; then
    echo 'The installer deployment command accepted an invalid package version.' >&2
    exit 1
fi

# Restore the baseline used by the focused function-level edge-case matrix.
rm -f "$TEST_DIR/new" "$TEST_DIR/moved" "$TEST_DIR/image-removed"
printf '%s\n' "$OLD_IMAGE_ID" > "$TEST_DIR/latest"
NEW_HEALTHY=0
PULL_RESULT=same
REGISTRY_MODE=same

update_image > "$TEST_DIR/noop-output"
grep -Fq '镜像已是最新' "$TEST_DIR/noop-output"
if grep -Eq '^(pull|stop|rename|run|rm) ' "$TEST_DIR/docker.log"; then
    echo 'Unchanged image caused a pull or container rebuild.' >&2
    exit 1
fi

: > "$TEST_DIR/docker.log"
touch "$TEST_DIR/health-starting"
printf '0\n' > "$TEST_DIR/health-checks"
update_image > "$TEST_DIR/starting-output"
grep -Fq '镜像已是最新' "$TEST_DIR/starting-output"
if grep -Eq '^(pull|stop|rename|run|rm) ' "$TEST_DIR/docker.log"; then
    echo 'Update changed a current image while its health check was becoming healthy.' >&2
    exit 1
fi
rm -f "$TEST_DIR/health-starting" "$TEST_DIR/health-checks"

for unchanged_case in changed-settings stopped arm64; do
    (
        : > "$TEST_DIR/docker.log"
        case "$unchanged_case" in
            changed-settings) BACKEND_LAN_ACCESS=0 ;;
            stopped) CONTAINER_STATE=exited ;;
            arm64) IMAGE_ARCH=arm64 ;;
        esac
        if [ "$unchanged_case" = stopped ]; then
            if update_image > "$TEST_DIR/unchanged-output" 2>&1; then
                echo 'A stopped container was reported as a successful no-op update.' >&2
                exit 1
            fi
        else
            update_image > "$TEST_DIR/unchanged-output"
        fi
        ! grep -Eq '^(pull|stop|rename|run|rm) ' "$TEST_DIR/docker.log"
    )
done

for registry_error in unavailable malformed unsupported-platform ambiguous; do
    (
        : > "$TEST_DIR/docker.log"
        REGISTRY_MODE="$registry_error"
        [ "$registry_error" != unsupported-platform ] || IMAGE_ARCH=mips64
        [ "$registry_error" != ambiguous ] || IMAGE_ARCH=arm
        if (update_image) > "$TEST_DIR/registry-error" 2>&1; then
            echo 'An unverified registry response was accepted.' >&2
            exit 1
        fi
        ! grep -Eq '^(pull|stop|rename|run|rm) ' "$TEST_DIR/docker.log"
        [ "$(cat "$VOLUME_PATH/user-data")" = 'subscription data' ]
    )
done

(
    : > "$TEST_DIR/docker.log"
    REGISTRY_MODE=new
    PULL_RESULT=same
    if (update_image) > "$TEST_DIR/pull-mismatch" 2>&1; then
        echo 'Pulled image did not match the checked version but was accepted.' >&2
        exit 1
    fi
    ! grep -Eq '^(stop|rename|run|rm) ' "$TEST_DIR/docker.log"
    [ "$(cat "$VOLUME_PATH/user-data")" = 'subscription data' ]
)

: > "$TEST_DIR/docker.log"
PULL_RESULT=new
REGISTRY_MODE=new
result=0
if (update_image) > "$TEST_DIR/output" 2>&1; then
    result=0
else
    result=$?
fi
[ "$result" -ne 0 ]
[ "$(cat "$TEST_DIR/latest")" = "$OLD_IMAGE_ID" ]
grep -Fq "image tag $OLD_IMAGE_ID xream/sub-store:latest" "$TEST_DIR/docker.log"
grep -Eq 'rename sub-store-rollback-[0-9-]+ sub-store' "$TEST_DIR/docker.log"
grep -Fq 'new container failed to start' "$TEST_DIR/output"
! grep -q '^image rm ' "$TEST_DIR/docker.log"
[ "$(cat "$VOLUME_PATH/user-data")" = 'subscription data' ]

for cleanup_case in unused dangling shared tagged custom-tag latest-tag inspect-failed current-inspect-failed usage-failed remove-failed backup-failed single; do
    (
        CLEANUP_CASE="$cleanup_case"
        NEW_HEALTHY=1
        PULL_RESULT=new
        REGISTRY_MODE=new
        [ "$CLEANUP_CASE" != single ] || REGISTRY_MODE=single
        rm -f "$TEST_DIR/new" "$TEST_DIR/moved" "$TEST_DIR/image-removed"
        printf '%s\n' "$OLD_IMAGE_ID" > "$TEST_DIR/latest"
        : > "$TEST_DIR/docker.log"
        update_image > "$TEST_DIR/cleanup-output" 2>&1
        [ -f "$TEST_DIR/new" ]
        [ "$(cat "$VOLUME_PATH/user-data")" = 'subscription data' ]
        if grep -Eq '^(volume rm|system prune|image prune|builder prune|container prune)|^rm .*--volumes' "$TEST_DIR/docker.log"; then
            echo 'Cleanup touched resources beyond the replaced image.' >&2
            exit 1
        fi
        case "$CLEANUP_CASE" in
            unused|dangling|single|latest-tag)
                [ -f "$TEST_DIR/image-removed" ]
                grep -Fxq "image rm $OLD_IMAGE_ID" "$TEST_DIR/docker.log"
                backup_line="$(grep -n '^rm sub-store-rollback-' "$TEST_DIR/docker.log" | cut -d: -f1)"
                image_line="$(grep -n '^image rm ' "$TEST_DIR/docker.log" | cut -d: -f1)"
                [ "$backup_line" -lt "$image_line" ]
                ;;
            remove-failed)
                [ ! -f "$TEST_DIR/image-removed" ]
                grep -Fq 'Update succeeded, but the old image could not be removed' "$TEST_DIR/cleanup-output"
                ;;
            *)
                [ ! -f "$TEST_DIR/image-removed" ]
                ! grep -q '^image rm ' "$TEST_DIR/docker.log"
                ;;
        esac
    )
done

# Installer deployment keeps the old container until the explicit running-state
# check passes, then retires it. A failed post-replacement check restores it.
(
    REGISTRY_MODE=new
    PULL_RESULT=new
    NEW_HEALTHY=1
    CONTAINER_STATE=running
    CLEANUP_CASE=unused
    rm -f "$TEST_DIR/new" "$TEST_DIR/moved" "$TEST_DIR/image-removed" "$TEST_DIR/install-status-checked"
    : > "$TEST_DIR/docker.log"
    install_deploy update 0.0.24
    [ -f "$TEST_DIR/new" ]
    [ ! -f "$TEST_DIR/moved" ]
    grep -q '^rm sub-store-rollback-' "$TEST_DIR/docker.log"
    status_line="$(grep -nF "inspect -f {{.State.Status}} sub-store" "$TEST_DIR/docker.log" | tail -n 1 | cut -d: -f1)"
    metadata_line="$(grep -nFx 'metadata 0.0.24' "$TEST_DIR/docker.log" | cut -d: -f1)"
    backup_line="$(grep -n '^rm sub-store-rollback-' "$TEST_DIR/docker.log" | cut -d: -f1)"
    [ "$status_line" -lt "$metadata_line" ] && [ "$metadata_line" -lt "$backup_line" ]
)

REGISTRY_MODE=new
PULL_RESULT=new
NEW_HEALTHY=1
CONTAINER_STATE=running
INSTALL_STATUS_OVERRIDE=exited
CLEANUP_CASE=unused
rm -f "$TEST_DIR/new" "$TEST_DIR/moved" "$TEST_DIR/image-removed" "$TEST_DIR/install-status-checked"
: > "$TEST_DIR/docker.log"
if (install_deploy update 0.0.24) > "$TEST_DIR/staged-rollback-output" 2>&1; then
    echo 'Installer accepted a deployment whose post-update status was not running.' >&2
    exit 1
fi
[ ! -f "$TEST_DIR/new" ]
[ ! -f "$TEST_DIR/moved" ]
grep -q '^rename sub-store-rollback-.* sub-store$' "$TEST_DIR/docker.log"
! grep -q '^rm sub-store-rollback-' "$TEST_DIR/docker.log"
unset INSTALL_STATUS_OVERRIDE

REGISTRY_MODE=new
PULL_RESULT=new
NEW_HEALTHY=1
CONTAINER_STATE=running
INSTALL_METADATA_FAIL=1
CLEANUP_CASE=unused
rm -f "$TEST_DIR/new" "$TEST_DIR/moved" "$TEST_DIR/image-removed" "$TEST_DIR/install-status-checked"
: > "$TEST_DIR/docker.log"
if (install_deploy update 0.0.24) > "$TEST_DIR/staged-metadata-failure-output" 2>&1; then
    echo 'Installer accepted metadata failure after a successful deployment.' >&2
    exit 1
fi
[ ! -f "$TEST_DIR/new" ]
[ ! -f "$TEST_DIR/moved" ]
grep -q '^rename sub-store-rollback-.* sub-store$' "$TEST_DIR/docker.log"
! grep -q '^rm sub-store-rollback-' "$TEST_DIR/docker.log"
unset INSTALL_METADATA_FAIL

awk '/^step 5 / {copy=1; next} /^step 6 / {exit} copy {print}' "$ROOT/run/payload/install.sh" |
    sed -e 's|/usr/bin/sub-storectl|test_ctl|g' \
        -e 's|/etc/init.d/sub-store|test_init|g' \
        -e "s|/etc/sub-store/installed|$TEST_DIR/installer-installed|g" \
        -e "s|/etc/config/sub-store|$CONFIG|g" \
        -e "s|/etc/sub-store/version|$TEST_DIR/package-version|g" > "$TEST_DIR/install-deployment.sh"

for install_case in fresh cached pull-failed managed managed-failed existing existing-failed; do
    rm -f "$TEST_DIR/installer-installed"
    rm -f "$TEST_DIR/package-version" "$TEST_DIR/rollback-removed"
    : > "$TEST_DIR/installer.log"
    if (
        EXISTING=0
        PACKAGE_VERSION=0.0.24
        case "$install_case" in
            managed|managed-failed)
                EXISTING=1
                touch "$TEST_DIR/installer-installed"
                printf '0.0.23\n' > "$TEST_DIR/package-version"
                ;;
            existing-failed) EXISTING=1 ;;
            existing) EXISTING=1 ;;
        esac
        say() { :; }
        uci() {
            printf 'uci %s\n' "$*" >> "$TEST_DIR/installer.log"
            case "$*" in '-q get sub-store.main.data_dir') return 1 ;; esac
        }
        test_ctl() {
            printf 'ctl %s\n' "$*" >> "$TEST_DIR/installer.log"
            if [ "$1" = install-deploy ]; then
                case "$install_case" in
                    managed|managed-failed)
                        [ -f "$TEST_DIR/installer-installed" ] &&
                            [ "$(cat "$TEST_DIR/package-version")" = '0.0.23' ] || {
                                echo 'Managed installer state changed before deployment validation.' >&2
                                return 20
                            }
                        ;;
                esac
                case "$install_case" in
                    managed-failed|existing-failed) return 1 ;;
                esac
                touch "$TEST_DIR/installer-installed"
                printf '%s\n' "$PACKAGE_VERSION" > "$TEST_DIR/package-version"
                printf 'metadata committed\n' >> "$TEST_DIR/installer.log"
                touch "$TEST_DIR/rollback-removed"
            fi
            if [ "$1" = status ]; then
                printf 'running\n'
                return 0
            fi
            if [ "$1" = pull ]; then
                [ "$install_case" != pull-failed ] || return 1
            fi
        }
        test_init() { printf 'init %s\n' "$*" >> "$TEST_DIR/installer.log"; }
        commit_plugin_update() { printf 'commit plugin state\n' >> "$TEST_DIR/installer.log"; }
        . "$TEST_DIR/install-deployment.sh"
    ) > "$TEST_DIR/install-output" 2>&1; then
        [ "$install_case" != pull-failed ]
    else
        case "$install_case" in
            pull-failed)
                ! grep -q '^init ' "$TEST_DIR/installer.log"
                ! grep -q '^uci set sub-store.main.image_ref=' "$TEST_DIR/installer.log"
                continue
                ;;
            managed|managed-failed|existing-failed)
                ! grep -q '^commit plugin state$' "$TEST_DIR/installer.log"
                if [ "$install_case" = managed-failed ]; then
                    [ "$(cat "$TEST_DIR/package-version")" = '0.0.23' ]
                fi
                continue
                ;;
            *)
                echo "Unexpected installer failure: $install_case" >&2
                cat "$TEST_DIR/install-output" >&2
                exit 1
                ;;
        esac
    fi
    case "$install_case" in
        fresh|cached)
            grep -Fxq 'ctl pull' "$TEST_DIR/installer.log"
            grep -Fxq 'uci set sub-store.main.image_ref=xream/sub-store:latest' "$TEST_DIR/installer.log"
            pull_line="$(grep -n '^ctl pull$' "$TEST_DIR/installer.log" | cut -d: -f1)"
            start_line="$(grep -n '^init start$' "$TEST_DIR/installer.log" | cut -d: -f1)"
            [ "$pull_line" -lt "$start_line" ]
            ;;
        managed)
            ! grep -q '^ctl pull$' "$TEST_DIR/installer.log"
            grep -Fxq 'ctl install-deploy update 0.0.24' "$TEST_DIR/installer.log"
            grep -Fxq 'metadata committed' "$TEST_DIR/installer.log"
            grep -Fxq 'commit plugin state' "$TEST_DIR/installer.log"
            ;;
        existing)
            ! grep -q '^ctl pull$' "$TEST_DIR/installer.log"
            grep -Fxq 'ctl install-deploy restart 0.0.24' "$TEST_DIR/installer.log"
            grep -Fxq 'metadata committed' "$TEST_DIR/installer.log"
            grep -Fxq 'commit plugin state' "$TEST_DIR/installer.log"
            ;;
    esac
    [ "$(cat "$TEST_DIR/package-version")" = '0.0.24' ]
    [ "$(cat "$VOLUME_PATH/user-data")" = 'subscription data' ]
done

echo 'Remote image checks, scoped cleanup, first-install pulls, rollback and data-preservation checks passed.'
