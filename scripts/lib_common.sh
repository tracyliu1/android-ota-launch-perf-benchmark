#!/bin/bash
# lib_common.sh — 公共函数库 + 归档子命令
#
# 双重用法：
#   1) 作为库被其他脚本 source：source "$(dirname "$0")/lib_common.sh"
#   2) 作为命令行工具直接执行：
#        bash scripts/lib_common.sh archive <phase> [--skip-timeline] [--skip-logcat]
#        bash scripts/lib_common.sh split-continuous <continuous-tag> --into <p_a> <p_b> [--keep-original]
#
# 平台说明：
#   以下命令基于 Android 12 + MTK 平台验证。
#   若你的设备 prop/命令不同，请修改 config.sh 中的 EXTRA_PROPS 或脚本中的对应命令。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载用户配置（如果存在）
if [ -f "$SCRIPT_DIR/config.sh" ]; then
    source "$SCRIPT_DIR/config.sh"
else
    source "$SCRIPT_DIR/config.template.sh"
fi

INVESTIGATION_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVIDENCE_DIR="$INVESTIGATION_ROOT/evidence"
REPORTS_DIR="$INVESTIGATION_ROOT/reports"
NOTES_DIR="$INVESTIGATION_ROOT/notes"

# 默认按日期把证据归档到 evidence/MMDD/，同一天多轮可手动覆盖：
#   EVIDENCE_RUN_TAG=0617_run2 bash scripts/06_run_phase_with_timeline.sh ...
EVIDENCE_RUN_TAG="${EVIDENCE_RUN_TAG:-$(date '+%m%d')}"
export EVIDENCE_RUN_TAG

EVIDENCE_DEVICE_TAG="${EVIDENCE_DEVICE_TAG:-}"
export EVIDENCE_DEVICE_TAG

# ---------- 日志 ----------
log_info() { echo "[INFO $(date '+%H:%M:%S')] $*" >&2; }
log_warn() { echo "[WARN $(date '+%H:%M:%S')] $*" >&2; }
log_err()  { echo "[ERR  $(date '+%H:%M:%S')] $*" >&2; }
log_ok()   { echo "[OK   $(date '+%H:%M:%S')] $*" >&2; }

ts() { date '+%Y%m%d_%H%M%S'; }
ts_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }
ts_epoch() { date '+%s'; }

ensure_dir() { [ -d "$1" ] || mkdir -p "$1"; }

# ---------- 参数解析 ----------
parse_phase_args() {
    PARSED_PHASE=""
    PARSED_SUFFIX=""
    REMAINING_ARGS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --phase)  PARSED_PHASE="$2";  shift 2 ;;
            --suffix) PARSED_SUFFIX="$2"; shift 2 ;;
            *) REMAINING_ARGS+=("$1");    shift ;;
        esac
    done
}

require_phase() {
    if [ -z "${PARSED_PHASE:-}" ]; then
        log_err "Missing --phase argument"
        exit 2
    fi
    validate_phase "$PARSED_PHASE"
}

evidence_run_dir() {
    echo "$EVIDENCE_DIR/$EVIDENCE_RUN_TAG"
}

sanitize_tag() {
    local tag="$1"
    tag="$(printf '%s' "$tag" | tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_*//;s/_*$//')"
    [ -n "$tag" ] || tag="Device"
    printf '%s\n' "$tag"
}

detect_device_tag() {
    local serial=""
    local prop=""
    serial=$(get_device_serial 2>/dev/null || true)
    if [ -n "$serial" ]; then
        for key in ro.product.model ro.product.vendor.device ro.product.system.device ro.product.device ro.product.name; do
            prop=$(adb -s "$serial" shell getprop "$key" 2>/dev/null | tr -d '\r' | sed -n '1p')
            if [ -n "$prop" ]; then
                sanitize_tag "$prop"
                return 0
            fi
        done
        sanitize_tag "$serial"
        return 0
    fi
    sanitize_tag "Device"
}

device_tag() {
    if [ -n "${EVIDENCE_DEVICE_TAG:-}" ]; then
        sanitize_tag "$EVIDENCE_DEVICE_TAG"
    else
        detect_device_tag
    fi
}

