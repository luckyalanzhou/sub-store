#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
cleanup() { command rm -rf "$TEST_DIR"; }
trap cleanup EXIT
TEST_ROOT="$TEST_DIR/root"
mkdir -p "$TEST_ROOT/usr/lib/sub-store"
touch "$TEST_ROOT/usr/lib/sub-store/registry-image.sh" \
    "$TEST_ROOT/usr/lib/sub-store/export-data" \
    "$TEST_ROOT/usr/lib/sub-store/status"

awk '/^uninstall_plugin\(\) \{/ { copying=1 } /^ACTION=/ { exit } copying { print }' \
    "$ROOT/run/payload/root/usr/bin/sub-storectl" > "$TEST_DIR/uninstall.sh"

daemon_ready() { :; }
docker() {
    case "$*" in
        'inspect sub-store'|'volume inspect sub-store-data') return 1 ;;
        *) echo "Unexpected Docker command: $*" >&2; return 1 ;;
    esac
}
rm() {
    operation="$1"
    shift
    case "$operation" in -f|-rf) ;; *) echo "Unexpected rm option: $operation" >&2; return 1 ;; esac
    for target in "$@"; do
        case "$target" in
            /*) command rm "$operation" "$TEST_ROOT$target" ;;
            *) echo "Unexpected uninstall target: $target" >&2; return 1 ;;
        esac
    done
}

DATA_VOLUME=sub-store-data
. "$TEST_DIR/uninstall.sh"
uninstall_plugin --keep-data >/dev/null

[ ! -e "$TEST_ROOT/usr/lib/sub-store/registry-image.sh" ]
[ ! -e "$TEST_ROOT/usr/lib/sub-store/export-data" ]

echo 'Uninstall removes standalone helper modules without deleting user data.'
