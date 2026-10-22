#!/bin/sh

initialize_install_log() {
    target="${1:-}"
    case "$target" in /*) ;; *) return 1 ;; esac

    target_dir="${target%/*}"
    [ -n "$target_dir" ] || target_dir=/
    [ -d "$target_dir" ] || return 1

    temp_file="$(umask 077; mktemp "$target_dir/.sub-store-run-install.XXXXXX")" || return 1
    chmod 600 "$temp_file" || {
        rm -f "$temp_file"
        return 1
    }

    # Unlink an old log without following a possible symlink. ln then creates
    # the destination exclusively; if an attacker wins the race, it fails closed.
    rm -f "$target" || {
        rm -f "$temp_file"
        return 1
    }
    if ! ln "$temp_file" "$target"; then
        rm -f "$temp_file"
        return 1
    fi
    rm -f "$temp_file"
}