phase_test_tag() {
    local phase="$1"
    if [[ "$phase" =~ _T[0-9] ]]; then
        printf 'T%s\n' "${phase#*_T}"
    else
        printf '%s\n' "$phase"
    fi
}

validate_phase() {
    local phase="$1"
    local test_tag
    test_tag="$(phase_test_tag "$phase")"
    if [[ "$test_tag" =~ ^P[0-9] ]]; then
        log_err "Old P* phase name is not allowed anymore: $phase"
        log_info "Use T* instead, for example: --phase T0"
        exit 2
    fi
    if ! [[ "$test_tag" =~ ^T[0-9][A-Za-z0-9._-]*$ ]]; then
        log_err "Invalid phase name: $phase"
        log_info "Use T* phase names, for example: T0, T1_OTA, T2_Steady"
        exit 2
    fi
}

phase_tag() {
    local phase="$1"
    local dev
    local test_tag
    dev="$(device_tag)"
    test_tag="$(phase_test_tag "$phase")"
    echo "${dev}_${test_tag}"
}

phase_dir() {
    echo "$(evidence_run_dir)/$(phase_tag "$1")"
}

# Host-side runtime files must be isolated as strictly as evidence directories.
# In particular, concurrent devices may intentionally use the same phase name.
host_scratch_key() {
    local phase="$1"
    local run_tag
    local target

    run_tag="$(sanitize_tag "$EVIDENCE_RUN_TAG")"
    if [ -n "${EVIDENCE_DEVICE_TAG:-}" ]; then
        target="$(sanitize_tag "$EVIDENCE_DEVICE_TAG")"
    elif [ -n "${ANDROID_SERIAL:-${DEVICE_SERIAL:-}}" ]; then
        target="$(sanitize_tag "${ANDROID_SERIAL:-${DEVICE_SERIAL:-}}")"
    else
        target="$(device_tag)"
    fi

    printf '%s__%s__%s\n' "$run_tag" "$target" "$(sanitize_tag "$phase")"
}

