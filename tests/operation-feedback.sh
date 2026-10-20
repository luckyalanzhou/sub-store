#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/ctl" <<'EOF'
#!/bin/sh
[ "$1" != "restart" ] || : > "$RESTART_STARTED"
echo "operation output: $1"
if [ "$1" = "update" ] && [ -f "$INTERRUPT_UPDATE" ]; then
    printf '%s\n' "$$" > "$COMMAND_PID_FILE"
    while [ ! -e "$RELEASE_UPDATE" ]; do sleep 0.05; done
    : > "$COMMAND_FINISHED"
    echo 'operation output: interrupt-controlled update complete'
    exit 0
fi
[ "$1" != "update" ] || {
    if [ -f "$SLOW_UPDATE" ]; then
        dd if=/dev/zero bs=1024 count=1200 2>/dev/null | tr '\000' x
        echo 'operation output: update'
        sleep 2
        exit 0
    fi
    exit 7
}
[ "$1" != "restart" ] || sleep 3
EOF
chmod +x "$TMP/ctl"
mkdir "$TMP/bin"
REAL_CHMOD="$(command -v chmod)"
REAL_STAT="$(command -v stat)"
REAL_DD="$(command -v dd)"
cat > "$TMP/bin/dd" <<'EOF'
#!/bin/sh
if [ "${BUSYBOX_TEST:-0}" = "1" ]; then
    exec busybox dd "$@"
fi
exec "$REAL_DD" "$@"
EOF
cat > "$TMP/bin/chmod" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CHMOD_LOG"
exec "$REAL_CHMOD" "$@"
EOF
cat > "$TMP/bin/stat" <<'EOF'
#!/bin/sh
if [ "${BUSYBOX_TEST:-0}" = "1" ]; then
    exec busybox stat "$@"
fi
exec "$REAL_STAT" "$@"
EOF
"$REAL_CHMOD" +x "$TMP/bin/chmod"
"$REAL_CHMOD" +x "$TMP/bin/stat"
"$REAL_CHMOD" +x "$TMP/bin/dd"
export REAL_CHMOD REAL_STAT REAL_DD CHMOD_LOG="$TMP/chmod.log"
PATH="$TMP/bin:$PATH"
export PATH
sed -e "s|STATE=/tmp/sub-store-operation|STATE=$TMP/state|" \
    -e "s|/usr/bin/sub-storectl|$TMP/ctl|" \
    "$ROOT/installer/payload/root/usr/lib/sub-store/job.sh" > "$TMP/job"
run_sh() {
    if [ "${BUSYBOX_TEST:-0}" = "1" ]; then busybox ash "$@"; else sh "$@"; fi
}
assert_operation_snapshot() {
    expected_action="$1"
    expected_phase="$2"
    [ "$(sed -n '1p' "$TMP/state/snapshot")" = sub-store-operation-v1 ]
    operation_id="$(sed -n '2p' "$TMP/state/snapshot")"
    printf '%s\n' "$operation_id" | grep -Eq '^[0-9]+-[0-9]+$'
    [ "$(sed -n '3p' "$TMP/state/snapshot")" = "$expected_action" ]
    [ "$(sed -n '4p' "$TMP/state/snapshot")" = "$expected_phase" ]
}
report_worker_timeout() {
    state_dir="$1"
    echo "Timed out waiting for the operation worker in $state_dir." >&2
    for state_file in phase status snapshot output.log; do
        if [ -f "$state_dir/$state_file" ]; then
            printf '%s:\n' "$state_file" >&2
            cat "$state_dir/$state_file" >&2
        fi
    done
    worker_pid="$(cat "$state_dir/lock/pid" 2>/dev/null || true)"
    case "$worker_pid" in
        ''|*[!0-9]*) ;;
        *)
            ps >&2 || true
            if [ -r "/proc/$worker_pid/wchan" ]; then
                printf 'worker wait channel: ' >&2
                cat "/proc/$worker_pid/wchan" >&2
                printf 'worker file descriptors:\n' >&2
                ls -l "/proc/$worker_pid/fd" >&2 || true
            fi
            ;;
    esac
}
export SLOW_UPDATE="$TMP/slow-update"
export INTERRUPT_UPDATE="$TMP/interrupt-update"
export COMMAND_PID_FILE="$TMP/interrupted-command.pid"
export RESTART_STARTED="$TMP/restart-started"
export RELEASE_UPDATE="$TMP/release-interrupted-update"
export COMMAND_FINISHED="$TMP/interrupted-command-finished"
if run_sh "$TMP/job" check; then
    echo 'The removed manual service check is still accepted.' >&2
    exit 1
