#!/bin/bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
SAMPLER="$PROJECT_ROOT/scripts/03_timeline_sampler.sh"
RUN_TAG="timeline-namespace-test-$$"
PHASE="T0_ParallelTest"
KEY_A="${RUN_TAG}__SERIAL_A__${PHASE}"
KEY_B="${RUN_TAG}__SERIAL_B__${PHASE}"
PID_A="$PROJECT_ROOT/.timeline_sampler_${KEY_A}.pid"
PID_B="$PROJECT_ROOT/.timeline_sampler_${KEY_B}.pid"

cleanup() {
    local pid_file pid
    for pid_file in "$PID_A" "$PID_B"; do
        if [ -f "$pid_file" ]; then
            pid="$(cat "$pid_file" 2>/dev/null || true)"
            if [ -n "$pid" ]; then
                kill "$pid" 2>/dev/null || true
            fi
        fi
    done
    rm -f \
        "$PROJECT_ROOT/.timeline_sampler_${KEY_A}.pid" \
        "$PROJECT_ROOT/.timeline_sampler_${KEY_A}.log" \
        "$PROJECT_ROOT/.timeline_${KEY_A}.csv" \
        "$PROJECT_ROOT/.timeline_sampler_${KEY_B}.pid" \
        "$PROJECT_ROOT/.timeline_sampler_${KEY_B}.log" \
        "$PROJECT_ROOT/.timeline_${KEY_B}.csv"
    rm -rf "$PROJECT_ROOT/evidence/$RUN_TAG"
}
trap cleanup EXIT

run_sampler() {
    local serial="$1"
    shift
    env \
        PATH="$TEST_DIR/fixtures:$PATH" \
        ANDROID_SERIAL="$serial" \
        DEVICE_SERIAL="$serial" \
        EVIDENCE_RUN_TAG="$RUN_TAG" \
        EVIDENCE_DEVICE_TAG="$serial" \
        TIMELINE_INTERVAL_SEC=1 \
        bash "$SAMPLER" --phase "$PHASE" "$@"
}

run_sampler SERIAL_A --start
run_sampler SERIAL_B --start

pid_a="$(cat "$PID_A")"
pid_b="$(cat "$PID_B")"
[ "$pid_a" != "$pid_b" ]
kill -0 "$pid_a"
kill -0 "$pid_b"

sleep 2
run_sampler SERIAL_A --stop

[ ! -e "$PID_A" ]
kill -0 "$pid_b"
[ -s "$PROJECT_ROOT/evidence/$RUN_TAG/SERIAL_A_${PHASE}/timeline/timeline.csv" ]

run_sampler SERIAL_B --stop

[ ! -e "$PID_B" ]
[ -s "$PROJECT_ROOT/evidence/$RUN_TAG/SERIAL_B_${PHASE}/timeline/timeline.csv" ]

echo "parallel timeline lifecycle: pass"
