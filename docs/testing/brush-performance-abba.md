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

`Scripts/run-brush-performance-acceptance.sh` separately records optimized coverage and true cancellation latency. A complete acceptance report must combine both artifacts with real RAW preview, original-size export, export peak RSS, the 50-cycle settled-RSS workload, and device UI evidence. A passing synthetic JSONL file alone is not an overall performance pass.
