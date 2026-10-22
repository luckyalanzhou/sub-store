#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/ctl" <<'EOF'
#!/bin/sh
echo "operation output: $1"
[ "$1" != "update" ] || {
    if [ -f "$SLOW_UPDATE" ]; then
        dd if=/dev/zero bs=1024 count=1200 2>/dev/null | tr '\000' x
        echo 'operation output: update'
        sleep 2
        exit 0
    fi
    exit 7
}
[ "$1" != "restart" ] || sleep 1
EOF
chmod +x "$TMP/ctl"
sed -e "s|STATE=/tmp/sub-store-operation|STATE=$TMP/state|" \
    -e "s|/usr/bin/sub-storectl|$TMP/ctl|" \
    "$ROOT/run/payload/root/usr/lib/sub-store/job.sh" > "$TMP/job"
run_sh() {
    if [ "${BUSYBOX_TEST:-0}" = "1" ]; then busybox ash "$@"; else sh "$@"; fi
}
export SLOW_UPDATE="$TMP/slow-update"
if run_sh "$TMP/job" check; then
    echo 'The removed manual service check is still accepted.' >&2
    exit 1
fi
run_sh "$TMP/job" clear-runtime-logs
grep -q 'operation output: clear-runtime-logs' "$TMP/state/output.log"
run_sh "$TMP/job" clear-maintenance-logs
grep -q 'operation output: clear-maintenance-logs' "$TMP/state/output.log"
run_sh "$TMP/job" start
grep -q '操作成功' "$TMP/state/status"
grep -q 'operation output: start' "$TMP/state/output.log"
case "$(uname -s)" in
    MINGW*|MSYS*) ;;
    *)
        [ "$(stat -c '%a' "$TMP/state/output.log")" = 600 ] || {
            echo 'The operation log does not have mode 600.' >&2
            exit 1
        }
        ;;
esac
[ ! -d "$TMP/state/lock" ]
run_sh "$TMP/job" check-plugin-update
grep -q 'operation output: check-plugin-update' "$TMP/state/output.log"
grep -q 'check-plugin-update' "$TMP/state/action"
run_sh "$TMP/job" update-all
grep -q 'operation output: update-all' "$TMP/state/output.log"
grep -q 'update-all' "$TMP/state/action"
result=0
run_sh "$TMP/job" update || result=$?
[ "$result" -eq 7 ]
grep -q '退出码：7' "$TMP/state/status"
[ ! -d "$TMP/state/lock" ]
mkdir "$TMP/state/lock"
printf '%s\n' "$$" > "$TMP/state/lock/pid"
if run_sh "$TMP/job" stop; then exit 1; fi
grep -q '退出码：7' "$TMP/state/status"
rm -f "$TMP/state/lock/pid"
if run_sh "$TMP/job" stop; then
    echo 'An operation reclaimed a lock while its owner was initializing.' >&2
    exit 1
fi
rmdir "$TMP/state/lock"
if run_sh "$TMP/job" arbitrary; then exit 1; fi
run_sh "$TMP/job" --enqueue restart
[ -d "$TMP/state/lock" ]
grep -q running "$TMP/state/phase"
if run_sh "$TMP/job" --enqueue stop; then exit 1; fi
attempt=0
while [ -d "$TMP/state/lock" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ]
    sleep 1
done
grep -q success "$TMP/state/phase"
touch "$SLOW_UPDATE"
started="$(date +%s)"
run_sh "$TMP/job" --enqueue update
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 2 ] || { echo "enqueue waited ${elapsed}s for the update worker" >&2; exit 1; }
[ -d "$TMP/state/lock" ]
attempt=0
sleep 1
live_log_size="$(wc -c < "$TMP/state/output.log" | tr -d '[:space:]')"
[ "$live_log_size" -le 1048576 ] || { echo "live operation log exceeded its cap: ${live_log_size} bytes" >&2; exit 1; }
while [ -d "$TMP/state/lock" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ]
    sleep 1
done
grep -q success "$TMP/state/phase"
grep -q 'operation output: update' "$TMP/state/output.log"
log_size="$(wc -c < "$TMP/state/output.log" | tr -d '[:space:]')"
[ "$log_size" -eq 1048576 ] || { echo "operation log was not capped: ${log_size} bytes" >&2; exit 1; }

# A killed worker leaves its lock directory behind. The next request must reclaim it.
mkdir "$TMP/state/lock"
printf '%s\n' 0 > "$TMP/state/lock/pid"
mkfifo "$TMP/state/output.pipe"
touch "$TMP/state/output.chunk.999"
run_sh "$TMP/job" --enqueue stop
attempt=0
while [ -d "$TMP/state/lock" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ]
    sleep 1
done
grep -q success "$TMP/state/phase"
[ ! -e "$TMP/state/output.pipe" ]
[ ! -e "$TMP/state/output.chunk.999" ]

# State and log paths in /tmp must not follow links planted before the first
# request or between requests. A privileged action must leave the target alone.
mkdir "$TMP/attacker"
printf '%s\n' 'sentinel must remain unchanged' > "$TMP/sentinel"
ln -s "$TMP/sentinel" "$TMP/attacker/output.log"
ln -s "$TMP/sentinel" "$TMP/link-probe"
if [ -L "$TMP/link-probe" ]; then
    rm -rf "$TMP/state"
    ln -s "$TMP/attacker" "$TMP/state"
    if run_sh "$TMP/job" start >/dev/null 2>&1; then
        echo 'An operation followed a symlinked state directory.' >&2
        exit 1
    fi
    [ "$(cat "$TMP/sentinel")" = 'sentinel must remain unchanged' ] || {
        echo 'A symlinked state directory modified its target.' >&2
        exit 1
    }
    rm "$TMP/state"
    mkdir "$TMP/state"
    ln -s "$TMP/sentinel" "$TMP/state/output.log"
    if run_sh "$TMP/job" start >/dev/null 2>&1; then
        echo 'An operation followed a symlinked output log.' >&2
        exit 1
    fi
    [ "$(cat "$TMP/sentinel")" = 'sentinel must remain unchanged' ] || {
        echo 'A symlinked output log modified its target.' >&2
        exit 1
    }
    rm "$TMP/state/output.log"
    ln -s "$TMP/sentinel" "$TMP/state/snapshot"
    if run_sh "$TMP/job" start >/dev/null 2>&1; then
        echo 'An operation accepted a symlinked snapshot.' >&2
        exit 1
    fi
    [ "$(cat "$TMP/sentinel")" = 'sentinel must remain unchanged' ] || {
        echo 'A symlinked snapshot modified its target.' >&2
        exit 1
    }
else
    echo 'Symbolic-link regression checks skipped: this shell cannot create symlinks.' >&2
fi
echo "Operation success, failure and concurrency checks passed."
