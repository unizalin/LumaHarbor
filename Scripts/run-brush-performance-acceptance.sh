#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRATCH_PATH="${LUMAHARBOR_BRUSH_PERF_SCRATCH_PATH:-${TMPDIR:-/private/tmp}/LumaHarborBrushPerformanceScratch}"
SAMPLES="${LUMAHARBOR_BRUSH_PERF_SAMPLES:-8}"

if [[ ! "${SAMPLES}" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: LUMAHARBOR_BRUSH_PERF_SAMPLES must be a positive integer" >&2
    exit 2
fi

mkdir -p "${SCRATCH_PATH}"
cd "${REPO_ROOT}"

LUMAHARBOR_RUN_BRUSH_PERF_ACCEPTANCE=1 \
LUMAHARBOR_BRUSH_PERF_SAMPLES="${SAMPLES}" \
LUMAHARBOR_BRUSH_PERF_PREFER_METAL="${LUMAHARBOR_BRUSH_PERF_PREFER_METAL:-1}" \
swift test -c release \
    --scratch-path "${SCRATCH_PATH}" \
    --filter 'BrushMaskPerformanceTests.testOptInWorkloadPrintsMachineReadableSamples'
