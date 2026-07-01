#!/bin/bash
# 05_run_launch_test.sh — 启动耗时测试与低成本证据采集
#
# 用法:
#   bash scripts/05_run_launch_test.sh --phase <PHASE> [-c N] [-s SEC]
#
# 行为:
#   1. 读取 config.sh 中的 APP_LIST_FILE / LAUNCH_COUNT / BETWEEN_ATTEMPT_SLEEP_SEC
#   2. 对每个 app: force-stop -> logcat -c -> am start -W -> 抓启动窗口 logcat
#   3. 默认只保存 am start 原始输出、filtered logcat evidence、结构化 CSV
#   4. FULL_LOGCAT=1 时额外保存每次 attempt 的完整启动窗口 logcat

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_common.sh"

COUNT="${LAUNCH_COUNT:-5}"
SLEEP_SEC="${BETWEEN_ATTEMPT_SLEEP_SEC:-${LAUNCH_INTERVAL:-10}}"
LOGCAT_CAPTURE="${LOGCAT_CAPTURE_SEC:-5}"
FULL_LOGCAT="${FULL_LOGCAT:-0}"
# hook 线程级归因专用关键字（与宽口径 KEYWORD_PATTERNS 区分；只针对怀疑的 hook/监控库）
HOOK_KEYWORDS="${HOOK_KEYWORDS:-bytehook|rmonitor|shadowhook}"

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
AM_RAW_DIR="$OUT_DIR/am_start_raw"
LOG_EVIDENCE_DIR="$OUT_DIR/logcat_evidence"
LOG_FULL_DIR="$OUT_DIR/logcat_full"
TMP_DIR="$OUT_DIR/.tmp"
ensure_dir "$OUT_DIR"
ensure_dir "$AM_RAW_DIR"
ensure_dir "$LOG_EVIDENCE_DIR"
ensure_dir "$TMP_DIR"
[ "$FULL_LOGCAT" = "1" ] && ensure_dir "$LOG_FULL_DIR"

log_info "==== 05_run_launch_test.sh phase=$PHASE c=$COUNT sleep=$SLEEP_SEC logcat_capture=${LOGCAT_CAPTURE}s full_logcat=$FULL_LOGCAT ===="
log_info "App list:     $APP_LIST_FILE"
log_info "Output dir:   $OUT_DIR"
log_info "Device:       $SERIAL"

# 估算耗时
est_per_app=$(( COUNT * (SLEEP_SEC + LOGCAT_CAPTURE + 3) ))
n_apps=$(grep -cEv '^[[:space:]]*$|^[[:space:]]*#' "$APP_LIST_FILE")
total_est=$(( n_apps * est_per_app ))
log_info "Estimated total time: ~${total_est}s (= $((total_est / 60)) min) for $n_apps apps"

csv_escape() {
    local s="${1:-}"
    s="${s//$'\r'/}"
    s="${s//$'\n'/;}"
    s="${s//\"/\"\"}"
    printf '"%s"' "$s"
}

sanitize_file_part() {
    printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_*//;s/_*$//'
}

bool_true() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

keyword_regex() {
    if [ -n "${KEYWORD_PATTERNS:-}" ]; then
        printf '%s' "$KEYWORD_PATTERNS"
    else
        printf '%s' 'bytehook|rmonitor|shadowhook|bugly|eup|webview|chromium|SurfaceFlinger|C2MtkBufferManager'
    fi
}

count_keyword() {
    local file="$1"
    local pattern="$2"
    { grep -E -i -o "$pattern" "$file" 2>/dev/null || true; } | wc -l | tr -d ' '
}

