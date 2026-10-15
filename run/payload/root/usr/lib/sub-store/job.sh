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
case "$ACTION" in
    start|stop|restart|update|update-all|rotate-key|check|check-plugin-update|install-plugin-update|logs|clear-logs) ;;
    *) echo "Unsupported action" >&2; exit 1 ;;
esac
if [ "$MODE" = "--enqueue" ] && ! command -v nohup >/dev/null 2>&1; then
    echo "Cannot queue an operation: nohup is unavailable." >&2
    exit 1
fi
STATE=/tmp/sub-store-operation
mkdir -p "$STATE"
if [ "$MODE" = "--worker" ]; then
    [ -d "$STATE/lock" ] || { echo "No queued operation." >&2; exit 1; }
    [ "$(cat "$STATE/action" 2>/dev/null)" = "$ACTION" ] || {
        echo "Queued operation does not match." >&2
        exit 1
    }
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
    printf '%s\n' "$ACTION" > "$STATE/action"
    printf '%s\n' running > "$STATE/phase"
    : > "$STATE/output.log"
    printf '正在执行：%s；开始时间：%s\n' "$ACTION" "$(date '+%Y-%m-%d %H:%M:%S')" > "$STATE/status"
fi
run_job() {
    trap 'rm -f "$STATE/lock/pid"; rmdir "$STATE/lock" 2>/dev/null || true' EXIT
    trap 'printf "%s\n" interrupted > "$STATE/phase"; exit 130' INT
    trap 'printf "%s\n" interrupted > "$STATE/phase"; exit 143' TERM
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
            dd of="$chunk" bs=16384 count=1 <&3 2>/dev/null || break
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
        printf '操作失败：%s；无法建立有大小限制的日志流。\n' "$ACTION" > "$STATE/status"
        printf '%s\n' failed > "$STATE/phase"
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
        printf '操作成功：%s；完成时间：%s\n' "$ACTION" "$(date '+%Y-%m-%d %H:%M:%S')" > "$STATE/status"
        printf '%s\n' success > "$STATE/phase"
    else
        printf '操作失败：%s；退出码：%s；请查看日志与诊断。\n' "$ACTION" "$result" > "$STATE/status"
        printf '%s\n' failed > "$STATE/phase"
        exit "$result"
    fi
}
if [ "$MODE" = "--enqueue" ]; then
    # Detach the worker so rpcd's file.exec request returns before Docker finishes.
    nohup /bin/sh "$0" --worker "$ACTION" </dev/null >/dev/null 2>&1 &
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
