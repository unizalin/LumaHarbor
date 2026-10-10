#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASELINE_SHA="${LUMAHARBOR_BRUSH_BASELINE_SHA:-1de07dcfeb2ed217a75d1c04978da6a5936f379a}"
PREVIEW_SAMPLES="${LUMAHARBOR_BRUSH_RAW_PREVIEW_SAMPLES:-8}"
EXPORT_SAMPLES="${LUMAHARBOR_BRUSH_EXPORT_SAMPLES:-4}"
RAW_FIXTURE_DIR="${LUMAHARBOR_RAW_FIXTURE_DIR:-}"
HARNESS_SOURCE="${REPO_ROOT}/Tests/RawProcessingCoreTests/BrushRawExportABBAHarnessTests.swift"
TESTABILITY_PATCH="${SCRIPT_DIR}/fixtures/brush-baseline-release-testability.patch"

if [[ ! "${PREVIEW_SAMPLES}" =~ ^[1-9][0-9]*$ ]] || ((PREVIEW_SAMPLES % 2 != 0)); then
    echo "error: LUMAHARBOR_BRUSH_RAW_PREVIEW_SAMPLES must be a positive even integer" >&2
    exit 2
fi
if [[ ! "${EXPORT_SAMPLES}" =~ ^[1-9][0-9]*$ ]] || ((EXPORT_SAMPLES % 2 != 0)); then
    echo "error: LUMAHARBOR_BRUSH_EXPORT_SAMPLES must be a positive even integer" >&2
    exit 2
fi
if [[ -z "${RAW_FIXTURE_DIR}" || ! -d "${RAW_FIXTURE_DIR}" ]]; then
    echo "error: LUMAHARBOR_RAW_FIXTURE_DIR must name an available private fixture directory" >&2
    exit 2
fi

RAW_SOURCE=""
while IFS= read -r -d '' candidate; do
    RAW_SOURCE="${candidate}"
    break
done < <(find "${RAW_FIXTURE_DIR}" -maxdepth 1 -type f -iname '*.arw' -print0)
if [[ -z "${RAW_SOURCE}" ]]; then
    echo "error: private fixture directory contains no required RAW fixture" >&2
    exit 2
fi

cd "${REPO_ROOT}"
if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: RAW/export acceptance requires a clean worktree for exact SHAs" >&2
    exit 2
fi

if [[ -n "${LUMAHARBOR_BRUSH_RAW_EXPORT_RUN_ROOT:-}" ]]; then
    RUN_ROOT="${LUMAHARBOR_BRUSH_RAW_EXPORT_RUN_ROOT}"
    if [[ -e "${RUN_ROOT}" ]]; then
        echo "error: LUMAHARBOR_BRUSH_RAW_EXPORT_RUN_ROOT already exists; use a fresh run root" >&2
        exit 2
    fi
    mkdir -p "${RUN_ROOT}"
else
    RUN_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/LumaHarborBrushRawExport.XXXXXX")"
fi

BASELINE_ROOT="${RUN_ROOT}/baseline"
BASELINE_SCRATCH="${RUN_ROOT}/baseline-build"
CANDIDATE_SCRATCH="${RUN_ROOT}/candidate-build"
SAMPLES_ARTIFACT="${RUN_ROOT}/brush-raw-export-samples.jsonl"
GATES_ARTIFACT="${RUN_ROOT}/brush-raw-export-gates.json"

mkdir -p "${BASELINE_ROOT}"
git archive "${BASELINE_SHA}" | tar -x -C "${BASELINE_ROOT}"
patch -s -d "${BASELINE_ROOT}" -p1 < "${TESTABILITY_PATCH}"
cp "${HARNESS_SOURCE}" \
    "${BASELINE_ROOT}/Tests/RawProcessingCoreTests/BrushRawExportABBAHarnessTests.swift"

INSTRUMENTATION_DIGEST="$({
    shasum -a 256 < "${TESTABILITY_PATCH}"
    shasum -a 256 < "${HARNESS_SOURCE}"
} | shasum -a 256 | awk '{print $1}')"
HARNESS_SHA="$(git rev-parse HEAD)"
CANDIDATE_SHA="${HARNESS_SHA}"
SOURCE_DIGEST_BEFORE="$(shasum -a 256 "${RAW_SOURCE}" | awk '{print $1}')"

# Compile both variants before timing. The selected opt-in test skips during
# this build, but creates the exact Release test products reused below.
swift test -c release --package-path "${BASELINE_ROOT}" --scratch-path "${BASELINE_SCRATCH}" \
    --filter BrushRawExportABBAHarnessTests/testOptInProductionSample
