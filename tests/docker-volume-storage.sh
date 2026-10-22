#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CTL="$ROOT/run/payload/root/usr/bin/sub-storectl"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
awk '/^fail\(\) \{/ {copy=1} /^ACTION=/ {exit} copy {print}' "$CTL" > "$TEST_DIR/functions.sh"
. "$TEST_DIR/functions.sh"
. "$ROOT/run/payload/root/usr/lib/sub-store/cron.sh"

FRONTEND_PORT=8081
BACKEND_PORT=8080
BACKEND_LAN_ACCESS=1
ACCESS_HOST=sub.example.test
PUBLIC_URL=""
API_PATH=0123456789abcdef0123456789abcdef0123456789abcdef
SYNC_CRON='55 23 * * *'
DATA_VOLUME=sub-store-data
INSTALL_TRANSACTION_DIR="$TEST_DIR/install-transaction"
HEALTHCHECK="$ROOT/run/payload/root/usr/lib/sub-store/healthcheck.js"
APP_VERSION_CHECK="$ROOT/run/payload/root/usr/lib/sub-store/app-version.js"
IMAGE_REF=xream/sub-store:latest
RUN_IMAGE_REF="$IMAGE_REF"
MOCK_VOLUME_PATH="$TEST_DIR/docker-root/volumes/$DATA_VOLUME/_data"
MOCK_CONTAINER=0
MOCK_MERGE=""
MOCK_FRONTEND_MAPPING=""
MOCK_BACKEND_MAPPING=""
MOCK_CONTAINER_DATA_PATH=""
MOCK_CONTAINER_RUNNING=true
DOCKER_ARGS="$TEST_DIR/docker-args"
DOCKER_LOG="$TEST_DIR/docker-log"
MOCK_APP_LOGS="$TEST_DIR/app.log"
MOCK_LOG_DRIVER=json-file
MOCK_LOG_PATH="$TEST_DIR/sub-store-runtime.log"
MOCK_REPO_DIGEST=""
uci() {
    case "$*" in
        '-q get network.lan.ipaddr') printf '%s\n' 192.0.2.1 ;;
        *) return 1 ;;
    esac
}

docker() {
    printf '%s\n' "$*" >> "$DOCKER_LOG"
    case "$1" in
        info) return 0 ;;
        image)
            case "$2" in
                inspect)
                    case "$3" in
                        -f)
                            case "$4" in
                                *RepoDigests*) [ -z "$MOCK_REPO_DIGEST" ] || printf '%s\n' "$MOCK_REPO_DIGEST" ;;
                                *Id*) printf '%s\n' mock-image-id ;;
                            esac
                            ;;
                    esac
                    ;;
            esac
            ;;
        volume)
            case "$2" in
                inspect)
                    [ -d "$MOCK_VOLUME_PATH" ] || return 1
                    if [ "${3:-}" = '-f' ]; then printf '%s\n' "$MOCK_VOLUME_PATH"; fi
                    ;;
                create) mkdir -p "$MOCK_VOLUME_PATH"; printf '%s\n' "$DATA_VOLUME" ;;
                rm) rm -f "$MOCK_VOLUME_PATH/storage.json"; rmdir "$MOCK_VOLUME_PATH" ;;
                *) return 1 ;;
            esac
            ;;
        inspect)
            if [ "${2:-}" = '-f' ]; then
                case "$3" in
                    *State.Status*) [ "$MOCK_CONTAINER_RUNNING" = true ] && printf '%s\n' running || printf '%s\n' exited ;;
                    *State.Running*) printf '%s\n' "$MOCK_CONTAINER_RUNNING" ;;
                    *Config.Image*) printf '%s\n' xream/sub-store:latest ;;
                    *HostConfig.LogConfig.Type*) printf '%s\n' "$MOCK_LOG_DRIVER" ;;
                    *LogPath*) printf '%s\n' "$MOCK_LOG_PATH" ;;
                    *Config.Env*) if [ -n "$MOCK_MERGE" ]; then printf 'SUB_STORE_BACKEND_MERGE=%s\n' "$MOCK_MERGE"; fi ;;
                    *Mounts*) printf '%s\n' "$MOCK_CONTAINER_DATA_PATH" ;;
                    *) return 1 ;;
                esac
            else
                [ "$MOCK_CONTAINER" = 1 ]
            fi
            ;;
        port)
            case "$3" in
                3001/tcp) mapping="$MOCK_FRONTEND_MAPPING" ;;
                3000/tcp) mapping="$MOCK_BACKEND_MAPPING" ;;
                *) return 1 ;;
            esac
            if [ -n "$mapping" ]; then printf '0.0.0.0:%s\n' "$mapping"; fi
            ;;
        run) printf '%s\n' "$@" > "$DOCKER_ARGS"; printf '%s\n' mock-container ;;
        exec) return 0 ;;
        logs) cat "$MOCK_APP_LOGS" ;;
        stop) MOCK_CONTAINER_RUNNING=false; return 0 ;;
        start) MOCK_CONTAINER_RUNNING=true; return 0 ;;
        rm|rename) return 0 ;;
        *) return 1 ;;
    esac
}

