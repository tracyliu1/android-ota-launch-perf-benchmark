#!/bin/bash
# 00_env_check.sh — 实验前环境检查 + 设备身份归档
#
# 用法:
#   bash scripts/00_env_check.sh --phase <PHASE>
#
# 检查项:
#   1. host端：adb / python3 / openpyxl
#   2. host端：investigation 目录可写、剩余空间 >= 5 GB
#   3. 设备：仅一台连接、/data/local/tmp 剩余 >= 2 GB
#   4. App 清单文件存在、条目数正常
#   5. 把设备 fingerprint / build / VAB props 等 dump 到 evidence/<run-tag>/env/<device>_<phase>.txt
#
# 退出码: 0 全过；非 0 表示有 fail 项
# 平台说明: [MTK/Android12] 部分 prop 为 MTK 特有，请根据你的设备调整。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_common.sh"

parse_phase_args "$@"
require_phase
PHASE="$PARSED_PHASE"

log_info "==== 00_env_check.sh phase=$PHASE ===="
fail=0
inc_fail() { fail=$((fail+1)); }

# 1. adb
if ! command -v adb >/dev/null 2>&1; then
    log_err "adb not found in PATH"
    inc_fail
else
    log_ok "adb: $(adb --version | head -1)"
fi

# 2. python3
if ! command -v python3 >/dev/null 2>&1; then
    log_err "python3 not found"
    inc_fail
else
    log_ok "python3: $(python3 --version 2>&1)"
fi

# 3. openpyxl（非致命）
if python3 -c "import openpyxl" 2>/dev/null; then
    log_ok "openpyxl available (xlsx generation supported)"
else
    log_warn "openpyxl missing — launch test will output CSV only"
fi

# 4. investigation 根目录可写
if [ ! -w "$INVESTIGATION_ROOT" ]; then
    log_err "Investigation root not writable: $INVESTIGATION_ROOT"
    inc_fail
else
    log_ok "Investigation root writable: $INVESTIGATION_ROOT"
fi

# 5. host端剩余空间 >= 5 GB
host_avail_kb=$(df -k "$INVESTIGATION_ROOT" | awk 'NR==2 {print $4}')
host_min_kb=$((5 * 1024 * 1024))
if [ -z "$host_avail_kb" ] || [ "$host_avail_kb" -lt "$host_min_kb" ]; then
    log_err "Host disk avail too low at $INVESTIGATION_ROOT (got ${host_avail_kb:-?} KB, need >= ${host_min_kb} KB)"
    inc_fail
else
    log_ok "Host disk avail: ${host_avail_kb} KB (>= 5 GB)"
fi

# 6. 设备连接
SERIAL=""
if SERIAL=$(get_device_serial); then
    log_ok "Device serial: $SERIAL"
else
    inc_fail
fi

# 7. 设备 /data/local/tmp 空间
if [ -n "$SERIAL" ]; then
    if ! check_device_disk_space; then
        inc_fail
    fi
fi

# 8. App 清单
if [ ! -f "$APP_LIST_FILE" ]; then
    log_err "App list missing: $APP_LIST_FILE"
    inc_fail
else
    count=$(grep -cEv '^\s*$|^\s*#' "$APP_LIST_FILE" || true)
    log_ok "App list: $count entries ($APP_LIST_FILE)"
fi

# 9. dump device id
if [ -n "$SERIAL" ]; then
    dump_device_id "$PHASE"
    d="$(phase_dir "$PHASE")"
    ensure_dir "$d"
    cp "$(evidence_run_dir)/env/$(phase_tag "$PHASE").txt" "$d/device_id.txt"
    log_ok "Copied env/$(phase_tag "$PHASE").txt → $(phase_tag "$PHASE")/device_id.txt"
fi

echo ""
if [ "$fail" -gt 0 ]; then
    log_err "Environment check FAILED ($fail issue(s))"
    exit 1
else
    log_ok "Environment check PASSED for phase $PHASE"
fi
