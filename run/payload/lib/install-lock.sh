#!/bin/sh

INSTALL_OPERATION_STATE=/tmp/sub-store-operation
INSTALL_OPERATION_LOCK_ACTIVE=0

acquire_install_operation_lock() {
    # LuCI's plugin updater already runs inside this lock. Do not try to nest it.
    [ "${SUB_STORE_PLUGIN_ONLY:-0}" = "1" ] && return 0

    if [ ! -e "$INSTALL_OPERATION_STATE" ] && [ ! -L "$INSTALL_OPERATION_STATE" ]; then
        (umask 077; mkdir "$INSTALL_OPERATION_STATE") 2>/dev/null || {
            echo "Could not create the sub-store operation state directory." >&2
            return 1
        }
    fi
    state_info="$(stat -c '%F:%u:%a' "$INSTALL_OPERATION_STATE" 2>/dev/null || true)"
    if [ -L "$INSTALL_OPERATION_STATE" ] || [ "$state_info" != "directory:0:700" ]; then
        echo "The sub-store operation state directory is unsafe; refusing to install." >&2
        return 1
    fi

    if [ -L "$INSTALL_OPERATION_STATE/lock" ]; then
        echo "Operation lock is unsafe; refusing to install." >&2
        return 1
    fi
    if ! (umask 077; mkdir "$INSTALL_OPERATION_STATE/lock") 2>/dev/null; then
        lock_info="$(stat -c '%F:%u:%a' "$INSTALL_OPERATION_STATE/lock" 2>/dev/null || true)"
        if [ -L "$INSTALL_OPERATION_STATE/lock" ] || [ "$lock_info" != "directory:0:700" ] ||
            [ -L "$INSTALL_OPERATION_STATE/lock/pid" ]; then
            echo "Operation lock is unsafe; refusing to install." >&2
            return 1
        fi
        lock_pid="$(cat "$INSTALL_OPERATION_STATE/lock/pid" 2>/dev/null || true)"
        case "$lock_pid" in
            '')
                echo "Another operation is starting; try again shortly." >&2
                return 1
                ;;
            *[!0-9]*)
                echo "Operation lock is invalid; refusing to reclaim it." >&2
                return 1
                ;;
            *) [ "$lock_pid" -gt 0 ] 2>/dev/null || lock_pid="" ;;
        esac
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "Another sub-store operation is running; wait for it to finish before installing." >&2
            return 1
        fi
        rm -f "$INSTALL_OPERATION_STATE/lock/pid"
        if ! rmdir "$INSTALL_OPERATION_STATE/lock" 2>/dev/null ||
            ! (umask 077; mkdir "$INSTALL_OPERATION_STATE/lock") 2>/dev/null; then
            echo "Another sub-store operation is running; wait for it to finish before installing." >&2
            return 1
        fi
    fi

    if ! (set -C; printf '%s\n' "$$" > "$INSTALL_OPERATION_STATE/lock/pid") 2>/dev/null ||
        ! chmod 600 "$INSTALL_OPERATION_STATE/lock/pid"; then
        rmdir "$INSTALL_OPERATION_STATE/lock" 2>/dev/null || true
        echo "Could not safely record the installer operation lock." >&2
        return 1
    fi
    INSTALL_OPERATION_LOCK_ACTIVE=1
}

release_install_operation_lock() {
    [ "$INSTALL_OPERATION_LOCK_ACTIVE" = "1" ] || return 0
    if [ ! -L "$INSTALL_OPERATION_STATE/lock/pid" ] &&
        [ "$(cat "$INSTALL_OPERATION_STATE/lock/pid" 2>/dev/null || true)" = "$$" ]; then
        rm -f "$INSTALL_OPERATION_STATE/lock/pid"
        rmdir "$INSTALL_OPERATION_STATE/lock" 2>/dev/null || true
    fi
    INSTALL_OPERATION_LOCK_ACTIVE=0
}
