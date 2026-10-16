#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CTL="$ROOT/run/payload/root/usr/bin/sub-storectl"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
awk '/^fail\(\) \{/ {copy=1} /^ACTION=/ {exit} copy {print}' "$CTL" > "$TEST_DIR/functions.sh"
. "$TEST_DIR/functions.sh"
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
touch "$CONFIG"
VOLUME_PATH="$TEST_DIR/volume"
mkdir -p "$VOLUME_PATH"
printf '%s\n' old-image > "$TEST_DIR/latest"
: > "$TEST_DIR/docker.log"
PULL_RESULT=same
sleep() { :; }

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
        ps) return 0 ;;
        pull)
            [ "$PULL_RESULT" = same ] || printf '%s\n' broken-image > "$TEST_DIR/latest"
            echo pulled
            ;;
        image)
            case "$2" in
                inspect) cat "$TEST_DIR/latest" ;;
                tag) printf '%s\n' "$3" > "$TEST_DIR/latest" ;;
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
                *State.Running*) echo true ;;
                *State.Status*) if [ -f "$TEST_DIR/new" ]; then echo exited; else echo running; fi ;;
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
                *'{{.Image}}'*) echo old-image ;;
                *) return 1 ;;
            esac
            ;;
        stop) return 0 ;;
        rename)
            if [ "$2" = sub-store ]; then touch "$TEST_DIR/moved"; else rm -f "$TEST_DIR/moved"; fi
            ;;
        run) touch "$TEST_DIR/new"; echo new-container ;;
        exec) return 1 ;;
        logs) echo broken-container ;;
        rm) rm -f "$TEST_DIR/new" ;;
        start) return 0 ;;
        *) return 1 ;;
    esac
}

replace_container update > "$TEST_DIR/noop-output"
grep -Fq 'already uses the latest image' "$TEST_DIR/noop-output"
if grep -Eq '(^| )stop sub-store|(^| )run ' "$TEST_DIR/docker.log"; then
    echo 'Unchanged image caused a container rebuild.' >&2
    exit 1
fi

: > "$TEST_DIR/docker.log"
touch "$TEST_DIR/health-starting"
printf '0\n' > "$TEST_DIR/health-checks"
replace_container update > "$TEST_DIR/starting-output"
grep -Fq 'Waiting for the current container health check' "$TEST_DIR/starting-output"
grep -Fq 'already uses the latest image' "$TEST_DIR/starting-output"
if grep -Eq '(^| )stop sub-store|(^| )run ' "$TEST_DIR/docker.log"; then
    echo 'Update rebuilt a current image while its health check was becoming healthy.' >&2
    exit 1
fi
rm -f "$TEST_DIR/health-starting" "$TEST_DIR/health-checks"

: > "$TEST_DIR/docker.log"
PULL_RESULT=new
result=0
if (replace_container update) > "$TEST_DIR/output" 2>&1; then
    result=0
else
    result=$?
fi
[ "$result" -ne 0 ]
[ "$(cat "$TEST_DIR/latest")" = old-image ]
grep -Fq 'image tag old-image xream/sub-store:latest' "$TEST_DIR/docker.log"
grep -Eq 'rename sub-store-rollback-[0-9-]+ sub-store' "$TEST_DIR/docker.log"
grep -Fq 'new container failed to start' "$TEST_DIR/output"
echo 'Image no-op update and failed-image rollback checks passed.'