# 基于 logcat(threadtime) 时间戳 + TID 做 hook 归因。
# 输出以 '|' 分隔的 7 个字段（缺失留空）：
#   cold_window_ms|hook_hits_in_window|hook_hits_after_displayed|
#   hook_main_hits_in_window|hook_worker_hits_in_window|hook_main_span_ms|hook_first_offset_ms
# 口径：
#   - 冷启动窗口 = [目标进程 Start proc 时间, 该 pkg 首条 Displayed 时间]
#   - 主线程 = hook 行 TID($4) == 目标进程 PID；子线程 = $3==pid 且 $4!=pid
#   - 只统计 $3==pid（确属目标进程）的 hook 行，排除其他进程噪声
compute_hook_attribution() {
    local file="$1" pkg="$2" pid="$3" hookre="$4"
    if [ -z "$pid" ]; then
        printf '||||||\n'
        return 0
    fi
    awk -v pid="$pid" -v pkg="$pkg" -v hookre="$hookre" '
    function toms(t,   a) {
        if (t !~ /^[0-9]+:[0-9]+:[0-9]+\.[0-9]+$/) return -1
        split(t, a, ":")
        return ((a[1]*60)+a[2])*60000 + a[3]*1000
    }
    { t = toms($2) }
    index($0, "ActivityManager: Start proc " pid ":" pkg) > 0 && start=="" { start = t }
    index($0, "ActivityTaskManager: Displayed " pkg "/") > 0 && disp=="" { disp = t }
    ($3 == pid && $0 ~ hookre) {
        n++
        ev_ts[n] = t
        ev_main[n] = ($4 == pid) ? 1 : 0
    }
    END {
        cw=""; hin=0; haft=0; mainin=0; workin=0; span=""; foff=""
        if (start != "" && disp != "") cw = disp - start
        minm=""; maxm=""; minin=""
        for (i = 1; i <= n; i++) {
            ts = ev_ts[i]
            if (ts < 0) continue
            if (start != "" && disp != "" && ts >= start && ts <= disp) {
                hin++
                if (minin == "" || ts < minin) minin = ts
                if (ev_main[i]) {
                    mainin++
                    if (minm == "" || ts < minm) minm = ts
                    if (maxm == "" || ts > maxm) maxm = ts
                } else {
                    workin++
                }
            } else if (disp != "" && ts > disp) {
                haft++
            }
        }
        if (minm != "" && maxm != "") span = maxm - minm
        if (minin != "" && start != "") foff = minin - start
        printf "%s|%s|%s|%s|%s|%s|%s\n", cw, hin, haft, mainin, workin, span, foff
    }
    ' "$file" 2>/dev/null || printf '||||||\n'
}

extract_field() {
    local name="$1"
    local file="$2"
    sed -n "s/^${name}: //p" "$file" | tail -1 | tr -d '\r'
}

extract_status() {
    local file="$1"
    sed -n 's/^Status: //p' "$file" | tail -1 | tr -d '\r'
}

