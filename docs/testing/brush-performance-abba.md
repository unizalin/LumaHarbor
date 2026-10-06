# Brush performance ABBA harness

`Scripts/run-brush-performance-abba.sh` compares baseline `B` with the checked-out candidate `O` through the same production preview API. It archives `B` into a new temporary directory, applies the checked-in Release testability patch, copies the shared harness, builds both variants, and only then starts timed `--skip-build` samples. It does not modify an existing worktree.

The default run covers 0, 1, and 10 masks across cold first open, warm unchanged, parameter changed, stroke appended, and stress-vector scenarios. Each scenario and mask count uses four `B O O B` blocks in round 1 and four `O B B O` blocks in round 2. That yields eight samples per variant per round. The fixture seed, sample ordinal, exposure sequence, appended stroke, and stress geometry are defined in `BrushPreviewABBAHarnessTests.swift` and shared unchanged with `B`.

```sh
Scripts/run-brush-performance-abba.sh
```

The script prints paths to a JSONL sample artifact and a gate artifact. The sample records conform to `docs/testing/brush-performance-abba-schema.json`. Peak RSS comes from `getrusage` inside each isolated test process; compiler memory is outside that process. The analyzer validates required fields and sample counts, then evaluates synthetic empty-preview, incremental preview, and preview-memory gates. Gates absent from that artifact remain explicitly `NOT RUN`.

For a bounded harness check, override the scenario, mask set, and block count. Such a run is diagnostic and does not satisfy the full sample contract:

```sh
LUMAHARBOR_BRUSH_ABBA_BLOCKS=1 \
LUMAHARBOR_BRUSH_ABBA_SCENARIOS=warm \
LUMAHARBOR_BRUSH_ABBA_MASK_COUNTS='0 1 10' \
Scripts/run-brush-performance-abba.sh
```

`Scripts/run-brush-performance-acceptance.sh` separately runs the Release cancellation and scheduler lifecycle workload. It requires a clean worktree, writes its raw XCTest log to a local run root, then uses `Scripts/analyze-brush-performance-acceptance.py` to emit an allowlist artifact conforming to `docs/testing/brush-performance-acceptance-schema.json`:

```sh
LUMAHARBOR_BRUSH_PERF_RUN_ROOT="$TASK_ACCEPTANCE_ROOT" \
LUMAHARBOR_BRUSH_PERF_SCRATCH_PATH="$TASK_PERF_SCRATCH" \
LUMAHARBOR_BRUSH_PERF_SAMPLES=8 \
Scripts/run-brush-performance-acceptance.sh
```

The scheduler workload performs five warmups and fifty production-route A→B switches. A enters the raster barrier, B submission cancels A, the barrier is released, and the harness waits for every live scheduler task to join. It validates B's token, subject, context, brush mapping and rendered histogram, and records actual worker started/finished counts plus settled RSS.

The O-only `coverageIncludingSampling` field is diagnostic. `validationSampling`, `coverageRaster`, and `blendMaterialization` intentionally remain `null`, and `PERF-COVERAGE` remains `NOT RUN`, because B and O do not expose identical non-overlapping wall-time boundaries. Parallel worker CPU durations must never be summed and reported as wall time. A complete acceptance report must still combine these artifacts with real RAW preview, original-size export, export peak RSS, and device UI evidence.

## Untimed pixel validation

After all timed work has stopped, use the independent snapshot runner to compare
the shared workloads through the production preview route and direct R8 storage:

```sh
TASK_PARITY_PARENT=$(mktemp -d)
python3 Scripts/run-brush-output-parity.py --repo . \
  --candidate a4278c15606ed6e79d414fcf646acb37c30b223f \
  --run-root "$TASK_PARITY_PARENT/run"
```

The runner archives B/O from immutable commits. It copies the same harness to
both, applies the baseline Release testability patch, and adds a baseline-only
test wrapper that copies the existing scalar calculation verbatim and returns
its R8 bytes before CIImage construction. The production baseline function is
unchanged; the emitted observation patch records the exact addition. O uses its
existing `_testRenderCoverageBytes` helper.

It captures 18 preview outputs and 66 mask buffers: all five scenarios and
0/1/10 masks, including both exposure parities for changed. Preview output is
normalized to sRGB RGBA8 with premultiplied alpha for comparison (maximum byte
error ≤1); direct R8 requires byte identity. `parity.json` records dimensions,
error maxima and coordinates, and thresholds. Full raw buffers and compiler
logs remain local; sanitized result metadata and the observation patch can be
committed after privacy review. Run roots must not already exist.

The changed empty control stays neutral; only active-mask cases alternate global
exposure ±0.05. The contract is covered by
`testChangedScenarioKeepsEmptyControlNeutralAcrossOrdinals`.

Analyzer validation PASS and process exit 0 only establish valid input. Inspect
each gate's result: a run may contain measured FAIL gates while its overall
status remains `DONE_WITH_CONCERNS` because required workloads are still absent.
