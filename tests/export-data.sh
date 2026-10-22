#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
REAL_MKTEMP="$(which mktemp)"
REAL_TAR="$(which tar)"
REAL_MV="$(which mv)"
BIN="$TEST_DIR/bin"
MOCK_VOLUME_PATH="$TEST_DIR/data-volume"
MOCK_PAUSED_STATE="$TEST_DIR/container-paused"
DOCKER_LOG="$TEST_DIR/docker.log"
TAR_MODE_AT_CREATE_CAPTURE="$TEST_DIR/tar-mode-at-create"
MOCK_EXPORT_LINK="$TEST_DIR/export-link"
MOCK_EXPORT_RACE=0
MOCK_TAR_SKIP=0
mkdir -p "$BIN" "$MOCK_VOLUME_PATH"
printf '%s\n' '{"user":"data"}' > "$MOCK_VOLUME_PATH/storage.json"
printf '%s\n' false > "$MOCK_PAUSED_STATE"
printf '%s\n' 'test configuration' > "$TEST_DIR/config"

cat > "$TEST_DIR/openwrt-functions.sh" <<'EOF'
config_load() { :; }
config_get() { eval "$1='${4:-}'"; }
config_get_bool() { eval "$1='${4:-}'"; }
EOF

sed \
    -e "s|/etc/config/sub-store|$TEST_DIR/config|g" \
    -e "s|/lib/functions.sh|$TEST_DIR/openwrt-functions.sh|g" \
    -e "s|/usr/lib/sub-store/cron.sh|$ROOT/run/payload/root/usr/lib/sub-store/cron.sh|g" \
    -e "s|/usr/lib/sub-store/registry-image.sh|$ROOT/run/payload/root/usr/lib/sub-store/registry-image.sh|g" \
    -e "s|/usr/lib/sub-store/export-data|$TEST_DIR/export-data|g" \
    "$ROOT/run/payload/root/usr/bin/sub-storectl" > "$TEST_DIR/sub-storectl"
cp "$ROOT/run/payload/root/usr/lib/sub-store/export-data" "$TEST_DIR/export-data"
grep -Fq "exec $TEST_DIR/export-data" "$TEST_DIR/sub-storectl" || {
    echo 'sub-storectl did not dispatch exports through the export module.' >&2
    exit 1
}
grep -Fq 'tar -czf "$temp_file"' "$TEST_DIR/export-data" || {
    echo 'The export module does not create the expected archive.' >&2
    exit 1
}
grep -Fq 'mv -f "$temp_file" "$resolved_target"' "$TEST_DIR/export-data" || {
    echo 'The export module does not atomically replace the destination.' >&2
    exit 1
}

cat > "$BIN/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$*" in
    info) exit 0 ;;
    'volume inspect sub-store-data') [ -d "$MOCK_VOLUME_PATH" ] ;;
    'volume inspect -f {{.Mountpoint}} sub-store-data') printf '%s\n' "$MOCK_VOLUME_PATH" ;;
    'inspect -f {{.State.Running}} sub-store') printf '%s\n' true ;;
    'inspect -f {{.State.Paused}} sub-store') cat "$MOCK_PAUSED_STATE" ;;
    'pause sub-store')
        printf '%s\n' true > "$MOCK_PAUSED_STATE"
        [ "${MOCK_PAUSE_FAIL:-0}" != 1 ]
        ;;
    'unpause sub-store') printf '%s\n' false > "$MOCK_PAUSED_STATE" ;;
    *) exit 1 ;;
esac
EOF

cat > "$BIN/mktemp" <<'EOF'
#!/bin/sh
if [ "${MOCK_EXPORT_RACE:-0}" = 1 ]; then
    rm -f "$MOCK_EXPORT_LINK"
    ln -s "$MOCK_VOLUME_PATH" "$MOCK_EXPORT_LINK"
fi
created_file="$("$REAL_MKTEMP" "$@")" || exit
stat -c '%a' "$created_file" > "$TAR_MODE_AT_CREATE_CAPTURE"
printf '%s\n' "$created_file"
EOF

cat > "$BIN/tar" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-czf" ]; then
    [ "$(stat -c '%a' "$2")" = 600 ] || exit 81
    if [ "${MOCK_TAR_SKIP:-0}" = 1 ]; then
        printf '%s\n' 'test archive' > "$2"
        exit 0
    fi
    if [ -n "${EXPORT_TARGET:-}" ]; then
        expected="${EXPORT_OLD_CONTENT:?}"
    else
        expected=""
    fi
    if [ "${MOCK_TAR_FAIL:-0}" = 1 ]; then
        printf '%s\n' 'partial archive' > "$2"
        exit 2
    fi
    "$REAL_TAR" "$@"
    if [ -n "${EXPORT_TARGET:-}" ]; then
        [ "$(cat "$EXPORT_TARGET")" = "$expected" ] || exit 82
    fi
    exit 0
fi
exec "$REAL_TAR" "$@"
EOF

