#!/bin/sh
set -eu
umask 077

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
INSTALLER="$ROOT/run/payload/install.sh"

mkdir -p "$TMP/state/lock"
EXPECTED_STATE_INFO="$(stat -c '%F:%u:%a' "$TMP/state")"
sed -e "s|INSTALL_OPERATION_STATE=/tmp/sub-store-operation|INSTALL_OPERATION_STATE=$TMP/state|" \
    -e "s|directory:0:700|$EXPECTED_STATE_INFO|" \
    "$ROOT/run/payload/lib/install-lock.sh" > "$TMP/install-lock.sh"
. "$TMP/install-lock.sh"

# An active LuCI operation must reject a full installer without changing its lock.
printf '%s\n' "$$" > "$TMP/state/lock/pid"
if acquire_install_operation_lock > "$TMP/active-output" 2>&1; then
    echo 'Installer entered while a LuCI operation was active.' >&2
    exit 1
fi
grep -q 'Another sub-store operation is running' "$TMP/active-output"
[ "$(cat "$TMP/state/lock/pid")" = "$$" ]

# An empty lock is a startup race, not permission to reclaim another process's lock.
: > "$TMP/state/lock/pid"
if acquire_install_operation_lock > "$TMP/empty-output" 2>&1; then
    echo 'Installer entered while a LuCI operation lock was initializing.' >&2
    exit 1
fi
[ -f "$TMP/state/lock/pid" ]

# A terminated installer leaves no owner, so the next full install can reclaim
# the stale lock without waiting for a router reboot.
printf '%s\n' 2147483647 > "$TMP/state/lock/pid"
acquire_install_operation_lock
[ "$(cat "$TMP/state/lock/pid")" = "$$" ]
release_install_operation_lock
[ ! -e "$TMP/state/lock" ]

acquire_install_operation_lock
[ "$(cat "$TMP/state/lock/pid")" = "$$" ]
release_install_operation_lock
[ ! -e "$TMP/state/lock" ]

echo 'Installer operation lock: helper lifecycle checks passed.'

# Installer exit cleanup must release the shared lock on an unsuccessful exit.
if (
    . "$TMP/install-lock.sh"
    acquire_install_operation_lock
    trap 'release_install_operation_lock' EXIT
    exit 1
); then
    echo 'The simulated failed installer unexpectedly succeeded.' >&2
    exit 1
fi
[ ! -e "$TMP/state/lock" ]

# Plugin-only updates reuse the already-held LuCI lock and must not remove it.
mkdir -p "$TMP/state/lock"
printf '%s\n' "$$" > "$TMP/state/lock/pid"
SUB_STORE_PLUGIN_ONLY=1
acquire_install_operation_lock
release_install_operation_lock
[ -d "$TMP/state/lock" ]
rm -f "$TMP/state/lock/pid"
rmdir "$TMP/state/lock"

echo 'Installer operation lock: plugin-only bypass passed.'

# Verify the actual installer wires the shared guard before full-install work,
# while the plugin-only branch remains covered by the helper's explicit bypass.
grep -Fq '. "$PACKAGE_DIR/lib/install-lock.sh"' "$INSTALLER"
acquire_line="$(grep -nF 'acquire_install_operation_lock || fail' "$INSTALLER" | cut -d: -f1)"
plugin_line="$(grep -nF 'if [ "$PLUGIN_ONLY" = "1" ]; then' "$INSTALLER" | tail -n 1 | cut -d: -f1)"
[ -n "$acquire_line" ] && [ -n "$plugin_line" ] && [ "$acquire_line" -lt "$plugin_line" ]
grep -Fq 'release_install_operation_lock || true' "$INSTALLER"

echo 'Installer operation lock: installer wiring checks passed.'

# Exercise the actual installer entry without touching host system paths. The
# active case must stop before dependency setup; the idle case reaches a
# controlled missing-init-script failure and must release its acquired lock.
mkdir -p "$TMP/package" "$TMP/bin" "$TMP/entry-state/lock"
cp -R "$ROOT/run/payload/." "$TMP/package/"
ENTRY_STATE_INFO="$(stat -c '%F:%u:%a' "$TMP/entry-state")"
sed -e "s|INSTALL_OPERATION_STATE=/tmp/sub-store-operation|INSTALL_OPERATION_STATE=$TMP/entry-state|" \
    -e "s|directory:0:700|$ENTRY_STATE_INFO|" \
    "$TMP/package/lib/install-lock.sh" > "$TMP/install-lock.sh"
mv "$TMP/install-lock.sh" "$TMP/package/lib/install-lock.sh"
sed -e "s|LOG=/tmp/sub-store-run-install.log|LOG=$TMP/installer.log|" \
    -e 's|^.*Run the .run installer as root.*$|:|' \
    "$INSTALLER" > "$TMP/package/install.sh"
cat > "$TMP/bin/id" <<'EOF'
#!/bin/sh
[ "${1:-}" != "-u" ] || { printf '0\n'; exit 0; }
exit 1
EOF
cat > "$TMP/bin/opkg" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$OPKG_LOG"
EOF
cat > "$TMP/bin/docker" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TMP/bin/jsonfilter" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMP/bin/id" "$TMP/bin/opkg" "$TMP/bin/docker" "$TMP/bin/jsonfilter"
printf '%s\n' "$$" > "$TMP/entry-state/lock/pid"
if (PATH="$TMP/bin:$PATH" OPKG_LOG="$TMP/opkg.log" sh "$TMP/package/install.sh") > "$TMP/entry-active-output" 2>&1; then
    echo 'The installer entry accepted an active LuCI operation.' >&2
    exit 1
fi
if [ "$(cat "$TMP/entry-state/lock/pid")" != "$$" ]; then
    echo 'Active installer entry changed the existing lock owner:' >&2
    cat "$TMP/entry-active-output" >&2
    exit 1
fi
if [ -e "$TMP/opkg.log" ]; then
    echo 'Active installer entry proceeded to package operations:' >&2
    cat "$TMP/entry-active-output" >&2
    cat "$TMP/opkg.log" >&2
    exit 1
fi
if ! grep -q 'Another sub-store operation is running' "$TMP/entry-active-output"; then
    echo 'Active installer entry failed for an unexpected reason:' >&2
    cat "$TMP/entry-active-output" >&2
    exit 1
fi

echo 'Installer operation lock: active-operation rejection passed.'

rm -f "$TMP/entry-state/lock/pid"
rmdir "$TMP/entry-state/lock"
if (PATH="$TMP/bin:$PATH" OPKG_LOG="$TMP/opkg.log" sh "$TMP/package/install.sh") > "$TMP/entry-idle-output" 2>&1; then
    echo 'The installer entry unexpectedly passed its controlled missing-init-script failure.' >&2
    exit 1
fi
[ ! -e "$TMP/entry-state/lock" ]
grep -q 'The dockerd init service is missing' "$TMP/entry-idle-output"

echo 'Installer operation-lock boundaries passed.'
