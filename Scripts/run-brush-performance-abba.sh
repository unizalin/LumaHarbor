#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASELINE_SHA="${LUMAHARBOR_BRUSH_BASELINE_SHA:-1de07dcfeb2ed217a75d1c04978da6a5936f379a}"
BLOCKS="${LUMAHARBOR_BRUSH_ABBA_BLOCKS:-4}"
MASK_COUNTS="${LUMAHARBOR_BRUSH_ABBA_MASK_COUNTS:-0 1 10}"
SCENARIOS="${LUMAHARBOR_BRUSH_ABBA_SCENARIOS:-cold warm changed appended stress}"
RUN_ROOT="${LUMAHARBOR_BRUSH_ABBA_RUN_ROOT:-$(mktemp -d "${TMPDIR:-/private/tmp}/LumaHarborBrushABBA.XXXXXX")}"
BASELINE_ROOT="${RUN_ROOT}/baseline"
BASELINE_SCRATCH="${RUN_ROOT}/baseline-build"
CANDIDATE_SCRATCH="${RUN_ROOT}/candidate-build"
ARTIFACT="${RUN_ROOT}/brush-preview-abba.jsonl"
GATE_ARTIFACT="${RUN_ROOT}/brush-preview-abba-gates.json"
HARNESS_SOURCE="${REPO_ROOT}/Tests/RawProcessingCoreTests/BrushPreviewABBAHarnessTests.swift"
TESTABILITY_PATCH="${SCRIPT_DIR}/fixtures/brush-baseline-release-testability.patch"

if [[ ! "${BLOCKS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: LUMAHARBOR_BRUSH_ABBA_BLOCKS must be a positive integer" >&2
    exit 2
fi

mkdir -p "${BASELINE_ROOT}"
git -C "${REPO_ROOT}" archive "${BASELINE_SHA}" | tar -x -C "${BASELINE_ROOT}"
patch -s -d "${BASELINE_ROOT}" -p1 < "${TESTABILITY_PATCH}"
cp "${HARNESS_SOURCE}" "${BASELINE_ROOT}/Tests/RawProcessingCoreTests/BrushPreviewABBAHarnessTests.swift"

INSTRUMENTATION_DIGEST="$({ shasum -a 256 < "${TESTABILITY_PATCH}"; shasum -a 256 < "${HARNESS_SOURCE}"; } | shasum -a 256 | awk '{print $1}')"
HARNESS_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
CANDIDATE_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD)"

# Compile both variants before timing. The opt-in test skips, but SwiftPM still
# builds the same Release test product later used with --skip-build.
swift test -c release --package-path "${BASELINE_ROOT}" --scratch-path "${BASELINE_SCRATCH}" \
    --filter BrushPreviewABBAHarnessTests
swift test -c release --package-path "${REPO_ROOT}" --scratch-path "${CANDIDATE_SCRATCH}" \
    --filter BrushPreviewABBAHarnessTests

: > "${ARTIFACT}"
B_ORDINAL=0
O_ORDINAL=0
ORDER_INDEX=0

run_sample() {
    local variant="$1"
    local round="$2"
    local mask_count="$3"
    local scenario="$4"
    local package_root scratch product_sha sample_ordinal
    if [[ "${variant}" == "B" ]]; then
        package_root="${BASELINE_ROOT}"
        scratch="${BASELINE_SCRATCH}"
        product_sha="${BASELINE_SHA}"
        sample_ordinal="${B_ORDINAL}"
        B_ORDINAL=$((B_ORDINAL + 1))
    else
        package_root="${REPO_ROOT}"
        scratch="${CANDIDATE_SCRATCH}"
        product_sha="${CANDIDATE_SHA}"
        sample_ordinal="${O_ORDINAL}"
        O_ORDINAL=$((O_ORDINAL + 1))
    fi

    local output record
    output="$(
        LUMAHARBOR_RUN_BRUSH_ABBA=1 \
        LUMAHARBOR_BRUSH_VARIANT="${variant}" \
        LUMAHARBOR_BRUSH_PRODUCT_SHA="${product_sha}" \
        LUMAHARBOR_BRUSH_HARNESS_SHA="${HARNESS_SHA}" \
        LUMAHARBOR_BRUSH_INSTRUMENTATION_DIGEST="${INSTRUMENTATION_DIGEST}" \
        LUMAHARBOR_BRUSH_ROUND="${round}" \
        LUMAHARBOR_BRUSH_ORDER="${ORDER_INDEX}" \
        LUMAHARBOR_BRUSH_SAMPLE_ORDINAL="${sample_ordinal}" \
        LUMAHARBOR_BRUSH_MASK_COUNT="${mask_count}" \
        LUMAHARBOR_BRUSH_SCENARIO="${scenario}" \
        swift test -c release --package-path "${package_root}" --scratch-path "${scratch}" \
            --skip-build --filter BrushPreviewABBAHarnessTests/testOptInProductionPreviewSample
    )"
    printf '%s\n' "${output}"
    record="$(printf '%s\n' "${output}" | awk '/^\{.*\}$/ { print; exit }')"
    if [[ -z "${record}" ]]; then
        echo "error: timed sample did not emit a JSON record" >&2
        exit 3
    fi
    printf '%s\n' "${record}" >> "${ARTIFACT}"
    ORDER_INDEX=$((ORDER_INDEX + 1))
}

for scenario in ${SCENARIOS}; do
    for mask_count in ${MASK_COUNTS}; do
        B_ORDINAL=0
        O_ORDINAL=0
        for ((block = 0; block < BLOCKS; block += 1)); do
            for variant in B O O B; do
                run_sample "${variant}" 1 "${mask_count}" "${scenario}"
            done
        done
        for ((block = 0; block < BLOCKS; block += 1)); do
            for variant in O B B O; do
                run_sample "${variant}" 2 "${mask_count}" "${scenario}"
            done
        done
    done
done

python3 "${SCRIPT_DIR}/analyze-brush-performance-abba.py" \
    --samples "${ARTIFACT}" \
    --output "${GATE_ARTIFACT}" \
    --expected-per-round "$((BLOCKS * 2))"
echo "artifact=${ARTIFACT}"
echo "gates=${GATE_ARTIFACT}"
echo "baselineRoot=${BASELINE_ROOT}"
