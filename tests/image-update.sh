#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CTL="$ROOT/installer/payload/root/usr/bin/sub-storectl"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
awk '/^fail\(\) \{/ {copy=1} /^ACTION=/ {exit} copy {print}' "$CTL" > "$TEST_DIR/functions.sh"
. "$TEST_DIR/functions.sh"
. "$ROOT/installer/payload/root/usr/lib/sub-store/cron.sh"
render_config() { valid_config; }

FRONTEND_PORT=3001
BACKEND_PORT=3000
BACKEND_LAN_ACCESS=1
ACCESS_HOST=""
PUBLIC_URL=""
API_PATH=0123456789abcdef0123456789abcdef0123456789abcdef
SYNC_CRON='55 23 * * *'
DATA_VOLUME=sub-store-data
HEALTHCHECK="$ROOT/installer/payload/root/usr/lib/sub-store/healthcheck.js"
APP_VERSION_CHECK="$ROOT/installer/payload/root/usr/lib/sub-store/app-version.js"
IMAGE_REF=xream/sub-store:latest
RUN_IMAGE_REF="$IMAGE_REF"
CONFIG="$TEST_DIR/sub-store.config"
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

cp() {
    if [ "${FAIL_DATA_COPY:-0}" = 1 ] && [ "$1" = "-a" ]; then
        mkdir -p "$3"
        printf '%s\n' partial > "$3/partial-copy"
        return 1
    fi
    command cp "$@"
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
            [ "$PULL_RESULT" != failed ] || return 1
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
                            if [ "$CLEANUP_CASE" = same-repository-tagged ]; then
                                echo 'tag xream/sub-store:backup'
                                echo "digest xream/sub-store@$OLD_IMAGE_ID"
                            else
                                [ "$CLEANUP_CASE" = dangling ] || echo "digest xream/sub-store@$OLD_IMAGE_ID"
                                [ "$CLEANUP_CASE" != tagged ] || echo 'tag user/keep:backup'
                            fi
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
                rm)
                    if [ "${MIGRATION_TEST:-0}" = 1 ]; then
                        [ -f "$VOLUME_PATH/partial-copy" ] || return 1
                        rm -rf "$VOLUME_PATH"
                        touch "$TEST_DIR/migration-volume-removed"
                    fi
                    return 0
                    ;;
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
                *State.Running*)
                    if [ "${SIGNAL_TEST:-0}" = 1 ]; then
                        [ ! -f "$TEST_DIR/stopped" ] && echo true
                    else
                        [ "$CONTAINER_STATE" != running ] || echo true
                    fi
                    ;;
                *State.Status*)
                    if [ -f "$TEST_DIR/new" ] && [ "$NEW_HEALTHY" != 1 ]; then echo exited; else echo "$CONTAINER_STATE"; fi
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
                *Mounts*Type*) echo "${OLD_MOUNT_TYPE-volume}" ;;
                *Mounts*Name*) echo "${OLD_MOUNT_NAME-$DATA_VOLUME}" ;;
                *Mounts*Source*) echo "${OLD_MOUNT_SOURCE-$VOLUME_PATH}" ;;
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
        stop)
            [ "${SIGNAL_TEST:-0}" != 1 ] || touch "$TEST_DIR/stopped"
            return 0
            ;;
        rename)
            if [ "$2" = sub-store ]; then touch "$TEST_DIR/moved"; else rm -f "$TEST_DIR/moved"; fi
            ;;
        run)
            if [ "${SIGNAL_TEST:-0}" = 1 ]; then
                touch "$TEST_DIR/run-reached"
                while [ ! -f "$TEST_DIR/run-release" ]; do command sleep 0.05; done
            fi
            touch "$TEST_DIR/new"
            echo new-container
            ;;
        cp)
            if [ "${FAIL_DATA_COPY:-0}" = 1 ]; then
                printf '%s\n' partial > "$VOLUME_PATH/partial-copy"
                return 1
            fi
            cat "$TEST_DIR/container-data" > "$VOLUME_PATH/subscriptions.yaml"
            ;;
        exec) [ "$NEW_HEALTHY" = 1 ] ;;
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
        start)
            if [ "${SIGNAL_TEST:-0}" = 1 ]; then
                rm -f "$TEST_DIR/stopped"
                touch "$TEST_DIR/started"
            fi
            return 0
            ;;
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
        update_image > "$TEST_DIR/unchanged-output"
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

