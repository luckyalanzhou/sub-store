#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PAYLOAD="$ROOT/run/payload"
VERSION="${VERSION:-}"

printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
    echo "VERSION must use semantic version form x.y.z" >&2
    exit 1
}

OUT="$ROOT/dist/sub-store-$VERSION.run"

command -v makeself >/dev/null 2>&1 || { echo "makeself is required" >&2; exit 1; }
[ -f "$PAYLOAD/install.sh" ] || { echo "package payload is missing" >&2; exit 1; }

mkdir -p "$ROOT/dist"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sub-store-run-build.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cp -R "$PAYLOAD" "$TMP/payload"
# Normalize archive permissions even when the runner uses a restrictive umask.
find "$TMP/payload" -type d -exec chmod 755 {} +
find "$TMP/payload" -type f -exec chmod 644 {} +
printf '%s\n' "$VERSION" > "$TMP/payload/build-version"
chmod 755 "$TMP/payload/install.sh"
makeself --nox11 "$TMP/payload" "$OUT" "sub-store $VERSION" ./install.sh
echo "Created $OUT"
wc -c < "$OUT"