cat > "$BIN/mv" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-f" ] && [ "${3:-}" = "${EXPORT_TARGET:-}" ]; then
    source_dir="$(CDPATH= cd -- "${2%/*}" && pwd -P)"
    target_dir="$(CDPATH= cd -- "${3%/*}" && pwd -P)"
    [ "$source_dir" = "$target_dir" ] || exit 83
fi
if [ "${MOCK_MV_FAIL:-0}" = 1 ] && [ "${3:-}" = "${EXPORT_TARGET:-}" ]; then
    exit 1
fi
exec "$REAL_MV" "$@"
EOF

chmod +x "$BIN/docker" "$BIN/mktemp" "$BIN/tar" "$BIN/mv" "$TEST_DIR/export-data"

run_export() {
    export PATH="$BIN:$PATH"
    export REAL_MKTEMP REAL_TAR REAL_MV MOCK_VOLUME_PATH MOCK_PAUSED_STATE
    export DOCKER_LOG TAR_MODE_AT_CREATE_CAPTURE EXPORT_TARGET
    export EXPORT_OLD_CONTENT MOCK_TAR_FAIL MOCK_PAUSE_FAIL MOCK_MV_FAIL
    export MOCK_EXPORT_LINK MOCK_EXPORT_RACE MOCK_TAR_SKIP
    if [ "${BUSYBOX_TEST:-0}" = 1 ]; then
        busybox ash "$TEST_DIR/sub-storectl" export-data "$EXPORT_TARGET"
    else
        sh "$TEST_DIR/sub-storectl" export-data "$EXPORT_TARGET"
    fi
}

TARGET="$TEST_DIR/sub-store-data.tar.gz"
EXPORT_TARGET="$TARGET"
EXPORT_OLD_CONTENT='previous archive'
printf '%s\n' "$EXPORT_OLD_CONTENT" > "$TARGET"
run_export >/dev/null
tar -tzf "$TARGET" | grep -Eq '(^|/)storage.json$'
[ "$(cat "$TAR_MODE_AT_CREATE_CAPTURE")" = 600 ]
[ "$(cat "$MOCK_PAUSED_STATE")" = false ]

EXPORT_OLD_CONTENT='old archive after tar failure'
printf '%s\n' "$EXPORT_OLD_CONTENT" > "$TARGET"
MOCK_TAR_FAIL=1
if run_export >/dev/null 2>&1; then
    echo 'Export unexpectedly succeeded after tar failed.' >&2
    exit 1
fi
MOCK_TAR_FAIL=0
[ "$(cat "$TARGET")" = "$EXPORT_OLD_CONTENT" ]
[ "$(cat "$MOCK_PAUSED_STATE")" = false ]

EXPORT_OLD_CONTENT='old archive after pause failure'
printf '%s\n' "$EXPORT_OLD_CONTENT" > "$TARGET"
MOCK_PAUSE_FAIL=1
if run_export >/dev/null 2>&1; then
    echo 'Export unexpectedly succeeded after Docker pause failed.' >&2
    exit 1
fi
MOCK_PAUSE_FAIL=0
[ "$(cat "$TARGET")" = "$EXPORT_OLD_CONTENT" ]
[ "$(cat "$MOCK_PAUSED_STATE")" = false ]

EXPORT_OLD_CONTENT='old archive after rename failure'
printf '%s\n' "$EXPORT_OLD_CONTENT" > "$TARGET"
MOCK_MV_FAIL=1
if run_export >/dev/null 2>&1; then
    echo 'Export unexpectedly succeeded after atomic replacement failed.' >&2
    exit 1
fi
MOCK_MV_FAIL=0
[ "$(cat "$TARGET")" = "$EXPORT_OLD_CONTENT" ]
[ "$(cat "$MOCK_PAUSED_STATE")" = false ]
[ -z "$(find "$TEST_DIR" -maxdepth 1 -name '.sub-store-export.*' -print -quit)" ]

VOLUME_LINK="$TEST_DIR/volume-link"
ln -s "$MOCK_VOLUME_PATH" "$VOLUME_LINK"
if [ -L "$VOLUME_LINK" ]; then
    EXPORT_TARGET="$VOLUME_LINK/escaped.tar.gz"
    : > "$DOCKER_LOG"
    if run_export > "$TEST_DIR/volume-link-output" 2>&1; then
        echo 'Export accepted a destination hidden inside the data volume by a symlink.' >&2
        exit 1
    fi
    if ! grep -Fq 'export destination cannot be inside the data volume' "$TEST_DIR/volume-link-output"; then
        cat "$TEST_DIR/volume-link-output" >&2
        exit 1
    fi
    ! grep -Fxq 'pause sub-store' "$DOCKER_LOG"
    [ ! -e "$MOCK_VOLUME_PATH/escaped.tar.gz" ]
    [ -z "$(find "$MOCK_VOLUME_PATH" -maxdepth 1 -name '.sub-store-export.*' -print -quit)" ]

    SAFE_EXPORT_DIR="$TEST_DIR/safe-export-dir"
    mkdir "$SAFE_EXPORT_DIR"
    ln -s "$SAFE_EXPORT_DIR" "$MOCK_EXPORT_LINK"
    EXPORT_TARGET="$MOCK_EXPORT_LINK/race.tar.gz"
    EXPORT_OLD_CONTENT=""
    MOCK_EXPORT_RACE=1
    MOCK_TAR_SKIP=1
    run_export >/dev/null
    MOCK_EXPORT_RACE=0
    MOCK_TAR_SKIP=0
    [ -f "$SAFE_EXPORT_DIR/race.tar.gz" ]
    [ ! -e "$MOCK_VOLUME_PATH/race.tar.gz" ]
    [ -z "$(find "$MOCK_VOLUME_PATH" -maxdepth 1 -name '.sub-store-export.*' -print -quit)" ]
else
    echo 'Symlink destination check skipped on a host that cannot create symlinks.'
fi
printf '%s\n' 'CLI export preserves private creation, atomic replacement, old archives and container state on failures.'
