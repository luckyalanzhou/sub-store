#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SERVICE="$ROOT/run/payload/root/etc/init.d/sub-store"

# OpenWrt rc.common treats any non-empty USE_PROCD value, including "0", as
# enabling procd. This service intentionally uses the legacy start/stop hooks.
if grep -q '^USE_PROCD=' "$SERVICE"; then
    echo 'The legacy sub-store init script must not set USE_PROCD.' >&2
    exit 1
fi

grep -Fq '/usr/bin/sub-storectl start' "$SERVICE"
grep -Fq '/usr/lib/sub-store/install-recovery || return 1' "$SERVICE"
grep -Fq '/usr/bin/sub-storectl stop' "$SERVICE"
grep -Fq '/usr/bin/sub-storectl restart' "$SERVICE"

echo 'The sub-store init script uses rc.common legacy hooks without enabling procd.'
