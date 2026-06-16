#!/bin/bash
# 06_run_phase_with_timeline.sh — run one launch-test phase with timeline lifecycle bound
#
# Usage:
#   bash scripts/06_run_phase_with_timeline.sh --phase <PHASE> [--skip-env] [--skip-apk] [--skip-dexopt-before] [--skip-dexopt-after] [--skip-archive] [--] [-c N] [-s SEC]
#
# Launch options after -- are passed to 05_run_launch_test.sh.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_common.sh"

PHASE=""
SKIP_ENV=false
SKIP_APK=false
SKIP_DEXOPT_BEFORE=false
SKIP_DEXOPT_AFTER=false
SKIP_ARCHIVE=false
LAUNCH_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --phase)
            PHASE="$2"
            shift 2
            ;;
        --skip-env)
            SKIP_ENV=true
            shift
            ;;
        --skip-apk)
            SKIP_APK=true
            shift
            ;;
        --skip-dexopt-before)
            SKIP_DEXOPT_BEFORE=true
            shift
            ;;
        --skip-dexopt-after)
            SKIP_DEXOPT_AFTER=true
            shift
            ;;
        --skip-archive)
            SKIP_ARCHIVE=true
            shift
            ;;
        --)
            shift
            LAUNCH_ARGS+=("$@")
            break
            ;;
        *)
            LAUNCH_ARGS+=("$1")
            shift
            ;;
    esac
done

[ -n "$PHASE" ] || { log_err "Missing --phase argument"; exit 2; }

TIMELINE_STARTED=false
cleanup() {
    local rc=$?
    if [ "$TIMELINE_STARTED" = "true" ]; then
        bash "$SCRIPT_DIR/03_timeline_sampler.sh" --phase "$PHASE" --stop || true
    fi
    if [ "$rc" -ne 0 ]; then
        log_err "Phase $PHASE failed (exit=$rc)"
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

log_info "==== 06_run_phase_with_timeline.sh phase=$PHASE ===="

if [ "$SKIP_ENV" != "true" ]; then
    bash "$SCRIPT_DIR/00_env_check.sh" --phase "$PHASE"
fi

if [ "$SKIP_APK" != "true" ]; then
    bash "$SCRIPT_DIR/01_dump_apk_versions.sh" --phase "$PHASE" --suffix before
fi

if [ "$SKIP_DEXOPT_BEFORE" != "true" ]; then
    bash "$SCRIPT_DIR/02_dump_dexopt_state.sh" --phase "$PHASE" --suffix before
fi

bash "$SCRIPT_DIR/03_timeline_sampler.sh" --phase "$PHASE" --start
TIMELINE_STARTED=true

bash "$SCRIPT_DIR/05_run_launch_test.sh" --phase "$PHASE" "${LAUNCH_ARGS[@]}"

if [ "$SKIP_DEXOPT_AFTER" != "true" ]; then
    bash "$SCRIPT_DIR/02_dump_dexopt_state.sh" --phase "$PHASE" --suffix after
fi

bash "$SCRIPT_DIR/03_timeline_sampler.sh" --phase "$PHASE" --stop
TIMELINE_STARTED=false

if [ "$SKIP_ARCHIVE" != "true" ]; then
    bash "$SCRIPT_DIR/lib_common.sh" archive "$PHASE" --skip-logcat
fi

log_ok "Phase $PHASE finished"
