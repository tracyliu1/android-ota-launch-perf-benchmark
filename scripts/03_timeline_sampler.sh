#!/bin/bash
# 03_timeline_sampler.sh — 系统负载采样（host 端轮询）
#
# 用法:
#   bash scripts/03_timeline_sampler.sh --phase <PHASE> --start
#   bash scripts/03_timeline_sampler.sh --phase <PHASE> --stop
#
# 行为:
#   --start: 在 host 端启动后台进程，按 TIMELINE_INTERVAL_SEC 通过 adb shell 采样系统状态
#   --stop:  停止采样，把数据保存到 evidence/<run-tag>/<device>_<PHASE>/timeline/
#
# 采样字段（CSV）:
#   epoch,iso_datetime,loadavg_1m,loadavg_5m,loadavg_15m,
#   mem_total_kb,mem_avail_kb,dex2oat_count,dex2oat_cpu_pct,
#   dexopt_job_status,merge_status,iowait_pct,user_pct,system_pct,
#   ac_powered,usb_powered,wireless_powered,max_charging_current,battery_level,battery_temp,
#   policy*_cur_freq,policy*_min_freq,policy*_max_freq,policy*_governor,
#   thermal_max_temp,thermal_max_type
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

SCRATCH_KEY="$(host_scratch_key "$PHASE")"
PID_FILE="$INVESTIGATION_ROOT/.timeline_sampler_${SCRATCH_KEY}.pid"
LOG_FILE="$INVESTIGATION_ROOT/.timeline_sampler_${SCRATCH_KEY}.log"
CSV_FILE="$INVESTIGATION_ROOT/.timeline_${SCRATCH_KEY}.csv"

TIMELINE_INTERVAL_SEC="${TIMELINE_INTERVAL_SEC:-30}"

csv_escape() {
    local s="${1:-}"
    s="${s//$'\r'/}"
    s="${s//$'\n'/;}"
    s="${s//\"/\"\"}"
    printf '"%s"' "$s"
}

is_enabled() {
    case "${1:-}" in
        true|TRUE|1|yes|YES|y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

timeline_header() {
    local header="epoch,iso_datetime,loadavg_1m,loadavg_5m,loadavg_15m,mem_total_kb,mem_avail_kb,dex2oat_count,dex2oat_cpu_pct,dexopt_job_status,merge_status,iowait_pct,user_pct,system_pct"

    if is_enabled "${TIMELINE_CAPTURE_BATTERY:-true}"; then
        header+=",ac_powered,usb_powered,wireless_powered,max_charging_current,battery_level,battery_temp"
    fi

    if is_enabled "${TIMELINE_CAPTURE_CPUFREQ:-true}"; then
        local policy
        for policy in "${TIMELINE_CPU_POLICIES[@]}"; do
            header+=",policy${policy}_cur_freq,policy${policy}_min_freq,policy${policy}_max_freq,policy${policy}_governor"
        done
    fi

    if is_enabled "${TIMELINE_CAPTURE_THERMAL:-true}"; then
        header+=",thermal_max_temp,thermal_max_type"
    fi

    printf '%s\n' "$header"
}

read_proc_stat_cpu() {
    adb shell "cat /proc/stat" 2>/dev/null | awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11; exit}' | tr -d '\r'
}

calc_cpu_pct() {
    local a="$1" b="$2" index="$3"
    awk -v a="$a" -v b="$b" -v idx="$index" '
        BEGIN {
            split(a, aa, " ");
            split(b, bb, " ");
            total = 0;
            for (i = 1; i <= 10; i++) {
                d[i] = bb[i] - aa[i];
                total += d[i];
            }
            if (total <= 0) {
                printf "";
            } else {
                printf "%.1f", d[idx] * 100 / total;
            }
        }'
}

sample_battery_fields() {
    if ! is_enabled "${TIMELINE_CAPTURE_BATTERY:-true}"; then
        return 0
    fi

    local battery ac usb wireless current level temp
    battery=$(adb shell "dumpsys battery" 2>/dev/null | tr -d '\r' || true)
    ac=$(echo "$battery" | awk -F': ' '/AC powered:/ {print $2; exit}')
    usb=$(echo "$battery" | awk -F': ' '/USB powered:/ {print $2; exit}')
    wireless=$(echo "$battery" | awk -F': ' '/Wireless powered:/ {print $2; exit}')
    current=$(echo "$battery" | awk -F': ' '/Max charging current:/ {print $2; exit}')
    level=$(echo "$battery" | awk -F': ' '/level:/ {print $2; exit}')
    temp=$(echo "$battery" | awk -F': ' '/temperature:/ {print $2; exit}')
    printf ',%s,%s,%s,%s,%s,%s' "${ac:-}" "${usb:-}" "${wireless:-}" "${current:-}" "${level:-}" "${temp:-}"
}