fi
mkdir -p "$TMP/foreign-state"
"$REAL_CHMOD" 755 "$TMP/foreign-state"
{
    cat <<'EOF'
stat() {
    if [ "$#" -ne 3 ] || [ "$1" != "-c" ] || [ "$2" != "%u" ] ||
        [ "$3" != "$FAKE_STATE_PATH" ]; then
        printf 'Unexpected stat invocation in ownership test: %s\n' "$*" >&2
        return 2
    fi
    printf '%s\n' "$FAKE_STATE_OWNER"
}
EOF
    sed -e "s|STATE=/tmp/sub-store-operation|STATE=$TMP/foreign-state|" \
        -e "s|/usr/bin/sub-storectl|$TMP/ctl|" \
        "$ROOT/installer/payload/root/usr/lib/sub-store/job.sh"
} > "$TMP/foreign-job"
current_uid="$(id -u)"
if [ "$current_uid" = 0 ]; then FAKE_STATE_OWNER=1; else FAKE_STATE_OWNER=0; fi
export FAKE_STATE_OWNER FAKE_STATE_PATH="$TMP/foreign-state"
if run_sh "$TMP/foreign-job" start > "$TMP/foreign-output" 2>&1; then
    echo 'A foreign-owned operation state directory was accepted.' >&2
    exit 1
fi
unset FAKE_STATE_OWNER FAKE_STATE_PATH
grep -Fq 'Operation state directory is not trusted' "$TMP/foreign-output" || {
    cat "$TMP/foreign-output" >&2
    echo 'The foreign-owned operation state directory failed for an unexpected reason.' >&2
    exit 1
}
[ ! -e "$TMP/foreign-state/lock" ] || {
    echo 'The worker touched a foreign-owned operation state directory.' >&2
    exit 1
}
case "$(uname -s)" in
    MINGW*|MSYS*) ;;
    *)
        mkdir "$TMP/link-target"
        ln -s "$TMP/link-target" "$TMP/link-state"
        sed -e "s|STATE=/tmp/sub-store-operation|STATE=$TMP/link-state|" \
            -e "s|/usr/bin/sub-storectl|$TMP/ctl|" \
            "$ROOT/installer/payload/root/usr/lib/sub-store/job.sh" > "$TMP/link-job"
        if run_sh "$TMP/link-job" start > "$TMP/link-output" 2>&1; then
            echo 'A symlinked operation state directory was accepted.' >&2
            exit 1
        fi
        grep -Fq 'Operation state directory is not trusted' "$TMP/link-output" || {
            echo 'The symlinked operation state directory failed for an unexpected reason.' >&2
            exit 1
        }
        [ ! -e "$TMP/link-target/lock" ] || {
            echo 'The worker wrote through a symlinked operation state directory.' >&2
            exit 1
        }

        mkdir -p "$TMP/lock-state/lock" "$TMP/pid-target"
        printf '%s\n' 1 > "$TMP/pid-target/pid"
        ln -s "$TMP/pid-target/pid" "$TMP/lock-state/lock/pid"
        sed -e "s|STATE=/tmp/sub-store-operation|STATE=$TMP/lock-state|" \
            -e "s|/usr/bin/sub-storectl|$TMP/ctl|" \
            "$ROOT/installer/payload/root/usr/lib/sub-store/job.sh" > "$TMP/lock-job"
        if run_sh "$TMP/lock-job" start > "$TMP/lock-output" 2>&1; then
            echo 'A symlinked operation lock file was accepted.' >&2
            exit 1
        fi
        grep -Fq 'Operation lock is not trusted' "$TMP/lock-output" || {
            echo 'The symlinked operation lock failed for an unexpected reason.' >&2
            exit 1
        }
        ;;
esac
mkdir -p "$TMP/state"
"$REAL_CHMOD" 777 "$TMP/state"
printf '%s\n' protected > "$TMP/protected"
for state_file in action phase status snapshot output.log output.pipe snapshot.999 output.chunk.999; do
    ln -s "$TMP/protected" "$TMP/state/$state_file"
done
: > "$CHMOD_LOG"
run_sh "$TMP/job" clear-runtime-logs
case "$(uname -s)" in
    MINGW*|MSYS*)
        grep -Fxq "700 $TMP/state" "$CHMOD_LOG" || {
            echo 'The operation state directory was not secured to mode 700.' >&2
            exit 1
        }
        ;;
    *) [ "$(stat -c '%a' "$TMP/state")" = 700 ] || {
        echo 'The operation state directory permissions are too broad.' >&2
        exit 1
    } ;;
esac
grep -q 'operation output: clear-runtime-logs' "$TMP/state/output.log"
[ "$(cat "$TMP/protected")" = protected ] || {
    echo 'A stale symlink in operation state modified a file outside the state directory.' >&2
    exit 1
}
for state_file in action phase status snapshot output.log output.pipe snapshot.999 output.chunk.999; do
    [ ! -L "$TMP/state/$state_file" ] || {
        echo "A stale symlink remained in operation state: $state_file" >&2
        exit 1
    }
