#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
awk '
    /^plugin_target_path\(\) \{/ { copy=1 }
    /^rollback_plugin_update\(\) \{/ { copy=1 }
    copy { print }
    copy && /^\}$/ { copy=0 }
' "$ROOT/run/payload/install.sh" > "$TEST_DIR/functions.sh"
. "$TEST_DIR/functions.sh"
say() { :; }
refresh_luci_cache() { :; }

PLUGIN_TARGET_PREFIX="$TEST_DIR/root"
PLUGIN_BACKUP_DIR="$TEST_DIR/backup"
PLUGIN_UPDATE_ACTIVE=1
mkdir -p "$PLUGIN_TARGET_PREFIX/usr/bin" "$PLUGIN_TARGET_PREFIX/usr/lib/sub-store" \
    "$PLUGIN_BACKUP_DIR/files/usr/bin"
printf '%s\n' broken > "$PLUGIN_TARGET_PREFIX/usr/bin/sub-storectl"
printf '%s\n' new > "$PLUGIN_TARGET_PREFIX/usr/lib/sub-store/new-file"
printf '%s\n' restored > "$PLUGIN_BACKUP_DIR/files/usr/bin/sub-storectl"
cat > "$PLUGIN_BACKUP_DIR/states" <<'EOF'
present usr/bin/sub-storectl
absent usr/lib/sub-store/new-file
EOF
rollback_plugin_update
[ "$(cat "$PLUGIN_TARGET_PREFIX/usr/bin/sub-storectl")" = restored ]
[ ! -e "$PLUGIN_TARGET_PREFIX/usr/lib/sub-store/new-file" ]
[ "$PLUGIN_UPDATE_ACTIVE" = 0 ]
[ -z "$PLUGIN_BACKUP_DIR" ]

PLUGIN_BACKUP_DIR="$TEST_DIR/incomplete-backup"
PLUGIN_UPDATE_ACTIVE=1
mkdir -p "$PLUGIN_BACKUP_DIR/files"
printf '%s\n' 'present usr/bin/missing-backup' > "$PLUGIN_BACKUP_DIR/states"
if rollback_plugin_update; then
    echo 'Rollback unexpectedly succeeded without its old file.' >&2
    exit 1
fi
[ -d "$PLUGIN_BACKUP_DIR" ]
[ "$PLUGIN_UPDATE_ACTIVE" = 1 ]
echo 'Plugin update rollback and recovery retention checks passed.'
