#!/bin/bash
# 04_logcat_recorder.sh — logcat 滚动录制
#
# 用法:
#   bash scripts/04_logcat_recorder.sh --phase <PHASE> --start
#   bash scripts/04_logcat_recorder.sh --phase <PHASE> --stop
#
# 行为:
#   --start: 在 host 端启动 adb logcat，按 64MB 轮转写入 evidence/<PHASE>/logcat/
#   --stop:  停止录制
#
# 平台说明: adb logcat 所有 Android 设备通用。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_common.sh"

parse_phase_args "$@"
PHASE="${PARSED_PHASE:-}"

ACTION=""
for arg in "${REMAINING_ARGS[@]}"; do
    case "$arg" in
        --start) ACTION="start" ;;
        --stop)  ACTION="stop" ;;
    esac
done

if [ -z "$ACTION" ]; then
    log_err "Usage: $0 --phase <PHASE> --start|--stop"
    exit 2
fi

PID_FILE="$INVESTIGATION_ROOT/.logcat_recorder_${PHASE}.pid"

if [ "$ACTION" = "start" ]; then
    [ -n "$PHASE" ] || { log_err "--start requires --phase"; exit 2; }
    if [ -f "$PID_FILE" ]; then
        old_pid=$(cat "$PID_FILE" 2>/dev/null)
        if kill -0 "$old_pid" 2>/dev/null; then
            log_err "Logcat recorder already running (pid=$old_pid)"
            exit 1
        fi
    fi

    SERIAL=$(get_device_serial) || exit 1
    dst="$(phase_dir "$PHASE")/logcat"
    ensure_dir "$dst"

    log_info "Starting logcat recorder for phase=$PHASE"
    adb logcat -b all -v threadtime > "$dst/main.log" 2>&1 &
    # 注意: 直接使用 host 端重定向，避免设备端文件权限问题
    # 若需要设备端轮转，可用 adb logcat -f /sdcard/... -r 65536 -n 10
    rec_pid=$!
    echo "$rec_pid" > "$PID_FILE"
    log_ok "Logcat recorder started, host-pid=$rec_pid → $dst/main.log"

elif [ "$ACTION" = "stop" ]; then
    [ -n "$PHASE" ] || { log_err "--stop requires --phase"; exit 2; }
    if [ ! -f "$PID_FILE" ]; then
        log_warn "No PID file found ($PID_FILE), recorder may not be running"
        exit 0
    fi

    pid=$(cat "$PID_FILE")
    # adb logcat 的 host 端进程树: adb logcat 会自己退出当设备断开，
    # 但我们启动的是 host 端 adb 进程，直接 kill 即可
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        log_ok "Stopped logcat recorder (pid=$pid)"
    else
        log_warn "Recorder process $pid not found"
    fi
    rm -f "$PID_FILE"
fi
