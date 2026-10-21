#!/bin/sh
# Public LuCI assets need traversal and read access independently of umask.
# Do not recursively chmod configuration, application data or credentials.
sub_store_public_permissions() {
    target_root="${1:-}"
    for public_dir in \
        /www /www/luci-static /www/luci-static/resources \
        /www/luci-static/resources/view /www/luci-static/resources/view/sub-store; do
        chmod 755 "$target_root$public_dir" || return 1
    done
    for public_asset in \
        "$target_root/www/luci-static/resources/view/sub-store/manage.js" \
        "$target_root/www/luci-static/resources/view/sub-store/"manage_*.js; do
        [ -f "$public_asset" ] || continue
        chmod 644 "$public_asset" || return 1
    done
    chmod 644 "$target_root/usr/share/luci/menu.d/luci-app-sub-store.json" \
        "$target_root/usr/share/rpcd/acl.d/luci-app-sub-store.json"
}