(
    : > "$TEST_DIR/docker.log"
    PULL_RESULT=failed
    REGISTRY_MODE=new
    if (update_image) > "$TEST_DIR/pull-failed" 2>&1; then
        echo 'A Docker pull failure was accepted.' >&2
        exit 1
    fi
    grep -Fq 'could not pull the sub-store image' "$TEST_DIR/pull-failed"
    ! grep -Eq '^(stop|rename|run|rm) ' "$TEST_DIR/docker.log"
    [ "$(cat "$TEST_DIR/latest")" = "$OLD_IMAGE_ID" ]
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

(
    SIGNAL_TEST=1
    HAD_OLD_CONTAINER=1
    OLD_WAS_RUNNING=1
    REPLACEMENT_COMMITTED=0
    BACKUP_NAME=sub-store-rollback-test
    VOLUME_MIGRATION_IN_PROGRESS=0
    PREVIOUS_IMAGE_ID="$OLD_IMAGE_ID"
    PREVIOUS_FRONTEND_PORT=""
    PREVIOUS_BACKEND_PORT=""
    PREVIOUS_API_PATH=""
    PREVIOUS_SYNC_CRON=""
    : > "$TEST_DIR/docker.log"
    rm -f "$TEST_DIR/new" "$TEST_DIR/started"
    touch "$TEST_DIR/moved" "$TEST_DIR/stopped"

    if (handle_replacement_signal 143) > "$TEST_DIR/signal-handler-output" 2>&1; then
        echo 'The replacement signal handler returned success instead of the TERM status.' >&2
        exit 1
    else
        signal_status=$?
    fi
    [ "$signal_status" -eq 143 ]
    [ ! -f "$TEST_DIR/moved" ]
    [ ! -f "$TEST_DIR/stopped" ]
    [ -f "$TEST_DIR/started" ]
    grep -Fq 'rename sub-store-rollback-test sub-store' "$TEST_DIR/docker.log"
    grep -Fxq 'start sub-store' "$TEST_DIR/docker.log"
)

(
    SIGNAL_TEST=1
    HAD_OLD_CONTAINER=1
    OLD_WAS_RUNNING=1
    REPLACEMENT_COMMITTED=0
    BACKUP_NAME=sub-store-rollback-test
    PREVIOUS_IMAGE_ID="$OLD_IMAGE_ID"
    PREVIOUS_FRONTEND_PORT=""
    PREVIOUS_BACKEND_PORT=""
    PREVIOUS_API_PATH=""
    PREVIOUS_SYNC_CRON=""
    : > "$TEST_DIR/docker.log"
    rm -f "$TEST_DIR/moved" "$TEST_DIR/new" "$TEST_DIR/started"
    touch "$TEST_DIR/stopped"

    if (handle_replacement_signal 143) > "$TEST_DIR/signal-handler-output" 2>&1; then
        echo 'The replacement signal handler returned success instead of the TERM status.' >&2
        exit 1
    else
        signal_status=$?
    fi
    [ "$signal_status" -eq 143 ]
    [ ! -f "$TEST_DIR/stopped" ]
    [ -f "$TEST_DIR/started" ]
    grep -Fxq 'start sub-store' "$TEST_DIR/docker.log"
)

(
    SIGNAL_TEST=1
    HAD_OLD_CONTAINER=1
    OLD_WAS_RUNNING=1
    REPLACEMENT_COMMITTED=1
    BACKUP_NAME=sub-store-rollback-test
    PREVIOUS_IMAGE_ID="$OLD_IMAGE_ID"
    : > "$TEST_DIR/docker.log"
    touch "$TEST_DIR/moved" "$TEST_DIR/new"
    rm -f "$TEST_DIR/stopped" "$TEST_DIR/started"

    if (handle_replacement_signal 143) > "$TEST_DIR/signal-handler-output" 2>&1; then
        echo 'The committed replacement handler returned success instead of the TERM status.' >&2
        exit 1
    else
        signal_status=$?
    fi
    [ "$signal_status" -eq 143 ]
    [ -f "$TEST_DIR/moved" ]
    [ -f "$TEST_DIR/new" ]
    ! grep -Eq '^(rm|rename|start) ' "$TEST_DIR/docker.log"
)

run_replacement_signal_test=1
case "$(uname -s)" in
    MINGW*|MSYS*) [ "${RUN_REPLACEMENT_SIGNAL_TEST:-0}" = 1 ] || run_replacement_signal_test=0 ;;
