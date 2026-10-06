#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRATCH_PATH="${LUMAHARBOR_BRUSH_PERF_SCRATCH_PATH:-${TMPDIR:-/private/tmp}/LumaHarborBrushPerformanceScratch}"
SAMPLES="${LUMAHARBOR_BRUSH_PERF_SAMPLES:-8}"
RUN_ROOT="${LUMAHARBOR_BRUSH_PERF_RUN_ROOT:-${TMPDIR:-/private/tmp}/LumaHarborBrushPerformanceAcceptance}"

if [[ ! "${SAMPLES}" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: LUMAHARBOR_BRUSH_PERF_SAMPLES must be a positive integer" >&2
    exit 2
fi

mkdir -p "${SCRATCH_PATH}"
mkdir -p "${RUN_ROOT}"
cd "${REPO_ROOT}"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: brush performance acceptance requires a clean worktree so productSHA and harnessSHA are exact" >&2
    exit 2
fi

PRODUCT_SHA="$(git rev-parse HEAD)"
RAW_LOG="${RUN_ROOT}/brush-performance-acceptance.log"
ARTIFACT="${RUN_ROOT}/brush-performance-acceptance.json"

LUMAHARBOR_RUN_BRUSH_PERF_ACCEPTANCE=1 \
LUMAHARBOR_BRUSH_PERF_SAMPLES="${SAMPLES}" \
LUMAHARBOR_BRUSH_PERF_PREFER_METAL="${LUMAHARBOR_BRUSH_PERF_PREFER_METAL:-1}" \
swift test -c release \
    --scratch-path "${SCRATCH_PATH}" \
    --filter 'BrushMaskPerformanceTests.testOptIn' | tee "${RAW_LOG}"

python3 "${SCRIPT_DIR}/analyze-brush-performance-acceptance.py" \
    --input "${RAW_LOG}" \
    --output "${ARTIFACT}" \
    --product-sha "${PRODUCT_SHA}" \
    --harness-sha "${PRODUCT_SHA}" \
    --expected-samples "${SAMPLES}"

echo "raw log: ${RAW_LOG}"
echo "artifact: ${ARTIFACT}"
