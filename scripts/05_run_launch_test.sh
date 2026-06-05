#!/bin/bash
# 05_run_launch_test.sh — 启动耗时测试
#
# 用法:
#   bash scripts/05_run_launch_test.sh --phase <PHASE> [-c N] [-s SEC]
#
# 行为:
#   1. 读取 config.sh 中的 APP_LIST_FILE / LAUNCH_COUNT / LAUNCH_INTERVAL
#   2. 对每个 app: force-stop → am start -W (循环 c 次，间隔 s 秒)
#   3. 解析 TotalTime，输出 CSV + XLSX（若 openpyxl 可用）
#   4. 记录 started_at / ended_at 到 launch_window.txt
#
# 平台说明:
#   基于 `am start -W`（Activity Manager Wait），所有 Android 设备均支持。
#   TotalTime 的语义因设备/ROM 略有差异，建议在目标设备上用单次启动验证。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_common.sh"

COUNT="${LAUNCH_COUNT:-5}"
SLEEP_SEC="${LAUNCH_INTERVAL:-10}"

parse_phase_args "$@"
require_phase
PHASE="$PARSED_PHASE"

# 解析额外的 -c / -s（覆盖配置文件）
i=0
while [ $i -lt ${#REMAINING_ARGS[@]} ]; do
    arg="${REMAINING_ARGS[$i]}"
    case "$arg" in
        -c) COUNT="${REMAINING_ARGS[$((i+1))]}"; i=$((i+2)) ;;
        -s) SLEEP_SEC="${REMAINING_ARGS[$((i+1))]}"; i=$((i+2)) ;;
        *) log_warn "Ignoring unknown arg: $arg"; i=$((i+1)) ;;
    esac
done

SERIAL=$(get_device_serial) || exit 1
[ -f "$APP_LIST_FILE" ] || { log_err "App list missing: $APP_LIST_FILE"; exit 1; }

OUT_DIR="$(phase_dir "$PHASE")/launch_raw"
ensure_dir "$OUT_DIR"

log_info "==== 05_run_launch_test.sh phase=$PHASE c=$COUNT s=$SLEEP_SEC ===="
log_info "App list:     $APP_LIST_FILE"
log_info "Output dir:   $OUT_DIR"
log_info "Device:       $SERIAL"

# 估算耗时
est_per_app=$(( COUNT * (SLEEP_SEC + 3) ))
n_apps=$(grep -cEv '^[[:space:]]*$|^[[:space:]]*#' "$APP_LIST_FILE")
total_est=$(( n_apps * est_per_app ))
log_info "Estimated total time: ~${total_est}s (= $((total_est / 60)) min) for $n_apps apps"

# 保存原 stay_on 设置，测试前强制开"充电时常亮"
ORIG_STAY_ON=$(adb shell "settings get global stay_on_while_plugged_in 2>/dev/null" \
    | tr -d '\r' | head -1)
[ -z "$ORIG_STAY_ON" ] || [ "$ORIG_STAY_ON" = "null" ] && ORIG_STAY_ON=0
log_info "Saving stay_on_while_plugged_in (was: $ORIG_STAY_ON)"

adb shell "settings put global stay_on_while_plugged_in ${STAY_ON_WHILE_PLUGGED:-7}" >/dev/null 2>&1 || true
adb shell "input keyevent KEYCODE_WAKEUP" >/dev/null 2>&1 || true
adb shell "wm dismiss-keyguard" >/dev/null 2>&1 || true
log_info "Screen forced ON"

restore_stay_on() {
    adb shell "settings put global stay_on_while_plugged_in $ORIG_STAY_ON" >/dev/null 2>&1 || true
    log_info "Restored stay_on_while_plugged_in to $ORIG_STAY_ON"
}
trap restore_stay_on EXIT

# 记录 started_at
STARTED=$(ts_epoch)

