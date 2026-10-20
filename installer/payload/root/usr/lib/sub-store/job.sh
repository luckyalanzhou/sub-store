#!/bin/sh
# Reserve the operation before returning to LuCI; do not hold its RPC open.
set -e
umask 077
MODE="${1:-}"
if [ "$MODE" = "--enqueue" ] || [ "$MODE" = "--worker" ]; then
    ACTION="${2:-}"
else
    ACTION="$MODE"
fi
OPERATION_ID="${3:-}"
case "$ACTION" in
    start|stop|restart|update|update-all|rotate-key|check-plugin-update|install-plugin-update|logs|clear-runtime-logs|clear-maintenance-logs) ;;
    *) echo "Unsupported action" >&2; exit 1 ;;
esac
if [ "$MODE" = "--enqueue" ] && ! command -v nohup >/dev/null 2>&1; then
    echo "Cannot queue an operation: nohup is unavailable." >&2
    exit 1
fi
STATE=/tmp/sub-store-operation
if [ -L "$STATE" ]; then
    echo "Operation state directory is not trusted." >&2
    exit 1
fi
mkdir -p "$STATE"
if [ -L "$STATE" ] || [ ! -d "$STATE" ]; then
    echo "Operation state directory is not trusted." >&2
    exit 1
fi
state_uid="$(stat -c '%u' "$STATE" 2>/dev/null)" || {
    echo "Cannot verify operation state directory ownership." >&2
    exit 1
}
current_uid="$(id -u)" || {
    echo "Cannot verify operation state directory ownership." >&2
    exit 1
}
if [ "$state_uid" != "$current_uid" ]; then
    echo "Operation state directory is not trusted." >&2
    exit 1
fi
chmod 700 "$STATE" || {
    echo "Cannot secure operation state directory." >&2
    exit 1
}
write_operation_state() {
    phase="$1"
    message="$2"
    snapshot_tmp="$(mktemp "$STATE/snapshot.XXXXXX")" || return 1
    {
        printf '%s\n' sub-store-operation-v1
        printf '%s\n' "$OPERATION_ID"
        printf '%s\n' "$ACTION"
        printf '%s\n' "$phase"
        printf '%s\n' "$message"
    } > "$snapshot_tmp"
    printf '%s\n' "$ACTION" > "$STATE/action"
    printf '%s\n' "$phase" > "$STATE/phase"
    printf '%s\n' "$message" > "$STATE/status"
    mv -f "$snapshot_tmp" "$STATE/snapshot"
}
if [ -L "$STATE/lock" ] || [ -L "$STATE/lock/pid" ]; then
    echo "Operation lock is not trusted." >&2
    exit 1
fi
if [ "$MODE" = "--worker" ]; then
    [ -d "$STATE/lock" ] || { echo "No queued operation." >&2; exit 1; }
    [ "$(cat "$STATE/action" 2>/dev/null)" = "$ACTION" ] || {
        echo "Queued operation does not match." >&2
        exit 1
    }
    queued_operation_id="$(sed -n '2p' "$STATE/snapshot" 2>/dev/null || true)"
    if [ -n "$OPERATION_ID" ] && [ "$queued_operation_id" != "$OPERATION_ID" ]; then
        echo "Queued operation ID does not match." >&2
        exit 1
    fi
    OPERATION_ID="$queued_operation_id"
    [ -n "$OPERATION_ID" ] || { echo "Queued operation has no ID." >&2; exit 1; }
    printf '%s\n' "$$" > "$STATE/lock/pid"