done
run_sh "$TMP/job" clear-maintenance-logs
grep -q 'operation output: clear-maintenance-logs' "$TMP/state/output.log"
run_sh "$TMP/job" start
grep -q '操作成功' "$TMP/state/status"
grep -q 'operation output: start' "$TMP/state/output.log"
assert_operation_snapshot start success
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
rmdir "$TMP/state/lock"
if run_sh "$TMP/job" arbitrary; then exit 1; fi
run_sh "$TMP/job" --enqueue restart
[ -d "$TMP/state/lock" ]
grep -q running "$TMP/state/phase"
if run_sh "$TMP/job" --enqueue stop; then exit 1; fi
attempt=0
while [ ! -e "$RESTART_STARTED" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 20 ]; then
        report_worker_timeout "$TMP/state"
        echo 'The restart command did not start in time.' >&2
        exit 1
    fi
    sleep 0.05
done
attempt=0
while ! grep -q 'operation output: restart' "$TMP/state/output.log"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 20 ]; then
        report_worker_timeout "$TMP/state"
        echo 'Operation output was not visible before the worker exited.' >&2
        exit 1
    fi
    sleep 0.05
done
attempt=0
while [ -d "$TMP/state/lock" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 10 ]; then
        report_worker_timeout "$TMP/state"
        exit 1
    fi
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
[ "$live_log_size" -gt 0 ] || { echo 'operation output was not visible while the worker was running.' >&2; exit 1; }
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

run_worker_signal_test=1
case "$(uname -s)" in
    MINGW*|MSYS*) [ "${RUN_WORKER_SIGNAL_TEST:-0}" = 1 ] || run_worker_signal_test=0 ;;
esac
if [ "$run_worker_signal_test" = 1 ]; then
    INTERRUPT_STATE="$TMP/interrupted-state"
    mkdir -p "$INTERRUPT_STATE"
    sed -e "s|STATE=/tmp/sub-store-operation|STATE=$INTERRUPT_STATE|" \
        -e "s|/usr/bin/sub-storectl|$TMP/ctl|" \
        "$ROOT/installer/payload/root/usr/lib/sub-store/job.sh" > "$TMP/interrupted-job"
    touch "$INTERRUPT_UPDATE"
    run_sh "$TMP/interrupted-job" --enqueue update
    attempt=0
    while [ ! -s "$COMMAND_PID_FILE" ]; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 30 ]; then
            worker_pid="$(cat "$INTERRUPT_STATE/lock/pid" 2>/dev/null || true)"
            kill -TERM "$worker_pid" 2>/dev/null || true
            touch "$RELEASE_UPDATE"
            echo 'The interrupted command did not start in time.' >&2
            exit 1
        fi
        sleep 0.05
    done
    worker_pid="$(cat "$INTERRUPT_STATE/lock/pid")"
    command_pid="$(cat "$COMMAND_PID_FILE")"
    kill -TERM "$worker_pid"
    sleep 0.1
    command_alive=0
    kill -0 "$command_pid" 2>/dev/null && command_alive=1 || true
    concurrent_operation=0
    if [ "$command_alive" = 1 ] &&
        run_sh "$TMP/interrupted-job" --enqueue stop > "$TMP/interrupted-concurrent-output" 2>&1; then
        concurrent_operation=1
    fi
    touch "$RELEASE_UPDATE"
    if [ "$command_alive" = 1 ]; then
        attempt=0
        while [ ! -e "$COMMAND_FINISHED" ]; do
            attempt=$((attempt + 1))
            if [ "$attempt" -ge 30 ]; then
                kill -TERM "$command_pid" 2>/dev/null || true
                kill -TERM "$worker_pid" 2>/dev/null || true
                echo 'The interrupted command did not finish after release.' >&2
                exit 1
            fi
            sleep 0.05
        done
    fi
    attempt=0
    while [ -d "$INTERRUPT_STATE/lock" ]; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 30 ]; then
            kill -TERM "$worker_pid" 2>/dev/null || true
            echo 'The interrupted worker did not release its lock.' >&2
            exit 1
        fi
        sleep 0.05
    done
    if [ "$concurrent_operation" = 1 ]; then
        cat "$TMP/interrupted-concurrent-output" >&2
        echo 'A second operation was accepted while the interrupted command was still running.' >&2
        exit 1
    fi
    [ "$(cat "$INTERRUPT_STATE/phase")" = interrupted ] || {
        cat "$INTERRUPT_STATE/status" >&2
        echo 'The terminated worker did not report an interrupted operation.' >&2
        exit 1
    }
fi

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
assert_operation_snapshot stop success
if command -v lua5.1 >/dev/null 2>&1; then
    SUB_STORE_TEST_OPERATION_SNAPSHOT="$TMP/state/snapshot" lua5.1 "$ROOT/tests/luci-status.lua" "$ROOT"
    mkdir -p "$TMP/legacy-state"
    printf '%s\n' sub-store-operation-v1 1-2 stop success > "$TMP/legacy-state/snapshot"
    printf '%s\n' stop > "$TMP/legacy-state/action"
    printf '%s\n' success > "$TMP/legacy-state/phase"
    printf '%s\n' 'legacy operation status' > "$TMP/legacy-state/status"
    SUB_STORE_TEST_STATUS_FIXTURE_DIR="$TMP/legacy-state" lua5.1 "$ROOT/tests/luci-status.lua" "$ROOT"
fi
echo "Operation success, failure and concurrency checks passed."
