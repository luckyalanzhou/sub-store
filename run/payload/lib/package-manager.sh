#!/bin/sh

detect_package_manager() {
    apk_marker="${1:-/etc/apk/arch}"

    # The apk system marker is authoritative, even if opkg is also available.
    if [ -s "$apk_marker" ]; then
        command -v apk >/dev/null 2>&1 || return 1
        PACKAGE_MANAGER=apk
    elif command -v opkg >/dev/null 2>&1; then
        PACKAGE_MANAGER=opkg
    elif command -v apk >/dev/null 2>&1; then
        PACKAGE_MANAGER=apk
    else
        return 1
    fi
}

package_manager_update() {
    case "$PACKAGE_MANAGER" in
        opkg) opkg update ;;
        apk) apk update ;;
        *) return 1 ;;
    esac
}

package_manager_install() {
    case "$PACKAGE_MANAGER" in
        opkg) opkg install "$@" ;;
        apk) apk add "$@" ;;
        *) return 1 ;;
    esac
}

package_is_installed() {
    case "$PACKAGE_MANAGER" in
        opkg) opkg status "$1" 2>/dev/null | grep -q 'Status:.*installed' ;;
        apk) apk info 2>/dev/null | grep -Fxq -- "$1" ;;
        *) return 1 ;;
    esac
}