sample_cpufreq_fields() {
    if ! is_enabled "${TIMELINE_CAPTURE_CPUFREQ:-true}"; then
        return 0
    fi

    local policy base cur min max gov
    for policy in "${TIMELINE_CPU_POLICIES[@]}"; do
        base="/sys/devices/system/cpu/cpufreq/policy${policy}"
        cur=$(adb shell "cat $base/scaling_cur_freq 2>/dev/null" | tr -d '\r' || true)
        min=$(adb shell "cat $base/scaling_min_freq 2>/dev/null" | tr -d '\r' || true)
        max=$(adb shell "cat $base/scaling_max_freq 2>/dev/null" | tr -d '\r' || true)
        gov=$(adb shell "cat $base/scaling_governor 2>/dev/null" | tr -d '\r' || true)
        printf ',%s,%s,%s,%s' "${cur:-}" "${min:-}" "${max:-}" "${gov:-}"
    done
}

sample_thermal_fields() {
    if ! is_enabled "${TIMELINE_CAPTURE_THERMAL:-true}"; then
        return 0
    fi

    local out max_temp max_type
    out=$(adb shell '
        for z in /sys/class/thermal/thermal_zone*; do
            [ -r "$z/temp" ] || continue
            temp=$(cat "$z/temp" 2>/dev/null)
            case "$temp" in
                ""|*[!0-9-]*) continue ;;
            esac
            type=$(cat "$z/type" 2>/dev/null)
            echo "$temp $type"
        done
    ' 2>/dev/null | tr -d '\r' || true)
    if [ -n "$out" ]; then
        max_temp=$(echo "$out" | awk 'BEGIN{m=""} {if (m=="" || $1>m) {m=$1; $1=""; sub(/^ /,""); t=$0}} END{print m}')
        max_type=$(echo "$out" | awk 'BEGIN{m=""} {if (m=="" || $1>m) {m=$1; $1=""; sub(/^ /,""); t=$0}} END{print t}')
    fi
    printf ',%s,' "${max_temp:-}"
    csv_escape "${max_type:-}"
}

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

    # CPU 拆分：/proc/stat 两次采样计算 delta，避免依赖 top 输出格式。
    local cpu_a cpu_b cpu_user="" cpu_sys="" cpu_iow=""
    cpu_a=$(read_proc_stat_cpu || true)
    sleep 1
    cpu_b=$(read_proc_stat_cpu || true)
    if [ -n "$cpu_a" ] && [ -n "$cpu_b" ]; then
        cpu_user=$(calc_cpu_pct "$cpu_a" "$cpu_b" 1)
        cpu_sys=$(calc_cpu_pct "$cpu_a" "$cpu_b" 3)
        cpu_iow=$(calc_cpu_pct "$cpu_a" "$cpu_b" 5)
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,' \
        "$epoch" "$iso" "$load1" "$load5" "$load15" \
        "${mem_total:-}" "${mem_avail:-}" "$dex2oat_count" "${dex2oat_cpu:-0}"
    csv_escape "${dexopt_job:-}"
    printf ','
    csv_escape "${merge_status:-UNKNOWN}"
    printf ',%s,%s,%s' "${cpu_iow:-}" "${cpu_user:-}" "${cpu_sys:-}"
    sample_battery_fields
    sample_cpufreq_fields
    sample_thermal_fields
    printf '\n'
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
    log_info "Starting timeline sampler for phase=$PHASE target=$(device_tag) (interval=${TIMELINE_INTERVAL_SEC}s)"

    # 启动后台采样进程
    (
        # 写 CSV header
        timeline_header > "$CSV_FILE"

        while true; do
            timeline_tick >> "$CSV_FILE" 2>/dev/null || true
            sleep "$TIMELINE_INTERVAL_SEC"
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
    src="$CSV_FILE"
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
