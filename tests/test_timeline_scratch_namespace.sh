#!/bin/bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
source "$PROJECT_ROOT/scripts/lib_common.sh"

phase="T0_AcceptanceFull"

EVIDENCE_RUN_TAG="0728-parallel"
EVIDENCE_DEVICE_TAG="serial-a"
key_a="$(host_scratch_key "$phase")"

EVIDENCE_DEVICE_TAG="serial-b"
key_b="$(host_scratch_key "$phase")"

[ "$key_a" = "0728-parallel__serial-a__T0_AcceptanceFull" ]
[ "$key_b" = "0728-parallel__serial-b__T0_AcceptanceFull" ]
[ "$key_a" != "$key_b" ]

EVIDENCE_RUN_TAG="0728 parallel/retry"
EVIDENCE_DEVICE_TAG="serial/a"
[ "$(host_scratch_key "$phase")" = "0728_parallel_retry__serial_a__T0_AcceptanceFull" ]

echo "timeline scratch namespace: pass"
