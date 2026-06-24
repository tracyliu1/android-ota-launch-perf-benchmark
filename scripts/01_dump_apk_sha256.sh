#!/bin/bash
# 01_dump_apk_sha256.sh — 采集 App APK sha256 快照
#
# 用法:
#   bash scripts/01_dump_apk_sha256.sh --phase <PHASE> --suffix <before|after>
#
# 产出: evidence/<run-tag>/<device>_<PHASE>/apk_sha256_<suffix>.csv
# 字段: pkg,codePath,apk_path,sha256,status

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
OUT="$OUT_DIR/apk_sha256_${SUFFIX}.csv"
APK_VERSIONS="$OUT_DIR/apk_versions_${SUFFIX}.csv"

log_info "==== 01_dump_apk_sha256.sh phase=$PHASE suffix=$SUFFIX ===="

if [ ! -f "$APK_VERSIONS" ]; then
    log_warn "APK version snapshot missing: $APK_VERSIONS; resolving paths via pm path"
fi

csv_escape() {
    local s="${1:-}"
    s="${s//$'\r'/}"
    s="${s//$'\n'/;}"
    s="${s//\"/\"\"}"
    printf '"%s"' "$s"
}

code_path_from_versions() {
    local pkg="$1"
    [ -f "$APK_VERSIONS" ] || return 0
    awk -F, -v p="\"$pkg\"" '
        NR == 1 { next }
        $1 == p {
            gsub(/^"|"$/, "", $7)
            print $7
            exit
        }' "$APK_VERSIONS"
}

{
    echo 'pkg,codePath,apk_path,sha256,status'
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        pkg="${line%%/*}"

        code_path="$(code_path_from_versions "$pkg" || true)"
        apk_path=""
        sha=""
        status="ok"

        if [ -n "$code_path" ]; then
            base="${code_path##*/}"
            apk_path="${code_path%/}/${base}.apk"
        fi

        if [ -z "$apk_path" ]; then
            pm_path=$(adb shell "pm path $pkg" </dev/null 2>/dev/null | tr -d '\r' | sed -n 's/^package://p' | sed -n '1p' || true)
            apk_path="$pm_path"
        fi

        if [ -n "$apk_path" ]; then
            sha=$(adb shell "sha256sum '$apk_path'" </dev/null 2>/dev/null | tr -d '\r' | awk '{print $1}' || true)
        fi

        if [ -z "$sha" ]; then
            status="missing"
        fi

        csv_escape "$pkg"
        printf ','
        csv_escape "$code_path"
        printf ','
        csv_escape "$apk_path"
        printf ','
        csv_escape "$sha"
        printf ','
        csv_escape "$status"
        printf '\n'
    done < "$APP_LIST_FILE"
} > "$OUT"

log_ok "APK sha256 → $OUT ($(grep -cEv '^[[:space:]]*$|^pkg' "$OUT") entries)"