extract_target_pid() {
    local pkg="$1"
    local file="$2"
    local pid=""
    pid=$(grep -E "ActivityManager: Start proc [0-9]+:${pkg}(/| |$)" "$file" \
        | tail -1 \
        | sed -n 's/.*Start proc \([0-9][0-9]*\):.*/\1/p' || true)
    if [ -z "$pid" ]; then
        pid=$(grep -E "packageName=${pkg}.*pid=[0-9]+" "$file" \
            | tail -1 \
            | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' || true)
    fi
    printf '%s' "$pid"
}

first_start_activity() {
    local pkg="$1"
    local file="$2"
    grep -E "ActivityTaskManager: START .*cmp=${pkg}/" "$file" \
        | head -1 \
        | sed -n 's/.*cmp=\([^ }]*\).*/\1/p' || true
}

final_start_activity() {
    local pkg="$1"
    local file="$2"
    grep -E "ActivityTaskManager: START .*cmp=${pkg}/" "$file" \
        | tail -1 \
        | sed -n 's/.*cmp=\([^ }]*\).*/\1/p' || true
}

start_chain() {
    local pkg="$1"
    local file="$2"
    grep -E "ActivityTaskManager: START .*cmp=${pkg}/" "$file" \
        | sed -n 's/.*cmp=\([^ }]*\).*/\1/p' \
        | awk 'BEGIN { first=1 } { if (!first) printf " > "; printf "%s", $0; first=0 } END { if (!first) printf "\n" }' || true
}

displayed_line_for_pkg() {
    local pkg="$1"
    local file="$2"
    grep -E "ActivityTaskManager: Displayed ${pkg}/" "$file" | tail -1 || true
}

displayed_activity_from_line() {
    sed -n 's/.*ActivityTaskManager: Displayed \([^:]*\): .*/\1/p'
}

displayed_ms_from_line() {
    local line="$1"
    local raw=""
    raw=$(printf '%s' "$line" | sed -n 's/.*: +\([^ ]*\).*/\1/p' | sed 's/ms$//' || true)
    if [[ "$raw" =~ ^([0-9]+)s([0-9]+)$ ]]; then
        printf '%s' $((10#${BASH_REMATCH[1]} * 1000 + 10#${BASH_REMATCH[2]}))
    elif [[ "$raw" =~ ^[0-9]+$ ]]; then
        printf '%s' "$raw"
    else
        printf ''
    fi
}

write_filtered_logcat() {
    local log_file="$1"
    local out_file="$2"
    local pattern
    pattern="$(keyword_regex)"
    grep -E -i "ActivityTaskManager|ActivityManager: Start proc|${pattern}" "$log_file" > "$out_file" 2>/dev/null || true
}

# 保存原 stay_on 设置，测试前强制开"充电时常亮"
ORIG_STAY_ON=$(adb -s "$SERIAL" shell "settings get global stay_on_while_plugged_in 2>/dev/null" \
    | tr -d '\r' | head -1)
[ -z "$ORIG_STAY_ON" ] || [ "$ORIG_STAY_ON" = "null" ] && ORIG_STAY_ON=0
log_info "Saving stay_on_while_plugged_in (was: $ORIG_STAY_ON)"

adb -s "$SERIAL" shell "settings put global stay_on_while_plugged_in ${STAY_ON_WHILE_PLUGGED:-7}" >/dev/null 2>&1 || true
adb -s "$SERIAL" shell "input keyevent KEYCODE_WAKEUP" >/dev/null 2>&1 || true
adb -s "$SERIAL" shell "wm dismiss-keyguard" >/dev/null 2>&1 || true
log_info "Screen forced ON"

restore_stay_on() {
    adb -s "$SERIAL" shell "settings put global stay_on_while_plugged_in $ORIG_STAY_ON" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR" >/dev/null 2>&1 || true
    log_info "Restored stay_on_while_plugged_in to $ORIG_STAY_ON"
}
trap restore_stay_on EXIT

STARTED=$(ts_epoch)

CSV_OUT="$OUT_DIR/apps_launch_${PHASE}.csv"
XLSX_OUT="$OUT_DIR/apps_launch_${PHASE}.xlsx"
ATTEMPT_CSV_OUT="$OUT_DIR/apps_launch_attempts_${PHASE}.csv"
DETAIL_CSV_OUT="$OUT_DIR/apps_launch_attempts_detail_${PHASE}.csv"
KEYWORD_CSV_OUT="$OUT_DIR/apps_launch_keyword_summary_${PHASE}.csv"

{
    echo -n "package,activity"
    for i in $(seq 1 "$COUNT"); do echo -n ",t${i}"; done
    echo ",avg,status"
} > "$CSV_OUT"

echo "package,activity,attempt,attempt_start_epoch,attempt_start_iso,attempt_end_epoch,attempt_end_iso,total_time_ms,status,error" > "$ATTEMPT_CSV_OUT"
echo "package,activity,component,attempt,attempt_start_epoch,attempt_start_iso,attempt_end_epoch,attempt_end_iso,status,launch_state,am_activity,total_time_ms,wait_time_ms,displayed_activity,displayed_time_ms,first_start_activity,final_start_activity,start_chain,target_pid,keyword_total,keyword_target_pid,bytehook_total,bytehook_target_pid,rmonitor_total,rmonitor_target_pid,shadowhook_total,shadowhook_target_pid,bugly_total,bugly_target_pid,evidence_logcat,full_logcat,am_raw,error,cold_window_ms,hook_hits_in_window,hook_hits_after_displayed,hook_main_hits_in_window,hook_worker_hits_in_window,hook_main_span_ms,hook_first_offset_ms" > "$DETAIL_CSV_OUT"
echo "package,activity,attempt,target_pid,keyword_total,keyword_target_pid,bytehook_total,bytehook_target_pid,rmonitor_total,rmonitor_target_pid,shadowhook_total,shadowhook_target_pid,bugly_total,bugly_target_pid" > "$KEYWORD_CSV_OUT"

log_info "Starting launch tests..."

line_no=0
while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    line_no=$((line_no + 1))

    pkg="${line%%/*}"
    act_raw="${line#*/}"
    if [[ "$act_raw" == .* ]]; then
        act="${pkg}${act_raw}"
    else
        act="$act_raw"
    fi
    component="${pkg}/${act}"
    file_pkg="$(sanitize_file_part "$pkg")"

    log_info "[$line_no/$n_apps] $pkg (activity=$act)"

    times=()
    status="ok"
    for i in $(seq 1 "$COUNT"); do
        base="${line_no}_${i}_${file_pkg}"
        am_raw="$AM_RAW_DIR/${base}_am.txt"
        evidence_log="$LOG_EVIDENCE_DIR/${base}_evidence_logcat.txt"
        tmp_log="$TMP_DIR/${base}_logcat.txt"
        full_log=""
        if [ "$FULL_LOGCAT" = "1" ]; then
            full_log="$LOG_FULL_DIR/${base}_full_logcat.txt"
        fi

        adb -s "$SERIAL" shell "am force-stop $pkg" </dev/null >/dev/null 2>&1 || true
        sleep 1
        adb -s "$SERIAL" logcat -c </dev/null >/dev/null 2>&1 || true
        sleep 1

        attempt_start=$(ts_epoch)
        attempt_start_iso=$(ts_iso)
        {
            echo "package=$pkg"
            echo "activity=$act_raw"
            echo "component=$component"
            echo "attempt=$i"
            adb -s "$SERIAL" shell "am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n '$component'" </dev/null
        } > "$am_raw" 2>&1 || true

        sleep "$LOGCAT_CAPTURE"
        adb -s "$SERIAL" logcat -d -v threadtime </dev/null > "$tmp_log" 2>&1 || true
        attempt_end=$(ts_epoch)
        attempt_end_iso=$(ts_iso)

        write_filtered_logcat "$tmp_log" "$evidence_log"
        if [ "$FULL_LOGCAT" = "1" ]; then
            cp "$tmp_log" "$full_log"
        fi

        adb -s "$SERIAL" shell "input keyevent HOME" </dev/null >/dev/null 2>&1 || true

        am_status="$(extract_status "$am_raw")"
        launch_state="$(extract_field "LaunchState" "$am_raw")"
        am_activity="$(extract_field "Activity" "$am_raw")"
        total_time="$(extract_field "TotalTime" "$am_raw")"
        wait_time="$(extract_field "WaitTime" "$am_raw")"
        dline="$(displayed_line_for_pkg "$pkg" "$tmp_log")"
        displayed_activity=""
        displayed_time=""
        if [ -n "$dline" ]; then
            displayed_activity="$(printf '%s' "$dline" | displayed_activity_from_line)"
            displayed_time="$(displayed_ms_from_line "$dline")"
        fi
        first_start="$(first_start_activity "$pkg" "$tmp_log")"
        final_start="$(final_start_activity "$pkg" "$tmp_log")"
        chain="$(start_chain "$pkg" "$tmp_log")"
        target_pid="$(extract_target_pid "$pkg" "$tmp_log")"
        pattern="$(keyword_regex)"
        keyword_total="$(count_keyword "$tmp_log" "$pattern")"
        keyword_target=0
        bytehook_total="$(count_keyword "$tmp_log" "bytehook")"
        rmonitor_total="$(count_keyword "$tmp_log" "rmonitor")"
        shadowhook_total="$(count_keyword "$tmp_log" "shadowhook")"
        bugly_total="$(count_keyword "$tmp_log" "bugly|eup")"
        bytehook_target=0
        rmonitor_target=0
        shadowhook_target=0
        bugly_target=0
        if [ -n "$target_pid" ]; then
            pid_log="$TMP_DIR/${base}_pid_logcat.txt"
            awk -v pid="$target_pid" '$3 == pid || $4 == pid {print}' "$tmp_log" > "$pid_log" || true
            keyword_target="$(count_keyword "$pid_log" "$pattern")"
            bytehook_target="$(count_keyword "$pid_log" "bytehook")"
            rmonitor_target="$(count_keyword "$pid_log" "rmonitor")"
            shadowhook_target="$(count_keyword "$pid_log" "shadowhook")"
            bugly_target="$(count_keyword "$pid_log" "bugly|eup")"
        fi

        # hook 线程级 + 时间级归因（基于 logcat 时间戳与 TID）
        hook_attr="$(compute_hook_attribution "$tmp_log" "$pkg" "$target_pid" "$HOOK_KEYWORDS")"
        IFS='|' read -r cold_window_ms hook_hits_in_window hook_hits_after_displayed \
            hook_main_hits_in_window hook_worker_hits_in_window hook_main_span_ms hook_first_offset_ms \
            <<< "$hook_attr"

        err=""
        attempt_status="ok"
        if [ "${am_status:-}" != "ok" ]; then
            attempt_status="ERROR"
            status="ERROR"
            err="status_not_ok"
        fi
        if [ -z "$total_time" ] || ! [[ "$total_time" =~ ^[0-9]+$ ]]; then
            attempt_status="ERROR"
            status="ERROR"
            err="${err:+$err;}total_time_missing"
            times+=(-1)
            log_warn "  attempt $i: TotalTime missing ($pkg)"
        else
            times+=("$total_time")
            log_info "  attempt $i: ${total_time}ms"
        fi

        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,' \
            "$(csv_escape "$pkg")" "$(csv_escape "$act_raw")" "$i" \
            "$attempt_start" "$attempt_start_iso" "$attempt_end" "$attempt_end_iso" \
            "${total_time:-}" "$attempt_status" >> "$ATTEMPT_CSV_OUT"
        csv_escape "$err" >> "$ATTEMPT_CSV_OUT"
        printf '\n' >> "$ATTEMPT_CSV_OUT"

        {
            csv_escape "$pkg"; printf ','
            csv_escape "$act_raw"; printf ','
            csv_escape "$component"; printf ','
            printf '%s,%s,' "$i" "$attempt_start"
            csv_escape "$attempt_start_iso"; printf ','
            printf '%s,' "$attempt_end"
            csv_escape "$attempt_end_iso"; printf ','
            csv_escape "$am_status"; printf ','
            csv_escape "$launch_state"; printf ','
            csv_escape "$am_activity"; printf ','
            printf '%s,%s,' "${total_time:-}" "${wait_time:-}"
            csv_escape "$displayed_activity"; printf ','
            printf '%s,' "${displayed_time:-}"
            csv_escape "$first_start"; printf ','
            csv_escape "$final_start"; printf ','
            csv_escape "$chain"; printf ','
            csv_escape "$target_pid"; printf ','
            printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,' \
                "$keyword_total" "$keyword_target" \
                "$bytehook_total" "$bytehook_target" \
                "$rmonitor_total" "$rmonitor_target" \
                "$shadowhook_total" "$shadowhook_target" \
                "$bugly_total" "$bugly_target"
            csv_escape "$evidence_log"; printf ','
            csv_escape "$full_log"; printf ','
            csv_escape "$am_raw"; printf ','
            csv_escape "$err"; printf ','
            printf '%s,%s,%s,%s,%s,%s,%s\n' \
                "${cold_window_ms:-}" "${hook_hits_in_window:-}" "${hook_hits_after_displayed:-}" \
                "${hook_main_hits_in_window:-}" "${hook_worker_hits_in_window:-}" \
                "${hook_main_span_ms:-}" "${hook_first_offset_ms:-}"
        } >> "$DETAIL_CSV_OUT"

        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$(csv_escape "$pkg")" "$(csv_escape "$act_raw")" "$i" "$(csv_escape "$target_pid")" \
            "$keyword_total" "$keyword_target" "$bytehook_total" "$bytehook_target" \
            "$rmonitor_total" "$rmonitor_target" "$shadowhook_total" "$shadowhook_target" \
            "$bugly_total" "$bugly_target" >> "$KEYWORD_CSV_OUT"

        rm -f "$tmp_log" "$TMP_DIR/${base}_pid_logcat.txt" >/dev/null 2>&1 || true

        if [ "$i" -lt "$COUNT" ]; then
            sleep "$SLEEP_SEC"
        fi
    done

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

{
    echo "phase=$PHASE"
    echo "count=$COUNT"
    echo "between_attempt_sleep_sec=$SLEEP_SEC"
    echo "logcat_capture_sec=$LOGCAT_CAPTURE"
    echo "full_logcat=$FULL_LOGCAT"
    echo "output_dir=$OUT_DIR"
    du -sh "$OUT_DIR" 2>/dev/null || true
    find "$OUT_DIR" -type f -name '*logcat*.txt' -printf '%s %p\n' 2>/dev/null | sort -nr | head -10 || true
} > "$OUT_DIR/run_size_summary.txt"

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
