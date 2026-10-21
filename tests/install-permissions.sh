#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "POSIX permission checks run on Linux CI; Windows mode bits are not authoritative."
        exit 0
        ;;
esac
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
. "$ROOT/run/payload/root/usr/lib/sub-store/permissions.sh"
for mask in 022 077; do
    dest="$TMP/$mask"
    mkdir -p "$dest"
    (umask "$mask"; cp -R "$ROOT/run/payload/root/." "$dest/")
    mkdir -p "$dest/etc/config"
    cp "$dest/www/luci-static/resources/view/sub-store/manage.js" \
        "$dest/www/luci-static/resources/view/sub-store/manage_0_0_22.js"
    printf 'private\n' > "$dest/etc/config/sub-store"
    chmod 600 "$dest/etc/config/sub-store"
    # Also exercise repair of the bad modes left by a previous installation.
    chmod 700 "$dest/www/luci-static/resources/view/sub-store"
    chmod 600 "$dest/www/luci-static/resources/view/sub-store/manage.js"
    chmod 600 "$dest/www/luci-static/resources/view/sub-store/manage_0_0_22.js"
    sub_store_public_permissions "$dest"
    for dir in /www /www/luci-static /www/luci-static/resources \
        /www/luci-static/resources/view /www/luci-static/resources/view/sub-store; do
        [ "$(stat -c '%a' "$dest$dir")" = "755" ]
    done
    for file in /www/luci-static/resources/view/sub-store/manage.js \
        /www/luci-static/resources/view/sub-store/manage_0_0_22.js \
        /usr/share/luci/menu.d/luci-app-sub-store.json \
        /usr/share/rpcd/acl.d/luci-app-sub-store.json; do
        [ "$(stat -c '%a' "$dest$file")" = "644" ]
    done
    [ "$(stat -c '%a' "$dest/etc/config/sub-store")" = "600" ]
done
echo "Fresh install and repair permissions passed with umask 022 and 077; credentials remain private."