swift test -c release --package-path "${REPO_ROOT}" --scratch-path "${CANDIDATE_SCRATCH}" \
    --filter BrushRawExportABBAHarnessTests/testOptInProductionSample

: > "${SAMPLES_ARTIFACT}"
ORDER_INDEX=0
B_ORDINAL=0
O_ORDINAL=0

run_sample() {
    local variant="$1"
    local round="$2"
    local operation="$3"
    local source_kind="$4"
    local scenario="$5"
    local mask_count="$6"
    local package_root scratch product_sha sample_ordinal output record

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

    if ! output="$(
        LUMAHARBOR_RUN_BRUSH_RAW_EXPORT_ABBA=1 \
        LUMAHARBOR_BRUSH_VARIANT="${variant}" \
        LUMAHARBOR_BRUSH_PRODUCT_SHA="${product_sha}" \
        LUMAHARBOR_BRUSH_HARNESS_SHA="${HARNESS_SHA}" \
        LUMAHARBOR_BRUSH_INSTRUMENTATION_DIGEST="${INSTRUMENTATION_DIGEST}" \
        LUMAHARBOR_BRUSH_ROUND="${round}" \
        LUMAHARBOR_BRUSH_SOURCE_KIND="${source_kind}" \
        LUMAHARBOR_BRUSH_OPERATION="${operation}" \
        LUMAHARBOR_BRUSH_SCENARIO="${scenario}" \
        LUMAHARBOR_BRUSH_ORDER="${ORDER_INDEX}" \
        LUMAHARBOR_BRUSH_SAMPLE_ORDINAL="${sample_ordinal}" \
        LUMAHARBOR_BRUSH_MASK_COUNT="${mask_count}" \
        LUMAHARBOR_BRUSH_RAW_SOURCE="${RAW_SOURCE}" \
        swift test -c release --package-path "${package_root}" --scratch-path "${scratch}" \
            --skip-build \
            --filter BrushRawExportABBAHarnessTests/testOptInProductionSample
    )"; then
        echo "error: timed ${operation} sample failed; inspect the local run root" >&2
        exit 3
    fi
    record="$(printf '%s\n' "${output}" | awk '/^\{.*\}$/ { print; exit }')"
    if [[ -z "${record}" ]]; then
        echo "error: timed sample did not emit a JSON record" >&2
        exit 3
    fi
    printf '%s\n' "${record}" >> "${SAMPLES_ARTIFACT}"
    ORDER_INDEX=$((ORDER_INDEX + 1))
}

run_abba_group() {
    local operation="$1"
    local source_kind="$2"
    local scenario="$3"
    local mask_count="$4"
    local samples_per_variant="$5"
    local blocks=$((samples_per_variant / 2))
    local block variant round pattern

    B_ORDINAL=0
    O_ORDINAL=0
    for round in 1 2; do
        if [[ "${round}" == 1 ]]; then
            pattern=(B O O B)
        else
            pattern=(O B B O)
        fi
        for ((block = 0; block < blocks; block += 1)); do
            for variant in "${pattern[@]}"; do
                run_sample "${variant}" "${round}" "${operation}" "${source_kind}" "${scenario}" "${mask_count}"
            done
        done
    done
}

for scenario in cold warm changed; do
    for mask_count in 0 1 10; do
        run_abba_group preview real-raw "${scenario}" "${mask_count}" "${PREVIEW_SAMPLES}"
    done
done

for source_kind in synthetic-24mp real-raw; do
    for mask_count in 1 10; do
        run_abba_group export "${source_kind}" full-resolution "${mask_count}" "${EXPORT_SAMPLES}"
    done
done

SOURCE_DIGEST_AFTER="$(shasum -a 256 "${RAW_SOURCE}" | awk '{print $1}')"
if [[ "${SOURCE_DIGEST_BEFORE}" != "${SOURCE_DIGEST_AFTER}" ]]; then
    echo "error: private RAW source changed during acceptance" >&2
    exit 4
fi

python3 "${SCRIPT_DIR}/analyze-brush-raw-export-acceptance.py" \
    --samples "${SAMPLES_ARTIFACT}" \
    --output "${GATES_ARTIFACT}" \
    --expected-preview-samples "${PREVIEW_SAMPLES}" \
    --expected-export-samples "${EXPORT_SAMPLES}"

if rg -n '/Users/|/Volumes/|/private/' "${SAMPLES_ARTIFACT}" "${GATES_ARTIFACT}" >/dev/null; then
    echo "error: public acceptance artifact contains a private path" >&2
    exit 5
fi

echo "samples=${SAMPLES_ARTIFACT}"
echo "gates=${GATES_ARTIFACT}"