esac
if [ "$run_replacement_signal_test" = 1 ]; then
    (
        SIGNAL_TEST=1
        NEW_HEALTHY=1
        PULL_RESULT=new
        REGISTRY_MODE=new
        printf '%s\n' "$OLD_IMAGE_ID" > "$TEST_DIR/latest"
        : > "$TEST_DIR/docker.log"
        rm -f "$TEST_DIR/moved" "$TEST_DIR/new" "$TEST_DIR/stopped" "$TEST_DIR/started" "$TEST_DIR/run-reached"
        rm -f "$TEST_DIR/run-release"

        update_image > "$TEST_DIR/signal-output" 2>&1 &
        update_pid=$!
        attempts=0
        while [ ! -f "$TEST_DIR/run-reached" ]; do
            if ! kill -0 "$update_pid" 2>/dev/null; then
                cat "$TEST_DIR/signal-output" >&2
                echo 'Image update exited before reaching the controlled replacement point.' >&2
                exit 1
            fi
            attempts=$((attempts + 1))
            [ "$attempts" -lt 200 ] || {
                kill -TERM "$update_pid" 2>/dev/null || true
                echo 'Image update did not reach the controlled replacement point.' >&2
                exit 1
            }
            command sleep 0.02
        done

        kill -TERM "$update_pid"
        # Let the in-flight docker run return so the shell can dispatch its pending signal trap.
        touch "$TEST_DIR/run-release"
        if wait "$update_pid"; then
            echo 'Image update ignored TERM while replacing the container.' >&2
            exit 1
        fi
        [ ! -f "$TEST_DIR/moved" ] || {
            cat "$TEST_DIR/docker.log" >&2
            echo 'Interrupted image update left the previous container renamed and stopped.' >&2
            exit 1
        }
        [ -f "$TEST_DIR/started" ] || {
            cat "$TEST_DIR/docker.log" >&2
            echo 'Interrupted image update did not restart the previous container.' >&2
            exit 1
        }
        ! grep -q '^image rm ' "$TEST_DIR/docker.log"
    )
fi

for cleanup_case in unused dangling shared tagged same-repository-tagged inspect-failed current-inspect-failed usage-failed remove-failed backup-failed single; do
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
            unused|dangling|single)
                [ -f "$TEST_DIR/image-removed" ]
                grep -Fxq "image rm --no-prune $OLD_IMAGE_ID" "$TEST_DIR/docker.log"
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