cat > "$MOCK_APP_LOGS" <<'EOF'
Sub-Store -- v2.42.3
startup output
Sub-Store -- v2.42.4
EOF
[ "$(show_app_version)" = "2.42.4" ]
grep -Fxq 'logs --tail 100 sub-store' "$DOCKER_LOG"
MOCK_REPO_DIGEST="xream/sub-store@sha256:$(printf 'a%.0s' $(seq 1 64))"
[ "$(resolve_official_digest xream/sub-store:latest)" = "$MOCK_REPO_DIGEST" ]
assert_official_image_ref "$MOCK_REPO_DIGEST"
if (assert_official_image_ref 'xream/sub-store@sha256:bad') >/dev/null 2>&1; then
    echo 'An invalid official image digest was accepted.' >&2
    exit 1
fi
MOCK_REPO_DIGEST=""

valid_config
if (BACKEND_PORT=8081; valid_config) >/dev/null 2>&1; then
    echo 'Equal frontend and backend ports were accepted.' >&2
    exit 1
fi
expected="http://$ACCESS_HOST:8081/?api=http%3A%2F%2F$ACCESS_HOST%3A8081%2F$API_PATH"
[ "$(show_url)" = "$expected" ]
[ "$(show_api_url)" = "http://$ACCESS_HOST:8080/$API_PATH" ]
PUBLIC_URL=https://sub.example.test/base
[ "$(show_url)" = "https://sub.example.test/base/?api=https%3A%2F%2Fsub.example.test%2Fbase%2F$API_PATH" ]
PUBLIC_URL='https://sub.example.test/a&b+c=d'
[ "$(show_url)" = "https://sub.example.test/a&b+c=d/?api=https%3A%2F%2Fsub.example.test%2Fa%26b%2Bc%3Dd%2F$API_PATH" ]
printf '%s' "$(frontend_cors_origins)" | grep -Fq 'https://sub.example.test'
PUBLIC_URL=""
MOCK_CONTAINER=1
MOCK_FRONTEND_MAPPING=9091
MOCK_BACKEND_MAPPING=9090
[ "$(show_url)" = "http://$ACCESS_HOST:9091/?api=http%3A%2F%2F$ACCESS_HOST%3A9091%2F$API_PATH" ]
[ "$(show_api_url)" = "http://$ACCESS_HOST:9090/$API_PATH" ]
MOCK_MERGE=true
MOCK_FRONTEND_MAPPING=""
[ "$(show_url)" = "http://$ACCESS_HOST:9090/?api=http%3A%2F%2F$ACCESS_HOST%3A9090%2F$API_PATH" ]
MOCK_CONTAINER_DATA_PATH=/actual/docker/volume/sub-store-data/_data
[ "$(show_storage_path)" = "$MOCK_CONTAINER_DATA_PATH" ]
MOCK_CONTAINER_DATA_PATH=""

MOCK_CONTAINER=0
MOCK_MERGE=""
ensure_data_volume
[ "$VOLUME_PATH" = "$MOCK_VOLUME_PATH" ]
[ "$(show_storage_path)" = "$MOCK_VOLUME_PATH" ]
run_container
grep -Fxq '8081:3001' "$DOCKER_ARGS"
grep -Fxq '8080:3000' "$DOCKER_ARGS"
grep -Fxq 'no-new-privileges:true' "$DOCKER_ARGS"
grep -Fxq 'SUB_STORE_BACKEND_MERGE=' "$DOCKER_ARGS"
grep -Fxq 'sub-store-data:/opt/app/data' "$DOCKER_ARGS"
grep -Fxq 'json-file' "$DOCKER_ARGS"
grep -Fxq 'max-size=1m' "$DOCKER_ARGS"
grep -Fxq 'max-file=1' "$DOCKER_ARGS"
grep -Fxq '60s' "$DOCKER_ARGS"
grep -Fxq '30s' "$DOCKER_ARGS"
grep -Fq 'http://sub.example.test:8081' "$DOCKER_ARGS"
BACKEND_LAN_ACCESS=0
[ "$(show_api_url)" = "http://127.0.0.1:8080/$API_PATH" ]
run_container
grep -Fxq '127.0.0.1:8080:3000' "$DOCKER_ARGS"
BACKEND_LAN_ACCESS=1

