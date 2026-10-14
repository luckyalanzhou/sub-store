#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/run/payload/root/usr/lib/sub-store/cron.sh"

for expression in \
    '55 23 * * *' \
    '*/15 0-23 1,15 1-12 0-6' \
    '1/2 * * * 7'; do
    if ! sub_store_valid_cron "$expression"; then
        echo "Expected valid cron expression: $expression" >&2
        exit 1
    fi
done

for expression in \
    '60 * * * *' \
    '* 24 * * *' \
    '* * 0 * *' \
    '* * * 13 *' \
    '* * * * 8' \
    '*/0 * * * *' \
    '1,,2 * * * *' \
    '2-1 * * * *' \
    '* * * *'; do
    if sub_store_valid_cron "$expression"; then
        echo "Expected invalid cron expression: $expression" >&2
        exit 1
    fi
done

echo "Cron validation checks passed."