for migration_case in bind-success bind-copy-failed bind-volume-alias container-copy-success container-copy-failed; do
    (
        migration_root="$TEST_DIR/$migration_case"
        VOLUME_PATH="$migration_root/volume"
        DATA_VOLUME="sub-store-data-$migration_case"
        MIGRATION_TEST=1
        NEW_HEALTHY=1
        PULL_RESULT=new
        REGISTRY_MODE=new
        expected_data='original subscription data'
        case "$migration_case" in
            bind-volume-alias)
                OLD_MOUNT_TYPE=bind
                OLD_MOUNT_SOURCE="$migration_root/volume-alias"
                if ! ln -s "$VOLUME_PATH" "$OLD_MOUNT_SOURCE" 2>/dev/null ||
                    [ ! -L "$OLD_MOUNT_SOURCE" ]; then
                    exit 0
                fi
                ;;
            bind-*)
                OLD_MOUNT_TYPE=bind
                OLD_MOUNT_SOURCE="$migration_root/legacy-data"
                mkdir -p "$OLD_MOUNT_SOURCE"
                printf '%s\n' "$expected_data" > "$OLD_MOUNT_SOURCE/subscriptions.yaml"
                ;;
            container-*)
                OLD_MOUNT_TYPE=
                OLD_MOUNT_SOURCE=
                printf '%s\n' "$expected_data" > "$TEST_DIR/container-data"
                ;;
        esac
        mkdir -p "$VOLUME_PATH"
        printf '%s\n' "$OLD_IMAGE_ID" > "$TEST_DIR/latest"
        : > "$TEST_DIR/docker.log"
        rm -f "$TEST_DIR/migration-volume-removed"

        case "$migration_case" in
          bind-volume-alias)
            if update_image > "$TEST_DIR/migration-output" 2>&1; then
                echo 'A bind mount aliasing the new Docker volume was accepted.' >&2
                exit 1
            fi
            grep -Fq 'existing data paths overlap; refusing recursive copy' "$TEST_DIR/migration-output" || {
                cat "$TEST_DIR/migration-output" >&2
                echo 'An overlapping bind mount source was not rejected.' >&2
                exit 1
            }
            if grep -Eq '^(pull|stop|rename|run) ' "$TEST_DIR/docker.log"; then
                cat "$TEST_DIR/docker.log" >&2
                echo 'Container or image operations began before rejecting overlapping paths.' >&2
                exit 1
            fi
            [ -d "$VOLUME_PATH" ] && [ -L "$OLD_MOUNT_SOURCE" ]
            [ ! -f "$TEST_DIR/new" ]
            ;;
          *-failed)
            FAIL_DATA_COPY=1
            if (update_image) > "$TEST_DIR/migration-output" 2>&1; then
                echo "A failed data migration was accepted: $migration_case" >&2
                exit 1
            fi
            expected_error='could not copy existing data into Docker volume'
            case "$migration_case" in
                container-*) expected_error='could not copy data from the existing container into Docker volume' ;;
            esac
            grep -Fq "$expected_error" "$TEST_DIR/migration-output" || {
                cat "$TEST_DIR/migration-output" >&2
                cat "$TEST_DIR/docker.log" >&2
                echo 'A failed data copy did not follow the expected rollback path.' >&2
                exit 1
            }
            [ -f "$TEST_DIR/migration-volume-removed" ] || {
                cat "$TEST_DIR/docker.log" >&2
                echo 'Rollback did not discard the partial destination volume.' >&2
                exit 1
            }
            [ ! -e "$VOLUME_PATH" ] || {
                echo 'Rollback left the partial destination volume behind.' >&2
                exit 1
            }
            grep -Eq 'rename sub-store-rollback-[0-9-]+ sub-store' "$TEST_DIR/docker.log" || {
                cat "$TEST_DIR/docker.log" >&2
                echo 'Rollback did not restore the previous container.' >&2
                exit 1
            }
            grep -Fxq 'start sub-store' "$TEST_DIR/docker.log" || {
                cat "$TEST_DIR/docker.log" >&2
                echo 'Rollback did not restart the previously running container.' >&2
                exit 1
            }
            if [ -n "$OLD_MOUNT_SOURCE" ]; then
                [ "$(cat "$OLD_MOUNT_SOURCE/subscriptions.yaml")" = "$expected_data" ]
            else
                [ "$(cat "$TEST_DIR/container-data")" = "$expected_data" ]
            fi
            ;;
          *)
            FAIL_DATA_COPY=0
            update_image > "$TEST_DIR/migration-output" 2>&1
            [ -f "$TEST_DIR/new" ]
            [ "$(cat "$VOLUME_PATH/subscriptions.yaml" 2>/dev/null || true)" = "$expected_data" ] || {
                cat "$TEST_DIR/migration-output" >&2
                cat "$TEST_DIR/docker.log" >&2
                echo "Successful data migration did not copy the original data: $migration_case" >&2
                exit 1
            }
            if [ -n "$OLD_MOUNT_SOURCE" ]; then
                [ "$(cat "$OLD_MOUNT_SOURCE/subscriptions.yaml")" = "$expected_data" ]
            else
                [ "$(cat "$TEST_DIR/container-data")" = "$expected_data" ]
            fi
            [ ! -f "$TEST_DIR/migration-volume-removed" ]
            ;;
        esac
    )