mkdir -p "$TEST_DIR/operation/lock"
printf '%s\n' clear-runtime-logs > "$TEST_DIR/operation/action"
sed -i "s|/tmp/sub-store-operation|$TEST_DIR/operation|g" "$TEST_DIR/functions.sh"
. "$TEST_DIR/functions.sh"
MOCK_CONTAINER=1
printf '%s\n' 'Sub-Store runtime output' > "$MOCK_LOG_PATH"
clear_runtime_logs >/dev/null
[ ! -s "$MOCK_LOG_PATH" ]
[ "$MOCK_CONTAINER_RUNNING" = true ]
[ -d "$VOLUME_PATH" ]
grep -Fq 'stop -t 10 sub-store' "$DOCKER_LOG"
grep -Fq 'start sub-store' "$DOCKER_LOG"
MOCK_CONTAINER_RUNNING=false
printf '%s\n' 'stopped runtime output' > "$MOCK_LOG_PATH"
start_count="$(grep -c '^start sub-store$' "$DOCKER_LOG")"
clear_runtime_logs >/dev/null
[ ! -s "$MOCK_LOG_PATH" ]
[ "$MOCK_CONTAINER_RUNNING" = false ]
[ "$(grep -c '^start sub-store$' "$DOCKER_LOG")" = "$start_count" ]
MOCK_LOG_DRIVER=local
printf '%s\n' 'must be preserved' > "$MOCK_LOG_PATH"
if (clear_runtime_logs) >/dev/null 2>&1; then
    echo 'Runtime logs were cleared with an unsupported logging driver.' >&2
    exit 1
fi
grep -Fxq 'must be preserved' "$MOCK_LOG_PATH"
MOCK_LOG_DRIVER=json-file
printf '%s\n' clear-maintenance-logs > "$TEST_DIR/operation/action"
printf '%s\n' 'old maintenance output' > "$TEST_DIR/operation/output.log"
printf '%s\n' 'runtime output remains' > "$MOCK_LOG_PATH"
clear_local_logs
[ ! -s "$TEST_DIR/operation/output.log" ]
grep -Fxq 'runtime output remains' "$MOCK_LOG_PATH"
[ -d "$VOLUME_PATH" ]

mkdir "$TEST_DIR/legacy-data"
printf '%s\n' '{"test":"preserved"}' > "$TEST_DIR/legacy-data/storage.json"
copy_directory_to_volume "$TEST_DIR/legacy-data"
cmp "$TEST_DIR/legacy-data/storage.json" "$VOLUME_PATH/storage.json"
if copy_directory_to_volume "$TEST_DIR/legacy-data" >/dev/null 2>&1; then
    echo 'Migration overwrote an occupied destination volume.' >&2
    exit 1
fi
cmp "$TEST_DIR/legacy-data/storage.json" "$VOLUME_PATH/storage.json"
if copy_directory_to_volume "$TEST_DIR" >/dev/null 2>&1; then
    echo 'Migration accepted a source containing the Docker volume.' >&2
    exit 1
fi
MOCK_CONTAINER=1
HAD_OLD_CONTAINER=1
BACKUP_NAME=sub-store-test-rollback
OLD_WAS_RUNNING=1
PREVIOUS_FRONTEND_PORT=""
PREVIOUS_BACKEND_PORT=""
PREVIOUS_API_PATH=""
PREVIOUS_SYNC_CRON=""
VOLUME_MIGRATION_IN_PROGRESS=0
PREVIOUS_IMAGE_ID=""
rollback_replacement
[ -f "$VOLUME_PATH/storage.json" ]
VOLUME_MIGRATION_IN_PROGRESS=1
rollback_replacement
[ ! -d "$VOLUME_PATH" ]
[ -f "$TEST_DIR/legacy-data/storage.json" ]
grep -Fxq 'rename sub-store-test-rollback sub-store' "$DOCKER_LOG"
grep -Fxq 'start sub-store' "$DOCKER_LOG"
echo 'Docker storage, port, URL and migration checks passed.'
