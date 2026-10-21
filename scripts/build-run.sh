#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PAYLOAD="$ROOT/run/payload"
VERSION="${VERSION:-}"

printf '%s\n' "$VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || {
    echo "VERSION must use MAJOR.MINOR.PATCH without leading zeroes" >&2
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
VIEW_DIR="$TMP/payload/root/www/luci-static/resources/view/sub-store"
MENU_FILE="$TMP/payload/root/usr/share/luci/menu.d/luci-app-sub-store.json"
VERSIONED_VIEW="manage_$(printf '%s' "$VERSION" | tr '.' '_')"
cp "$VIEW_DIR/manage.js" "$VIEW_DIR/$VERSIONED_VIEW.js"
sed -i "s#\"path\": \"sub-store/manage\"#\"path\": \"sub-store/$VERSIONED_VIEW\"#" "$MENU_FILE"
grep -Fq "\"path\": \"sub-store/$VERSIONED_VIEW\"" "$MENU_FILE" || {
    echo "Could not set the versioned LuCI view path" >&2
    exit 1
}
# Normalize archive permissions even when the runner uses a restrictive umask.
find "$TMP/payload" -type d -exec chmod 755 {} +
find "$TMP/payload" -type f -exec chmod 644 {} +
printf '%s\n' "$VERSION" > "$TMP/payload/build-version"
chmod 755 "$TMP/payload/install.sh"
makeself --nox11 "$TMP/payload" "$OUT" "sub-store $VERSION" ./install.sh
echo "Created $OUT"
wc -c < "$OUT"