# ---------- 设备相关 ----------
get_device_serial() {
    local target_serial="${ANDROID_SERIAL:-${DEVICE_SERIAL:-}}"
    if [ -n "$target_serial" ]; then
        local hit
        hit=$(adb devices | awk -v s="$target_serial" 'NR>1 && $1==s && $2=="device" {print $1}')
        if [ -z "$hit" ]; then
            log_err "Configured device serial=$target_serial, but not connected/authorized:"
            adb devices >&2
            return 1
        fi
        echo "$hit"
        return 0
    fi
    local count
    count=$(adb devices | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')
    if [ "$count" -eq 0 ]; then
        log_err "No device connected (adb devices)"
        return 1
    elif [ "$count" -gt 1 ]; then
        log_err "Multiple devices connected ($count). Set ANDROID_SERIAL to disambiguate:"
        adb devices >&2
        log_info "Hint: export ANDROID_SERIAL=<serial>"
        return 1
    fi
    adb devices | awk 'NR>1 && $2=="device" {print $1}'
}

check_device_disk_space() {
    local min_kb=$((2 * 1024 * 1024))
    local avail
    avail=$(adb shell df -k /data/local/tmp 2>/dev/null \
            | awk 'NR>=2 && $4 ~ /^[0-9]+$/ {print $4; exit}')
    if [ -z "$avail" ]; then
        log_warn "Cannot parse df /data/local/tmp output, skipping disk check"
        return 0
    fi
    if [ "$avail" -lt "$min_kb" ]; then
        log_err "Device /data/local/tmp avail ${avail} KB < required ${min_kb} KB (2 GB)"
        return 1
    fi
    log_ok "Device /data/local/tmp avail: ${avail} KB"
    return 0
}

# 把设备身份信息 dump 到 evidence/<run-tag>/env/<device>_<phase>.txt
# [MTK/Android12] 以下 prop 列表基于 MTK Android12，请根据你的设备增减
dump_device_id() {
    local phase="$1"
    local phase_label
    phase_label="$(phase_tag "$phase")"
    local out="$(evidence_run_dir)/env/${phase_label}.txt"
    ensure_dir "$(dirname "$out")"
    {
        echo "# Device identity for phase: $phase"
        echo "# Evidence phase tag: $phase_label"
        echo "# Captured at: $(ts_iso)"
        echo ""
        echo "## adb devices"
        adb devices
        echo ""
        echo "## Build / model props"
        for prop in \
                ro.serialno ro.product.model ro.product.brand ro.product.device \
                ro.product.cpu.abi ro.product.cpu.abilist \
                ro.build.version.release ro.build.version.sdk \
                ro.build.fingerprint ro.build.id ro.build.date \
                ro.build.type ro.build.tags \
                ro.boot.slot_suffix ro.boot.dynamic_partitions \
                ro.virtual_ab.enabled ro.virtual_ab.compression.enabled \
                ro.boot.hardware.platform ro.hardware ${EXTRA_PROPS[@]+"${EXTRA_PROPS[@]}"}; do
            local val
            val=$(adb shell getprop "$prop" 2>/dev/null | tr -d '\r')
            printf '%s = %s\n' "$prop" "$val"
        done
        echo ""
        echo "## Storage"
        adb shell df -h /data /data/local/tmp 2>/dev/null
        echo ""
        echo "## Uptime"
        adb shell uptime 2>/dev/null
        adb shell cat /proc/uptime 2>/dev/null
        echo ""
        echo "## Boot state"
        for prop in sys.boot_completed init.svc.boot_anim init.svc.update_engine; do
            local val
            val=$(adb shell getprop "$prop" 2>/dev/null | tr -d '\r')
            printf '%s = %s\n' "$prop" "$val"
        done
    } > "$out"
    log_ok "Device ID → $out"
}

write_launch_window() {
    local phase="$1" started="$2" ended="$3"
    local out
    out="$(phase_dir "$phase")/launch_window.txt"
    ensure_dir "$(dirname "$out")"
    {
        echo "phase=$phase"
        echo "phase_tag=$(phase_tag "$phase")"
        echo "started_at=$started"
        echo "ended_at=$ended"
        echo "started_iso=$(date -r "$started" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || true)"
        echo "ended_iso=$(date -r "$ended" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || true)"
    } > "$out"
    log_info "Launch window for $phase → $out"
}

# ---------- 子命令：archive ----------
cmd_archive() {
    local phase=""
    local skip_timeline=false
    local skip_logcat=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --skip-timeline) skip_timeline=true; shift ;;
            --skip-logcat)   skip_logcat=true;   shift ;;
            -*) log_err "Unknown archive flag: $1"; exit 2 ;;
            *)
                if [ -z "$phase" ]; then phase="$1"; shift
                else log_err "Unexpected positional arg: $1"; exit 2; fi
                ;;
        esac
    done
    [ -n "$phase" ] || { log_err "archive requires <phase>"; exit 2; }
    validate_phase "$phase"

    local d
    d="$(phase_dir "$phase")"
    ensure_dir "$d"
    log_info "Archive check for $phase ($d)"

    local missing=0
    check_file() {
        local rel="$1" desc="$2"
        if [ ! -e "$d/$rel" ]; then
            log_warn "MISSING: $rel  ($desc)"
            missing=$((missing+1))
        else
            log_ok "present: $rel"
        fi
    }

    check_file "device_id.txt"            "device identity dump (00_env_check)"
    check_file "apk_versions_before.csv"  "apk versionCode dump (10_dump_apk_versions)"
    if [ "${CHECK_APK_SHA256:-true}" = "true" ]; then
        check_file "apk_sha256_before.csv" "APK sha256 dump (01_dump_apk_sha256)"
    fi
    check_file "dexopt_before.csv"        "dexopt state, pre-test (11_dump_dexopt_state)"
    check_file "dexopt_after.csv"         "dexopt state, post-test (11_dump_dexopt_state)"
    check_file "launch_raw"               "launch test output dir (30_run_launch_test)"

    $skip_timeline || check_file "timeline" "timeline samples (20_timeline_sampler)"
    $skip_logcat   || check_file "logcat"   "rolling logcat (21_logcat_recorder)"

    if [ ! -e "$d/device_id.txt" ] && [ -e "$(evidence_run_dir)/env/$(phase_tag "$phase").txt" ]; then
        cp "$(evidence_run_dir)/env/$(phase_tag "$phase").txt" "$d/device_id.txt"
        log_info "Copied env/$(phase_tag "$phase").txt → $(phase_tag "$phase")/device_id.txt"
        missing=$((missing - 1))
    fi

    echo ""
    if [ "$missing" -gt 0 ]; then
        log_warn "$missing required artifact(s) missing for $phase"
        return 1
    else
        log_ok "All required artifacts present for $phase"
        return 0
    fi
}