done

awk '/^step 5 / {copy=1; next} /^step 6 / {exit} copy {print}' "$ROOT/installer/payload/install.sh" |
    sed -e 's|/usr/bin/sub-storectl|test_ctl|g' \
        -e 's|/etc/init.d/sub-store|test_init|g' \
        -e "s|/etc/sub-store/installed|$TEST_DIR/installer-installed|g" \
        -e "s|/etc/config/sub-store|$CONFIG|g" > "$TEST_DIR/install-deployment.sh"

for install_case in fresh cached pull-failed managed existing; do
    rm -f "$TEST_DIR/installer-installed"
    : > "$TEST_DIR/installer.log"
    if (
        EXISTING=0
        case "$install_case" in
            managed) EXISTING=1; touch "$TEST_DIR/installer-installed" ;;
            existing) EXISTING=1 ;;
        esac
        say() { :; }
        uci() {
            printf 'uci %s\n' "$*" >> "$TEST_DIR/installer.log"
            case "$*" in '-q get sub-store.main.data_dir') return 1 ;; esac
        }
        test_ctl() {
            printf 'ctl %s\n' "$*" >> "$TEST_DIR/installer.log"
            if [ "$1" = pull ]; then
                [ "$install_case" != pull-failed ] || return 1
            fi
        }
        test_init() { printf 'init %s\n' "$*" >> "$TEST_DIR/installer.log"; }
        . "$TEST_DIR/install-deployment.sh"
    ) > "$TEST_DIR/install-output" 2>&1; then
        [ "$install_case" != pull-failed ]
    else
        [ "$install_case" = pull-failed ]
        ! grep -q '^init ' "$TEST_DIR/installer.log"
        ! grep -q '^uci set sub-store.main.image_ref=' "$TEST_DIR/installer.log"
        continue
    fi
    case "$install_case" in
        fresh|cached)
            grep -Fxq 'ctl pull' "$TEST_DIR/installer.log"
            grep -Fxq 'uci set sub-store.main.image_ref=xream/sub-store:latest' "$TEST_DIR/installer.log"
            pull_line="$(grep -n '^ctl pull$' "$TEST_DIR/installer.log" | cut -d: -f1)"
            start_line="$(grep -n '^init start$' "$TEST_DIR/installer.log" | cut -d: -f1)"
            [ "$pull_line" -lt "$start_line" ]
            ;;
        managed) ! grep -q '^ctl pull$' "$TEST_DIR/installer.log"; grep -Fxq 'ctl update' "$TEST_DIR/installer.log" ;;
        existing) ! grep -q '^ctl pull$' "$TEST_DIR/installer.log"; grep -Fxq 'ctl restart' "$TEST_DIR/installer.log" ;;
    esac
    [ "$(cat "$VOLUME_PATH/user-data")" = 'subscription data' ]
done

echo 'Remote image checks, scoped cleanup, first-install pulls, rollback and data-preservation checks passed.'
