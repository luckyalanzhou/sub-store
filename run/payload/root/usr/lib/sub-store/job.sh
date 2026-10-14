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
    start|stop|restart|update|rotate-key|check|logs|clear-logs) ;;
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
else
    if ! mkdir "$STATE/lock" 2>/dev/null; then
        echo "Another operation is running." >&2
        exit 1
    fi
    trap 'rmdir "$STATE/lock"' EXIT
    printf '%s\n' "$ACTION" > "$STATE/action"
    printf '%s\n' running > "$STATE/phase"
    : > "$STATE/output.log"
    printf '正在执行：%s；开始时间：%s\n' "$ACTION" "$(date '+%Y-%m-%d %H:%M:%S')" > "$STATE/status"
fi
run_job() {
    trap 'rmdir "$STATE/lock"' EXIT
    trap 'printf "%s\n" interrupted > "$STATE/phase"; exit 130' INT
    trap 'printf "%s\n" interrupted > "$STATE/phase"; exit 143' TERM
    COMMAND=/usr/bin/sub-storectl
    set -- "$ACTION"
    trim_operation_log() {
        log_size="$(wc -c < "$STATE/output.log" | tr -d '[:space:]')"
        if [ -n "$log_size" ] && [ "$log_size" -gt 524288 ]; then
            trimmed_log="$(mktemp "$STATE/output.log.XXXXXX")"
            tail -c 524288 "$STATE/output.log" > "$trimmed_log"
            mv "$trimmed_log" "$STATE/output.log"
        fi
    }
    if "$COMMAND" "$@" > "$STATE/output.log" 2>&1; then
        trim_operation_log || true
        printf '操作成功：%s；完成时间：%s\n' "$ACTION" "$(date '+%Y-%m-%d %H:%M:%S')" > "$STATE/status"
        printf '%s\n' success > "$STATE/phase"
    else
        result=$?
        trim_operation_log || true
        printf '操作失败：%s；退出码：%s；请查看日志与诊断。\n' "$ACTION" "$result" > "$STATE/status"
        printf '%s\n' failed > "$STATE/phase"
        exit "$result"
    fi
}
if [ "$MODE" = "--enqueue" ]; then
    # Detach the worker so rpcd's file.exec request returns before Docker finishes.
    nohup /bin/sh "$0" --worker "$ACTION" </dev/null >/dev/null 2>&1 &
    trap - EXIT
    echo accepted
elif [ "$MODE" = "--worker" ]; then
    run_job
else
    run_job
fi