# 输出文件
CSV_OUT="$OUT_DIR/apps_launch_${PHASE}.csv"
XLSX_OUT="$OUT_DIR/apps_launch_${PHASE}.xlsx"

# 写 CSV header
{
    echo -n "package,activity"
    for i in $(seq 1 $COUNT); do echo -n ",t${i}"; done
    echo ",avg,status"
} > "$CSV_OUT"

log_info "Starting launch tests..."

line_no=0
while IFS= read -r line || [ -n "$line" ]; do
    # 跳过空行和注释
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    line_no=$((line_no + 1))

    pkg="${line%%/*}"
    act_raw="${line#*/}"
    # 处理相对 activity
    if [[ "$act_raw" == .* ]]; then
        act="${pkg}${act_raw}"
    else
        act="$act_raw"
    fi

    log_info "[$line_no/$n_apps] $pkg (activity=$act)"

    # force-stop
    adb shell "am force-stop $pkg" >/dev/null 2>&1 || true
    sleep 1

    times=()
    status="ok"
    for i in $(seq 1 $COUNT); do
        t=-1
        # am start -W 输出 TotalTime: xxx
        out=$(adb shell "am start -W -n ${pkg}/${act}" 2>&1) || {
            log_warn "  am start failed for $pkg (attempt $i)"
            status="ERROR"
            times+=(-1)
            continue
        }
        t=$(echo "$out" | grep -m1 '^TotalTime:' | awk '{print $2}')
        if [ -z "$t" ] || ! [[ "$t" =~ ^[0-9]+$ ]]; then
            log_warn "  Cannot parse TotalTime for $pkg (attempt $i). Output was:"
            echo "$out" | sed 's/^/    /' >&2
            status="ERROR"
            times+=(-1)
            continue
        fi
        times+=("$t")
        log_info "  attempt $i: ${t}ms"

        if [ "$i" -lt "$COUNT" ]; then
            sleep "$SLEEP_SEC"
        fi
    done

    # 计算平均（排除 -1）
    sum=0
    valid=0
    for t in "${times[@]}"; do
        if [ "$t" -ge 0 ]; then
            sum=$((sum + t))
            valid=$((valid + 1))
        fi
    done
    if [ "$valid" -gt 0 ]; then
        avg=$((sum / valid))
    else
        avg=-1
        status="ALL_ERROR"
    fi

    # 写 CSV
    {
        echo -n "${pkg},${act_raw}"
        for t in "${times[@]}"; do
            if [ "$t" -ge 0 ]; then echo -n ",${t}"; else echo -n ","; fi
        done
        if [ "$avg" -ge 0 ]; then echo ",${avg},${status}"; else echo ",,${status}"; fi
    } >> "$CSV_OUT"

done < "$APP_LIST_FILE"

ENDED=$(ts_epoch)
DURATION=$((ENDED - STARTED))

log_ok "Launch test finished (duration: ${DURATION}s = $((DURATION / 60)) min)"

write_launch_window "$PHASE" "$STARTED" "$ENDED"

# 尝试生成 XLSX
if python3 -c "import openpyxl" 2>/dev/null; then
    python3 - "$CSV_OUT" "$XLSX_OUT" <<'PYEOF'
import sys, openpyxl, csv
from openpyxl.styles import Font

csv_path, xlsx_path = sys.argv[1], sys.argv[2]
wb = openpyxl.Workbook()
ws = wb.active
ws.title = "LaunchTimes"

with open(csv_path, newline='', encoding='utf-8') as f:
    reader = csv.reader(f)
    for row in reader:
        ws.append(row)

# 简单样式：header 加粗
for cell in ws[1]:
    cell.font = Font(bold=True)

wb.save(xlsx_path)
print(f"Generated {xlsx_path}")
PYEOF
else
    log_warn "openpyxl not available, skipping xlsx generation. CSV is ready."
fi

log_info "Output files:"
ls -1 "$OUT_DIR" 2>/dev/null | sed 's/^/  /' >&2
