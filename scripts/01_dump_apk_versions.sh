#!/bin/bash
# 01_dump_apk_versions.sh — 采集 App APK 版本快照
#
# 用法:
#   bash scripts/01_dump_apk_versions.sh --phase <PHASE> --suffix <before|after>
#
# 产出: evidence/<run-tag>/<device>_<PHASE>/apk_versions_<suffix>.csv
# 字段: pkg,installed,versionCode,versionName,firstInstallTime,lastUpdateTime,codePath,primaryCpuAbi
# 平台说明: dumpsys package 格式在 Android 各版本基本一致，若解析失败请反馈。

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
OUT="$OUT_DIR/apk_versions_${SUFFIX}.csv"

log_info "==== 01_dump_apk_versions.sh phase=$PHASE suffix=$SUFFIX ===="

{
    echo 'pkg,installed,versionCode,versionName,firstInstallTime,lastUpdateTime,codePath,primaryCpuAbi'
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        pkg="${line%%/*}"

        info=$(adb shell "dumpsys package $pkg" </dev/null 2>/dev/null) || {
            echo "\"$pkg\",no,,,,,,,"
            continue
        }

        installed="yes"
        versionCode=$(echo "$info" | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | sed -n '1p' || true)
        versionName=$(echo "$info" | sed -n 's/.*versionName=\([^[:space:]]*\).*/\1/p' | sed -n '1p' || true)
        firstInstallTime=$(echo "$info" | sed -n 's/.*firstInstallTime=\([^[:space:]]*\).*/\1/p' | sed -n '1p' || true)
        lastUpdateTime=$(echo "$info" | sed -n 's/.*lastUpdateTime=\([^[:space:]]*\).*/\1/p' | sed -n '1p' || true)
        codePath=$(echo "$info" | sed -n 's/.*codePath=\([^[:space:]]*\).*/\1/p' | sed -n '1p' || true)
        primaryCpuAbi=$(echo "$info" | sed -n 's/.*primaryCpuAbi=\([^[:space:]]*\).*/\1/p' | sed -n '1p' || true)

        printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
            "$pkg" "$installed" "${versionCode:-}" "${versionName:-}" \
            "${firstInstallTime:-}" "${lastUpdateTime:-}" "${codePath:-}" "${primaryCpuAbi:-}"
    done < "$APP_LIST_FILE"
} > "$OUT"

log_ok "APK versions → $OUT ($(grep -cEv '^[[:space:]]*$|^pkg' "$OUT") entries)"