else
    if ! mkdir "$STATE/lock" 2>/dev/null; then
        lock_pid="$(cat "$STATE/lock/pid" 2>/dev/null || true)"
        case "$lock_pid" in
            ''|*[!0-9]*) lock_pid="" ;;
            *) [ "$lock_pid" -gt 0 ] 2>/dev/null || lock_pid="" ;;
        esac
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "Another operation is running." >&2
            exit 1
        fi
        rm -f "$STATE/lock/pid"
        if ! rmdir "$STATE/lock" 2>/dev/null || ! mkdir "$STATE/lock" 2>/dev/null; then
            echo "Another operation is running." >&2
            exit 1
        fi
        rm -f "$STATE/output.pipe" "$STATE"/output.chunk.*
    fi
    printf '%s\n' "$$" > "$STATE/lock/pid"
    trap 'rm -f "$STATE/lock/pid"; rmdir "$STATE/lock" 2>/dev/null || true' EXIT
    rm -f "$STATE/action" "$STATE/phase" "$STATE/status" "$STATE/snapshot" \
        "$STATE"/snapshot.* "$STATE/output.log" "$STATE/output.pipe" "$STATE"/output.chunk.*
    OPERATION_ID="$(date '+%s')-$$"
    : > "$STATE/output.log"
    write_operation_state running "正在执行：$ACTION；开始时间：$(date '+%Y-%m-%d %H:%M:%S')"
fi
run_job() {
    trap 'rm -f "$STATE/lock/pid"; rmdir "$STATE/lock" 2>/dev/null || true' EXIT
    trap 'write_operation_state interrupted "操作已中断"; exit 130' INT
    trap 'write_operation_state interrupted "操作已中断"; exit 143' TERM
    COMMAND=/usr/bin/sub-storectl
    set -- "$ACTION"
    trim_operation_log() {
        log_size="$(wc -c < "$STATE/output.log" | tr -d '[:space:]')"
        if [ -n "$log_size" ] && [ "$log_size" -gt 1048576 ]; then
            trimmed_log="$(mktemp "$STATE/output.log.XXXXXX")"
            tail -c 1048576 "$STATE/output.log" > "$trimmed_log"
            mv "$trimmed_log" "$STATE/output.log"
        fi
    }

    consume_operation_output() {
        chunk="$STATE/output.chunk.$$"
        exec 3< "$STATE/output.pipe"
        while :; do
            dd of="$chunk" bs=16384 count=1 iflag=fullblock <&3 2>/dev/null || break
            chunk_size="$(wc -c < "$chunk" | tr -d '[:space:]')"
            [ -n "$chunk_size" ] && [ "$chunk_size" -gt 0 ] || break
            cat "$chunk" >> "$STATE/output.log" || break
            trim_operation_log || true
        done
        exec 3<&-
        rm -f "$chunk"
    }

    if ! mkfifo "$STATE/output.pipe" 2>/dev/null; then
        echo "Cannot create a pipe for bounded operation logging." > "$STATE/output.log"
        write_operation_state failed "操作失败：$ACTION；无法建立有大小限制的日志流。"
        exit 1
    fi
    consume_operation_output &
    log_pid=$!
    if "$COMMAND" "$@" > "$STATE/output.pipe" 2>&1; then
        result=0
    else
        result=$?
    fi
    wait "$log_pid" || true
    rm -f "$STATE/output.pipe"
    trim_operation_log || true
    if [ "$result" -eq 0 ]; then
        write_operation_state success "操作成功：$ACTION；完成时间：$(date '+%Y-%m-%d %H:%M:%S')"
    else
        write_operation_state failed "操作失败：$ACTION；退出码：$result；请查看日志与诊断。"
        exit "$result"
    fi
}
if [ "$MODE" = "--enqueue" ]; then
    # Detach the worker so rpcd's file.exec request returns before Docker finishes.
    nohup /bin/sh "$0" --worker "$ACTION" "$OPERATION_ID" </dev/null >/dev/null 2>&1 &
    worker_pid=$!
    if [ -d "$STATE/lock" ]; then
        printf '%s\n' "$worker_pid" > "$STATE/lock/pid" 2>/dev/null || true
    fi
    trap - EXIT
    echo accepted
elif [ "$MODE" = "--worker" ]; then
    run_job
else
    run_job
fi
