#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ORIGINAL_PATH="$PATH"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin" "$TMP/apk-system"
: > "$TMP/calls"

cat > "$TMP/bin/opkg" <<'EOF'
#!/bin/sh
printf 'opkg %s\n' "$*" >> "$TEST_PACKAGE_MANAGER_CALLS"
case "$1" in
    status) printf 'Status: install user installed\n' ;;
esac
EOF
cat > "$TMP/bin/apk" <<'EOF'
#!/bin/sh
printf 'apk %s\n' "$*" >> "$TEST_PACKAGE_MANAGER_CALLS"
if [ "${TEST_PACKAGE_MANAGER_FAIL:-}" = "$1" ]; then
    exit 1
fi
case "$1" in
    info) printf 'rpcd-mod-file\njsonfilter\n' ;;
esac
EOF
chmod +x "$TMP/bin/opkg" "$TMP/bin/apk"
export PATH="$TMP/bin:$PATH"
export TEST_PACKAGE_MANAGER_CALLS="$TMP/calls"
. "$ROOT/run/payload/lib/package-manager.sh"

# 24.10: opkg remains the selected package manager.
detect_package_manager "$TMP/no-apk-marker"
[ "$PACKAGE_MANAGER" = opkg ]
package_manager_update
package_manager_install dockerd docker
package_is_installed rpcd-mod-file
grep -Fxq 'opkg update' "$TMP/calls"
grep -Fxq 'opkg install dockerd docker' "$TMP/calls"

# 25.12: the apk marker wins even if an opkg binary remains on the system.
printf 'x86_64\n' > "$TMP/apk-system/arch"
detect_package_manager "$TMP/apk-system/arch"
[ "$PACKAGE_MANAGER" = apk ]
package_manager_update
package_manager_install luci-base lua rpcd-mod-file curl
package_is_installed rpcd-mod-file
grep -Fxq 'apk update' "$TMP/calls"
grep -Fxq 'apk add luci-base lua rpcd-mod-file curl' "$TMP/calls"

# Package feed and install failures must remain visible to the installer.
TEST_PACKAGE_MANAGER_FAIL=update; export TEST_PACKAGE_MANAGER_FAIL
if package_manager_update; then
    echo 'A package feed update failure must propagate.' >&2
    exit 1
fi
TEST_PACKAGE_MANAGER_FAIL=add; export TEST_PACKAGE_MANAGER_FAIL
if package_manager_install jsonfilter; then
    echo 'A dependency installation failure must propagate.' >&2
    exit 1
fi
unset TEST_PACKAGE_MANAGER_FAIL

# Do not fall back to stale opkg when an apk system has lost its apk command.
mkdir -p "$TMP/opkg-only"
cp "$TMP/bin/opkg" "$TMP/opkg-only/opkg"
if PATH="$TMP/opkg-only" detect_package_manager "$TMP/apk-system/arch" 2>/dev/null; then
    echo 'An apk system must not fall back to stale opkg.' >&2
    exit 1
fi

# An apk-only environment without the marker still works as a best-effort fallback.
mkdir -p "$TMP/apk-only"
cp "$TMP/bin/apk" "$TMP/apk-only/apk"
PATH="$TMP/apk-only"; export PATH
detect_package_manager "$TMP/no-apk-marker"
[ "$PACKAGE_MANAGER" = apk ]
PATH="$ORIGINAL_PATH"; export PATH

echo 'opkg/apk selection, dependency commands, failure propagation, installed-package checks, and stale-opkg protection passed.'