# ---------- 子命令：split-continuous ----------
cmd_split_continuous() {
    local cont=""
    local into=()
    local keep_original=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --into)
                shift
                while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
                    into+=("$1"); shift
                done
                ;;
            --keep-original) keep_original=true; shift ;;
            -*) log_err "Unknown split-continuous flag: $1"; exit 2 ;;
            *)
                if [ -z "$cont" ]; then cont="$1"; shift
                else log_err "Unexpected positional arg: $1"; exit 2; fi
                ;;
        esac
    done
    [ -n "$cont" ] || { log_err "split-continuous requires <cont-tag>"; exit 2; }
    [ ${#into[@]} -gt 0 ] || { log_err "split-continuous requires --into <p1> <p2> ..."; exit 2; }
    for p in "${into[@]}"; do
        validate_phase "$p"
    done

    local src="$(evidence_run_dir)/timeline_${cont}"
    if [ ! -d "$src" ]; then
        log_err "Continuous timeline dir not found: $src"
        log_info "Hint: 03_timeline_sampler.sh --stop 时会把采样数据保存到 $(evidence_run_dir)/timeline_<phase>/"
        exit 1
    fi
    if [ ! -f "$src/timeline.csv" ]; then
        log_err "$src/timeline.csv missing; cannot slice"
        exit 1
    fi

    for p in "${into[@]}"; do
        local win="$(phase_dir "$p")/launch_window.txt"
        if [ ! -f "$win" ]; then
            log_warn "Skipping $p — no launch_window.txt found at $win"
            continue
        fi
        local started ended
        started=$(awk -F= '/^started_at=/ {print $2}' "$win")
        ended=$(awk -F= '/^ended_at=/   {print $2}' "$win")
        if [ -z "$started" ] || [ -z "$ended" ]; then
            log_warn "Bad launch_window.txt for $p (started=$started ended=$ended), skipping"
            continue
        fi
        local dst="$(phase_dir "$p")/timeline"
        ensure_dir "$dst"

        awk -F, -v s="$started" -v e="$ended" \
            'NR==1 { print; next } ($1+0 >= s+0 && $1+0 <= e+0) { print }' \
            "$src/timeline.csv" > "$dst/timeline.csv"
        local n
        n=$(($(wc -l < "$dst/timeline.csv") - 1))
        log_ok "Sliced $n ticks → $dst/timeline.csv (window: $started → $ended)"

        if [ -d "$src/raw" ]; then
            ln -snf "$src/raw" "$dst/raw_continuous_link"
            log_info "Linked raw/ from continuous → $dst/raw_continuous_link"
        fi

        {
            echo "sliced_from=$src"
            echo "window_started_at=$started"
            echo "window_ended_at=$ended"
            echo "tick_count=$n"
            echo "sliced_at=$(ts_iso)"
        } > "$dst/slice_info.txt"
    done

    if ! $keep_original; then
        log_info "(--keep-original was not specified, but original at $src is preserved by default)"
    fi
    log_ok "split-continuous complete for $cont"
}

# ---------- dispatcher ----------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cmd="${1:-}"
    if [ -z "$cmd" ]; then
        cat >&2 <<EOF
用法:
  bash $0 archive <phase> [--skip-timeline] [--skip-logcat]
  bash $0 split-continuous <cont-tag> --into <p1> <p2> ... [--keep-original]
EOF
        exit 2
    fi
    shift
    case "$cmd" in
        archive)          cmd_archive "$@" ;;
        split-continuous) cmd_split_continuous "$@" ;;
        *)
            log_err "Unknown subcommand: $cmd"
            exit 2
            ;;
    esac
fi
