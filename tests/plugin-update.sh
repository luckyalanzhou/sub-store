#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

SOURCE="$ROOT/run/payload/root/usr/lib/sub-store/plugin-update"
sed -e "s|STATE_DIR=/tmp/sub-store-plugin-update|STATE_DIR=$TMP/state|" \
    -e "s|CURRENT_VERSION_FILE=/etc/sub-store/version|CURRENT_VERSION_FILE=$TMP/current-version|" \
    "$SOURCE" > "$TMP/plugin-update"
chmod 755 "$TMP/plugin-update"

cat > "$TMP/bin/jsonfilter" <<'EOF'
#!/bin/sh
set -eu
file=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -i) file="$2"; shift 2 ;;
        *) shift ;;
    esac
done
sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1
EOF

cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
set -eu
output=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) output="$2"; shift 2 ;;
        -H|--connect-timeout|--max-time|--retry|--proto|--proto-redir) shift 2 ;;
        --fail|--silent|--show-error|--location) shift ;;
        *) url="$1"; shift ;;
    esac
done
printf '%s\n' "$url" >> "$TEST_CURL_LOG"
case "$url" in
    */releases/latest)
        printf '{\n  "tag_name": "v%s"\n}\n' "$TEST_RELEASE_VERSION" > "$output"
        ;;
    *.run.sha256)
        hash="$(sha256sum "$TEST_INSTALLER" | awk '{print $1}')"
        [ "${TEST_BAD_CHECKSUM:-0}" = 1 ] && hash="0000000000000000000000000000000000000000000000000000000000000000"
        name="${url##*/}"
        name="${name%.sha256}"
        printf '%s  %s\n' "$hash" "$name" > "$output"
        ;;
    *.run)
        cp "$TEST_INSTALLER" "$output"
        ;;
    *) echo "Unexpected URL: $url" >&2; exit 1 ;;
esac
EOF
chmod 755 "$TMP/bin/jsonfilter" "$TMP/bin/curl"

cat > "$TMP/fake-installer" <<'EOF'
#!/bin/sh
set -eu
if [ "${1:-}" = "--check" ]; then
    echo 'Archive integrity check passed.'
    exit 0
fi
[ "${SUB_STORE_PLUGIN_ONLY:-}" = 1 ] || exit 20
printf '%s\n' "$TEST_RELEASE_VERSION" > "$TEST_CURRENT_VERSION"
echo 'LuCI files installed without a Docker command.'
EOF
chmod 755 "$TMP/fake-installer"
printf '%s\n' 1.2.9999999999999999999 > "$TMP/current-version"
export TEST_RELEASE_VERSION=1.3.0
export TEST_INSTALLER="$TMP/fake-installer"
export TEST_CURRENT_VERSION="$TMP/current-version"
export TEST_CURL_LOG="$TMP/curl.log"
: > "$TEST_CURL_LOG"
export PATH="$TMP/bin:$PATH"

"$TMP/plugin-update" check > "$TMP/check.log"
[ "$(cat "$TMP/state/latest-version")" = 1.3.0 ]
[ "$(cat "$TMP/state/update-available")" = 1 ]
grep -q '发现新版本' "$TMP/check.log"

TEST_BAD_CHECKSUM=1
export TEST_BAD_CHECKSUM
if "$TMP/plugin-update" install > "$TMP/bad-checksum.log" 2>&1; then
    echo 'An invalid checksum was accepted.' >&2
    exit 1
fi
[ "$(cat "$TMP/current-version")" = 1.2.9999999999999999999 ]
grep -q 'SHA-256 verification failed' "$TMP/bad-checksum.log"

unset TEST_BAD_CHECKSUM
"$TMP/plugin-update" install > "$TMP/install.log"
[ "$(cat "$TMP/current-version")" = 1.3.0 ]
[ "$(cat "$TMP/state/update-available")" = 0 ]
grep -q 'Docker image and container were not changed' "$TMP/install.log"

asset_requests_before="$(grep -Ec '/sub-store-[^/]+\.run(\.sha256)?$' "$TEST_CURL_LOG" || true)"
"$TMP/plugin-update" install-if-newer > "$TMP/latest.log"
grep -q 'is up to date' "$TMP/latest.log"
asset_requests_after="$(grep -Ec '/sub-store-[^/]+\.run(\.sha256)?$' "$TEST_CURL_LOG" || true)"
[ "$asset_requests_after" -eq "$asset_requests_before" ] || {
    echo 'The up-to-date plugin triggered an unnecessary installer download.' >&2
    exit 1
}

echo 'Plugin release check, checksummed .run updates and no-op update passed.'
