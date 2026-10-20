#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

awk '
    /^prepare_install_log\(\) \{/ { copy=1 }
    copy { print }
    copy && /^\}$/ { exit }
' "$ROOT/installer/payload/install.sh" > "$TEST_DIR/functions.sh"
. "$TEST_DIR/functions.sh"

printf '%s\n' protected > "$TEST_DIR/target"
mkdir -m 700 "$TEST_DIR/private-log"
ln -s "$TEST_DIR/target" "$TEST_DIR/private-log/install.log"
if prepare_install_log "$TEST_DIR/private-log"; then
    echo 'A symlinked installer log was accepted.' >&2
    exit 1
fi
[ "$(cat "$TEST_DIR/target")" = protected ]
[ -L "$TEST_DIR/private-log/install.log" ]

mkdir "$TEST_DIR/target-dir"
ln -s "$TEST_DIR/target-dir" "$TEST_DIR/private-link"
if prepare_install_log "$TEST_DIR/private-link"; then
    echo 'A symlinked installer log directory was accepted.' >&2
    exit 1
fi
[ ! -e "$TEST_DIR/target-dir/install.log" ]

mkdir -m 700 "$TEST_DIR/hardlink-log"
ln "$TEST_DIR/target" "$TEST_DIR/hardlink-log/install.log"
if prepare_install_log "$TEST_DIR/hardlink-log"; then
    echo 'A hard-linked installer log was accepted.' >&2
    exit 1
fi
[ "$(cat "$TEST_DIR/target")" = protected ]

log_path="$(prepare_install_log "$TEST_DIR/secure-log")"
[ "$log_path" = "$TEST_DIR/secure-log/install.log" ]
[ "$(stat -c '%a' "$TEST_DIR/secure-log")" = 700 ]
[ "$(stat -c '%a' "$log_path")" = 600 ]
printf '%s\n' stale > "$TEST_DIR/secure-log/install.log.stale"
printf '%s\n' old > "$log_path"
[ "$(prepare_install_log "$TEST_DIR/secure-log")" = "$log_path" ]
[ ! -e "$TEST_DIR/secure-log/install.log.stale" ]
[ ! -s "$log_path" ]
[ "$(cat "$TEST_DIR/target")" = protected ]

echo "Installer log rejects symlinks and hard links, keeps one bounded private file, and leaves targets untouched."
