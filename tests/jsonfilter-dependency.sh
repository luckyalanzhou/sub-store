#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
MOCK_BIN="$TEST_DIR/opkg-bin"
APK_BIN="$TEST_DIR/apk-bin"
MOCK_LOG="$TEST_DIR/package-manager.log"
mkdir -p "$MOCK_BIN" "$APK_BIN"
export MOCK_BIN APK_BIN MOCK_LOG

awk '
    /^is_target_release\(\) \{/ { copy=1 }
    copy { print }
    copy && /^ensure_jsonfilter\(\) \{/ { last_function=1 }
    copy && last_function && /^\}$/ { exit }
' "$ROOT/installer/payload/install.sh" > "$TEST_DIR/functions.sh"
. "$TEST_DIR/functions.sh"

say() { printf '%s\n' "$*" >> "$TEST_DIR/messages"; }
fail() { say "ERROR: $*"; exit 1; }

is_target_release 24.10.5
is_target_release 25.12.0
for version in 24.100.5 25.120.0 24.10x 25.12foo 24.10.5foo 25.12.0-rc1 25.10.0; do
    if is_target_release "$version"; then
        echo "A non-target release was marked as a target: $version" >&2
        exit 1
    fi
done

mkdir -p "$TEST_DIR/no-manager-bin"
if (PATH="$TEST_DIR/no-manager-bin" detect_package_manager); then
    echo 'A system without opkg or apk was accepted.' >&2
    exit 1
fi
grep -Fq 'requires iStoreOS/OpenWrt with opkg or apk' "$TEST_DIR/messages"

cat > "$MOCK_BIN/opkg" <<'EOF'
#!/bin/sh
case "$1" in
    update)
        printf 'opkg update\n' >> "$MOCK_LOG"
        [ "${MOCK_FAIL_UPDATE:-0}" != 1 ]
        ;;
    install)
        shift
        printf 'opkg install %s\n' "$*" >> "$MOCK_LOG"
        for package do
            if [ "$package" = jsonfilter ]; then
                printf '#!/bin/sh\nexit 0\n' > "$MOCK_BIN/jsonfilter"
                /bin/chmod 755 "$MOCK_BIN/jsonfilter"
            fi
        done
        ;;
    status)
        case "${MOCK_OPKG_STATUS:-installed}" in
            installed) printf 'Package: %s\nStatus: install user installed\n' "$2" ;;
            user-not-installed) printf 'Package: %s\nStatus: install user not-installed\n' "$2" ;;
            unknown-not-installed) printf 'Package: %s\nStatus: unknown ok not-installed\n' "$2" ;;
            *) exit 1 ;;
        esac
        ;;
esac
EOF
/bin/chmod 755 "$MOCK_BIN/opkg"

PATH="$MOCK_BIN:/usr/bin"
detect_package_manager
[ "$PACKAGE_MANAGER" = opkg ]
ensure_jsonfilter
package_manager_install dockerd docker
printf 'opkg update\nopkg install jsonfilter\nopkg install dockerd docker\n' > "$TEST_DIR/expected.log"
cmp "$TEST_DIR/expected.log" "$MOCK_LOG"
[ -x "$MOCK_BIN/jsonfilter" ]

ensure_jsonfilter
cmp "$TEST_DIR/expected.log" "$MOCK_LOG"
MOCK_OPKG_STATUS=installed
export MOCK_OPKG_STATUS
package_is_installed rpcd-mod-file
for MOCK_OPKG_STATUS in user-not-installed unknown-not-installed; do
    export MOCK_OPKG_STATUS
    if package_is_installed rpcd-mod-file; then
        echo "An opkg package with status '$MOCK_OPKG_STATUS' was reported as installed." >&2
        exit 1
    fi
done

rm -f "$MOCK_BIN/jsonfilter"
hash -r
: > "$MOCK_LOG"
if (MOCK_FAIL_UPDATE=1 ensure_jsonfilter); then
    echo 'A failed opkg update was accepted.' >&2
    exit 1
fi
printf 'opkg update\n' > "$TEST_DIR/expected-failure.log"
cmp "$TEST_DIR/expected-failure.log" "$MOCK_LOG"
grep -Fq 'Could not refresh package feeds to install jsonfilter.' "$TEST_DIR/messages"
: > "$MOCK_LOG"

cat > "$APK_BIN/apk" <<'EOF'
#!/bin/sh
case "$1" in
    update)
        printf 'apk update\n' >> "$MOCK_LOG"
        [ "${MOCK_FAIL_UPDATE:-0}" != 1 ]
        ;;
    add)
        shift
        printf 'apk add %s\n' "$*" >> "$MOCK_LOG"
        for package do
            if [ "$package" = jsonfilter ]; then
                printf '#!/bin/sh\nexit 0\n' > "$APK_BIN/jsonfilter"
                /bin/chmod 755 "$APK_BIN/jsonfilter"
            fi
        done
        ;;
    info)
        [ "${MOCK_APK_INSTALLED:-0}" = 1 ] && printf 'rpcd-mod-file\n'
        ;;
esac
EOF
/bin/chmod 755 "$APK_BIN/apk"

PATH="$APK_BIN:/usr/bin"
detect_package_manager
[ "$PACKAGE_MANAGER" = apk ]
ensure_jsonfilter
package_manager_install dockerd docker
printf 'apk update\napk add jsonfilter\napk add dockerd docker\n' > "$TEST_DIR/expected.log"
cmp "$TEST_DIR/expected.log" "$MOCK_LOG"
[ -x "$APK_BIN/jsonfilter" ]
MOCK_APK_INSTALLED=1
export MOCK_APK_INSTALLED
package_is_installed rpcd-mod-file
MOCK_APK_INSTALLED=0
if package_is_installed rpcd-mod-file; then
    echo 'An uninstalled apk package was reported as installed.' >&2
    exit 1
fi

echo 'Package-manager detection, jsonfilter setup and installed-package checks pass for opkg and apk.'
