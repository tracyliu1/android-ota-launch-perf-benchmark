#!/bin/bash
# 03_timeline_sampler.sh — 系统负载采样（host 端轮询）
#
# 用法:
#   bash scripts/03_timeline_sampler.sh --phase <PHASE> --start
#   bash scripts/03_timeline_sampler.sh --phase <PHASE> --stop
#
# 行为:
#   --start: 在 host 端启动后台进程，每 30 秒通过 adb shell 采样一次系统状态
#   --stop:  停止采样，把数据保存到 evidence/<run-tag>/<device>_<PHASE>/timeline/
#
# 采样字段（CSV）:
#   epoch,iso_datetime,loadavg_1m,loadavg_5m,loadavg_15m,
#   mem_total_kb,mem_avail_kb,dex2oat_count,dex2oat_cpu_pct,
#   dexopt_job_status,merge_status,iowait_pct,user_pct,system_pct
#
# 平台说明:
#   [MTK/Android12] merge_status 通过 getprop / cmd update_engine 获取，
#   若设备不支持 VAB 或不支持对应命令，该列会显示 UNKNOWN。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_common.sh"

parse_phase_args "$@"
PHASE="${PARSED_PHASE:-}"
[ -z "$PHASE" ] || validate_phase "$PHASE"

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

PID_FILE="$INVESTIGATION_ROOT/.timeline_sampler_${PHASE}.pid"
LOG_FILE="$INVESTIGATION_ROOT/.timeline_sampler_${PHASE}.log"

timeline_tick() {
    local epoch=$(ts_epoch)
    local iso=$(ts_iso)
    local loadavg=$(adb shell "cat /proc/loadavg" 2>/dev/null | tr -d '\r')
    local load1=$(echo "$loadavg" | awk '{print $1}')
    local load5=$(echo "$loadavg" | awk '{print $2}')
    local load15=$(echo "$loadavg" | awk '{print $3}')

    local meminfo=$(adb shell "cat /proc/meminfo" 2>/dev/null || true)
    local mem_total=$(echo "$meminfo" | grep -m1 MemTotal | awk '{print $2}')
    local mem_avail=$(echo "$meminfo" | grep -m1 MemAvailable | awk '{print $2}')

    # dex2oat 进程
    local dex2oat_pids=$(adb shell "pidof dex2oat" 2>/dev/null | tr -d '\r')
    local dex2oat_count=0
    local dex2oat_cpu="0"
    if [ -n "$dex2oat_pids" ]; then
        dex2oat_count=$(echo "$dex2oat_pids" | wc -w | tr -d ' ')
        # 尝试统计 dex2oat CPU 占用（top -n1 单帧）
        dex2oat_cpu=$(adb shell "top -n1 -p $(echo $dex2oat_pids | tr ' ' ',') 2>/dev/null" | tail -1 | awk '{print $9}' || echo "0")
    fi

    # dexopt job 状态
    local dexopt_job=$(adb shell "dumpsys jobscheduler | grep -A 5 'BackgroundDexOpt' | head -6" 2>/dev/null | tr '\n' ';' | tr -d '\r')

    # VAB merge 状态
    local merge_status="UNKNOWN"
    if [ "${HAS_VAB:-true}" = "true" ]; then
        merge_status=$(adb shell "cmd update_engine merge_status 2>/dev/null || getprop ro.boot.slot_suffix 2>/dev/null" | tr -d '\r')
    fi

    # CPU 拆分（从 /proc/stat 第一行计算）
    local cpu_line=$(adb shell "cat /proc/stat" 2>/dev/null | grep '^cpu ' | tr -d '\r')
    local cpu_user="" cpu_sys="" cpu_iow=""
    if [ -n "$cpu_line" ]; then
        # 简化为直接读 top -n1 的汇总行
        local top_cpu=$(adb shell "top -n1 2>/dev/null | grep -m1 '%cpu' || top -n1 2>/dev/null | grep -m1 'CPU:'" | tr -d '\r')
        cpu_user=$(echo "$top_cpu" | sed -n 's/.*user[^0-9]*\([0-9.]*\).*/\1/p')
        cpu_sys=$(echo "$top_cpu" | sed -n 's/.*sys[^0-9]*\([0-9.]*\).*/\1/p')
        cpu_iow=$(echo "$top_cpu" | sed -n 's/.*iow[^0-9]*\([0-9.]*\).*/\1/p')
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s","%s",%s,%s,%s\n' \
        "$epoch" "$iso" "$load1" "$load5" "$load15" \
        "${mem_total:-}" "${mem_avail:-}" "$dex2oat_count" "${dex2oat_cpu:-0}" \
        "${dexopt_job:-}" "${merge_status:-UNKNOWN}" \
        "${cpu_iow:-}" "${cpu_user:-}" "${cpu_sys:-}"
}

if [ "$ACTION" = "start" ]; then
    [ -n "$PHASE" ] || { log_err "--start requires --phase"; exit 2; }
    if [ -f "$PID_FILE" ]; then
        old_pid=$(cat "$PID_FILE" 2>/dev/null)
        if kill -0 "$old_pid" 2>/dev/null; then
            log_err "Timeline sampler already running (pid=$old_pid)"
            exit 1
        fi
    fi

    SERIAL=$(get_device_serial) || exit 1
    log_info "Starting timeline sampler for phase=$PHASE (interval=30s)"

    # 启动后台采样进程
    (
        # 写 CSV header
        out_tmp="$INVESTIGATION_ROOT/.timeline_${PHASE}.csv"
        echo "epoch,iso_datetime,loadavg_1m,loadavg_5m,loadavg_15m,mem_total_kb,mem_avail_kb,dex2oat_count,dex2oat_cpu_pct,dexopt_job_status,merge_status,iowait_pct,user_pct,system_pct" > "$out_tmp"

        while true; do
            timeline_tick >> "$out_tmp" 2>/dev/null || true
            sleep 30
        done
    ) >"$LOG_FILE" 2>&1 &

    sampler_pid=$!
    echo "$sampler_pid" > "$PID_FILE"
    log_ok "Timeline sampler started, host-pid=$sampler_pid"
    log_info "Output will be saved to $(phase_dir "$PHASE")/timeline/ upon --stop"

elif [ "$ACTION" = "stop" ]; then
    [ -n "$PHASE" ] || { log_err "--stop requires --phase"; exit 2; }
    if [ ! -f "$PID_FILE" ]; then
        log_warn "No PID file found ($PID_FILE), sampler may not be running"
        exit 0
    fi

    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        log_ok "Stopped timeline sampler (pid=$pid)"
    else
        log_warn "Sampler process $pid not found"
    fi

    rm -f "$PID_FILE"

    # 归档
    src="$INVESTIGATION_ROOT/.timeline_${PHASE}.csv"
    dst="$(phase_dir "$PHASE")/timeline"
    ensure_dir "$dst"
    if [ -f "$src" ]; then
        mv "$src" "$dst/timeline.csv"
        log_ok "Timeline saved → $dst/timeline.csv"
        # 顺便把 log 也归档
        if [ -f "$LOG_FILE" ]; then
            mv "$LOG_FILE" "$dst/sampler.log"
        fi
    else
        log_warn "No timeline CSV found at $src"
    fi
fi
