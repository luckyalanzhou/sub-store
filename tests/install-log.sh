#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
. "$ROOT/run/payload/lib/install-log.sh"

LOG="$TMP/sub-store-run-install.log"
SENTINEL="$TMP/sentinel"
printf '%s\n' 'sensitive file contents' > "$SENTINEL"
chmod 640 "$SENTINEL"
ln -s "$SENTINEL" "$LOG"

initialize_install_log "$LOG"

[ ! -L "$LOG" ]
[ "$(cat "$SENTINEL")" = 'sensitive file contents' ]
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *)
        [ "$(stat -c '%a' "$SENTINEL")" = 640 ]
        [ "$(stat -c '%a' "$LOG")" = 600 ]
        ;;
esac
printf '%s\n' 'installer output' >> "$LOG"
[ "$(cat "$SENTINEL")" = 'sensitive file contents' ]
[ -z "$(find "$TMP" -maxdepth 1 -name '.sub-store-run-install.*' -print -quit)" ]

LOG="$TMP/sub-store-run-install.log"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *)
        mkdir "$TMP/log-directory"
        rm -f "$LOG"
        ln -s "$TMP/log-directory" "$LOG"
        initialize_install_log "$LOG"
        [ ! -L "$LOG" ]
        [ -f "$LOG" ]
        [ -z "$(find "$TMP/log-directory" -mindepth 1 -print -quit)" ]
        ;;
esac

echo 'Installer log initialization safely replaces symlinks and keeps files private.'
