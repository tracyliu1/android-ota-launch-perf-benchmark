#!/bin/bash
# 02_dump_dexopt_state.sh — 采集 dexopt 编译状态快照
#
# 用法:
#   bash scripts/02_dump_dexopt_state.sh --phase <PHASE> --suffix <before|after>
#
# 产出: evidence/<run-tag>/<device>_<PHASE>/dexopt_<suffix>.csv
# 字段: pkg,installed,isa,filter,reason,base_apk_path,oat_odex_size,oat_odex_mtime,oat_vdex_size,oat_vdex_mtime,profile_size,profile_mtime
# 平台说明:
#   dumpsys package <pkg> 的 dexopt 输出格式因 Android 版本而异。
#   以下解析基于 Android 12 (API31)。若你的设备输出格式不同，请修改解析逻辑。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_common.sh"

parse_phase_args "$@"
require_phase
PHASE="$PARSED_PHASE"
SUFFIX="${PARSED_SUFFIX:-before}"

SERIAL=$(get_device_serial) || exit 1
[ -f "$APP_LIST_FILE" ] || { log_err "App list missing: $APP_LIST_FILE"; exit 1; }

OUT_DIR="$(phase_dir "$PHASE")"
ensure_dir "$OUT_DIR"
OUT="$OUT_DIR/dexopt_${SUFFIX}.csv"

RAW_DIR="$OUT_DIR/dexopt_${SUFFIX}_raw"
ensure_dir "$RAW_DIR"

log_info "==== 02_dump_dexopt_state.sh phase=$PHASE suffix=$SUFFIX ===="

{
    echo 'pkg,installed,isa,filter,reason,base_apk_path,oat_odex_size,oat_odex_mtime,oat_vdex_size,oat_vdex_mtime,profile_size,profile_mtime'
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        pkg="${line%%/*}"

        raw_out="$RAW_DIR/${pkg}.txt"
        adb shell "dumpsys package $pkg" </dev/null > "$raw_out" 2>/dev/null || {
            echo "\"$pkg\",no,,,,,,,,,,"
            continue
        }

        info=$(cat "$raw_out")

        # 解析 compiler filter/status。
        # Android12 常见: [compiler filter: verify]
        # Android14 常见: arm64: [status=verify] [reason=prebuilt]
        filter=$(echo "$info" | grep -m1 '\[.*compiler filter:' | sed -n 's/.*compiler filter: \([^]]*\)\].*/\1/p' | tr -d '[:space:]' || true)
        [ -z "$filter" ] && filter=$(echo "$info" | grep -m1 'compilerFilter=' | sed -n 's/.*compilerFilter=\([^[:space:]]*\).*/\1/p' || true)
        [ -z "$filter" ] && filter=$(echo "$info" | grep -m1 '\[status=' | sed -n 's/.*\[status=\([^]]*\)\].*/\1/p' || true)

        # 解析 reason
        reason=$(echo "$info" | grep -m1 'reason:' | sed -n 's/.*reason: \([^[:space:]]*\).*/\1/p' || true)
        [ -z "$reason" ] && reason=$(echo "$info" | grep -m1 '\[reason=' | sed -n 's/.*\[reason=\([^]]*\)\].*/\1/p' || true)

        # 解析 base apk 路径
        base_apk=$(echo "$info" | grep -m1 '^[[:space:]]*path: ' | sed -n 's/^[[:space:]]*path: //p' || true)
        [ -z "$base_apk" ] && base_apk=$(echo "$info" | grep -m1 'baseDir=' | sed -n 's/.*baseDir=\([^[:space:]]*\).*/\1/p' || true)
        [ -z "$base_apk" ] && base_apk=$(echo "$info" | grep -m1 'codePath=' | sed -n 's/.*codePath=\([^[:space:]]*\).*/\1/p' || true)

        # isa (通常为 arm64)
        isa=$(echo "$info" | grep -m1 ': \[status=' | sed -n 's/^[[:space:]]*\([^:]*\):.*/\1/p' || true)
        [ -z "$isa" ] && isa=$(echo "$info" | grep -m1 'primaryCpuAbi=' | sed -n 's/.*primaryCpuAbi=\([^[:space:]]*\).*/\1/p' || true)

        # odex/vdex 信息 (从 dexopt 指令行中提取)
        odex_size=""
        odex_mtime=""
        vdex_size=""
        vdex_mtime=""
        profile_size=""
        profile_mtime=""

        # 尝试从 oat dir 信息解析
        oat_line=$(echo "$info" | grep -m1 'oatDir=' || true)
        if [ -n "$oat_line" ]; then
            oat_dir=$(echo "$oat_line" | sed -n 's/.*oatDir=\([^[:space:]]*\).*/\1/p')
            if [ -n "$oat_dir" ]; then
                # 尝试 ls -l 获取文件信息
                oat_info=$(adb shell "ls -l ${oat_dir}/${isa:-arm64}/" </dev/null 2>/dev/null || true)
                odex_size=$(echo "$oat_info" | grep '\.odex' | awk 'NR==1 {print $5}' || true)
                odex_mtime=$(echo "$oat_info" | grep '\.odex' | awk 'NR==1 {print $6" "$7}' || true)
                vdex_size=$(echo "$oat_info" | grep '\.vdex' | awk 'NR==1 {print $5}' || true)
                vdex_mtime=$(echo "$oat_info" | grep '\.vdex' | awk 'NR==1 {print $6" "$7}' || true)
            fi
        fi

        # Android14 dumpsys may give the concrete artifact path as:
        #   [location is /system/app/foo/oat/arm64/foo.odex]
        odex_path=$(echo "$info" | grep -m1 '\[location is .*\.odex\]' | sed -n 's/.*\[location is \([^]]*\.odex\)\].*/\1/p' || true)
        if [ -n "$odex_path" ] && [ -z "$odex_size" ]; then
            odex_info=$(adb shell "ls -l $odex_path ${odex_path%.odex}.vdex 2>/dev/null" </dev/null || true)
            odex_size=$(echo "$odex_info" | grep '\.odex' | awk 'NR==1 {print $5}' || true)
            odex_mtime=$(echo "$odex_info" | grep '\.odex' | awk 'NR==1 {print $6" "$7}' || true)
            vdex_size=$(echo "$odex_info" | grep '\.vdex' | awk 'NR==1 {print $5}' || true)
            vdex_mtime=$(echo "$odex_info" | grep '\.vdex' | awk 'NR==1 {print $6" "$7}' || true)
        fi

        # profile 信息
        prof_dir=$(adb shell "ls -d /data/misc/profiles/ref/$pkg 2>/dev/null" </dev/null || true)
        if [ -n "$prof_dir" ]; then
            prof_info=$(adb shell "ls -l /data/misc/profiles/ref/$pkg/ 2>/dev/null" </dev/null || true)
            profile_size=$(echo "$prof_info" | grep '\.prof' | awk 'NR==1 {print $5}' || true)
            profile_mtime=$(echo "$prof_info" | grep '\.prof' | awk 'NR==1 {print $6" "$7}' || true)
        fi

        printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
            "$pkg" "yes" "${isa:-}" "${filter:-}" "${reason:-}" "${base_apk:-}" \
            "${odex_size:-}" "${odex_mtime:-}" "${vdex_size:-}" "${vdex_mtime:-}" \
            "${profile_size:-}" "${profile_mtime:-}"
    done < "$APP_LIST_FILE"
} > "$OUT"

log_ok "dexopt state → $OUT ($(grep -cEv '^[[:space:]]*$|^pkg' "$OUT") entries)"
log_info "Raw dumpsys output → $RAW_DIR/"
