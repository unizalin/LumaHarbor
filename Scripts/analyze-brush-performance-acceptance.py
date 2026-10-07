#!/usr/bin/env python3

import argparse
import json
import math
from pathlib import Path
import re


SYNTHETIC_FIELDS = {
    "schemaVersion", "scenario", "variant", "maskCount", "width", "height",
    "strokeCountPerMask", "pointCountPerStroke", "sampleCount",
    "coverageDurationsSeconds", "durationsSeconds", "stageDurationsSeconds",
    "stageIsolation", "preferMetal", "seed",
}
CANCELLATION_FIELDS = {
    "schemaVersion", "scenario", "variant", "sampleCount", "durationsSeconds",
    "p95Seconds", "workerCounts", "cancelOutcome", "timingBoundary",
    "nonPreemptibleSectionsExcluded", "result",
}
MEMORY_FIELDS = {
    "schemaVersion", "scenario", "variant", "warmupCycles", "measuredCycles",
    "warmPlateauRSSBytes", "settledRSSBytes", "rssLimitBytes", "workerCounts",
    "schedulerCounts", "mappingChecks", "histogramChecks", "cancelOutcome", "result",
}
SCENARIO_FIELDS = {
    "synthetic-1600px": SYNTHETIC_FIELDS,
    "preview-cancel": CANCELLATION_FIELDS,
    "export-cancel-24mp": CANCELLATION_FIELDS,
    "50-cancel-switch-preview": MEMORY_FIELDS,
}
CANCELLATION_TIMING_BOUNDARY = "coverage barrier release through parent and worker join"


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def nearest_rank_p95(samples: list[float]) -> float:
    if not samples:
        fail("duration sample list is empty")
    ordered = sorted(samples)
    return ordered[max(math.ceil(0.95 * len(ordered)) - 1, 0)]


def parse_records(path: Path) -> list[dict]:
    records: list[dict] = []
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8", errors="strict").splitlines(),
        start=1,
    ):
        candidate = line.strip()
        if not candidate.startswith("{"):
            continue
        try:
            value = json.loads(candidate)
        except json.JSONDecodeError as error:
            fail(f"line {line_number}: invalid JSON record: {error.msg}")
        if not isinstance(value, dict):
            fail(f"line {line_number}: JSON record must be an object")
        scenario = value.get("scenario")
        if scenario not in SCENARIO_FIELDS:
            fail(f"line {line_number}: unsupported scenario {scenario!r}")
        required = SCENARIO_FIELDS[scenario]
        missing = sorted(required - value.keys())
        if missing:
            fail(f"{scenario} missing {','.join(missing)}")
        unexpected = sorted(value.keys() - required)
        if unexpected:
            fail(f"{scenario} unexpected {','.join(unexpected)}")
        records.append(value)
    return records


def require_number_list(record: dict, key: str, expected_count: int) -> list[float]:
    value = record.get(key)
    if not isinstance(value, list) or len(value) != expected_count:
        fail(f"{record.get('scenario')} {key} must contain {expected_count} samples")
    if any(
        isinstance(item, bool)
        or not isinstance(item, (int, float))
        or not math.isfinite(float(item))
        or item < 0
        for item in value
    ):
        fail(f"{record.get('scenario')} {key} contains an invalid duration")
    return [float(item) for item in value]


def require_exact_keys(value: object, expected: set[str], context: str) -> dict:
    if not isinstance(value, dict):
        fail(f"{context} must be an object")
    missing = sorted(expected - value.keys())
    unexpected = sorted(value.keys() - expected)
    if missing:
        fail(f"{context} missing {','.join(missing)}")
    if unexpected:
        fail(f"{context} unexpected {','.join(unexpected)}")
    return value


def require_nonnegative_integer(value: object, context: str, *, positive: bool = False) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < (1 if positive else 0):
        fail(f"{context} must be a {'positive' if positive else 'nonnegative'} integer")
    return value


def require_balanced_workers(record: dict) -> dict:
    scenario = record["scenario"]
    counts = require_exact_keys(
        record["workerCounts"],
        {"started", "finished", "activeAfterJoin"},
        f"{scenario} workerCounts",
    )
    started = require_nonnegative_integer(counts["started"], f"{scenario} workers started", positive=True)
    finished = require_nonnegative_integer(counts["finished"], f"{scenario} workers finished")
    active = require_nonnegative_integer(counts["activeAfterJoin"], f"{scenario} activeAfterJoin")
    if started != finished or active != 0:
        fail(f"{scenario} workers must be balanced and inactive after join")
    return counts


def require_commit_sha(value: str, name: str) -> None:
    if re.fullmatch(r"[0-9a-f]{40}", value) is None:
        fail(f"{name} must be a 40-character lowercase hex commit")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--product-sha", required=True)
    parser.add_argument("--harness-sha", required=True)
    parser.add_argument("--expected-samples", type=int, default=8)
    args = parser.parse_args()

    require_commit_sha(args.product_sha, "product-sha")
    require_commit_sha(args.harness_sha, "harness-sha")
    if args.expected_samples < 1:
        fail("expected-samples must be a positive integer")

    records = parse_records(args.input)
    if len(records) != 6:
        fail(f"expected exactly 6 records, found {len(records)}")
    by_scenario: dict[str, list[dict]] = {}
    for record in records:
        if record.get("schemaVersion") != 3:
            fail(f"unsupported record schemaVersion for {record.get('scenario')}")
        if record.get("variant") != "O":
            fail(f"{record.get('scenario')} variant must be O")
        by_scenario.setdefault(record["scenario"], []).append(record)

    synthetic = by_scenario.get("synthetic-1600px", [])
    if any(
        not isinstance(record.get("maskCount"), int)
        or isinstance(record.get("maskCount"), bool)
        for record in synthetic
    ) or sorted(record["maskCount"] for record in synthetic) != [0, 1, 10]:
        fail("synthetic-1600px must contain exactly mask counts 0, 1, and 10")
    for record in synthetic:
        if record.get("sampleCount") != args.expected_samples:
            fail("synthetic-1600px sampleCount does not match expected samples")
        if record.get("width") != 1600 or record.get("height") != 1067:
            fail("synthetic-1600px dimensions must be 1600x1067")
        if record.get("strokeCountPerMask") != 10 or record.get("pointCountPerStroke") != 100:
            fail("synthetic-1600px workload geometry is inconsistent")
        if not isinstance(record.get("preferMetal"), bool):
            fail("synthetic-1600px preferMetal must be boolean")
        if record.get("seed") != "LH-BRUSH-PERF-ACCEPTANCE-20261006":
            fail("synthetic-1600px seed is inconsistent")
        coverage = require_number_list(record, "coverageDurationsSeconds", args.expected_samples)
        durations = require_number_list(record, "durationsSeconds", args.expected_samples)
        stages = require_exact_keys(
            record["stageDurationsSeconds"],
            {
                "validationSampling", "coverageRaster", "coverageIncludingSampling",
                "blendMaterialization", "totalMaterialized",
            },
            "synthetic-1600px stageDurationsSeconds",
        )
        if stages["validationSampling"] is not None \
                or stages["coverageRaster"] is not None \
                or stages["blendMaterialization"] is not None:
            fail("unisolated synthetic stages must remain null")
        if stages["coverageIncludingSampling"] != coverage or stages["totalMaterialized"] != durations:
            fail("synthetic stage diagnostic arrays must match the source samples")
        isolation = require_exact_keys(
            record["stageIsolation"], {"result", "reason"}, "synthetic-1600px stageIsolation"
        )
        if isolation["result"] != "NOT RUN" or not isinstance(isolation["reason"], str) \
                or not isolation["reason"]:
            fail("stage isolation must remain NOT RUN without isolated B/O boundaries")

    cancellation_records = []
    cancellation_pass = True
    for scenario in ("preview-cancel", "export-cancel-24mp"):
        matches = by_scenario.get(scenario, [])
        if len(matches) != 1:
            fail(f"expected exactly one {scenario} record")
        record = matches[0]
        if record.get("sampleCount") != args.expected_samples:
            fail(f"{scenario} sampleCount does not match expected samples")
        samples = require_number_list(record, "durationsSeconds", args.expected_samples)
        p95 = nearest_rank_p95(samples)
        recorded_p95 = record.get("p95Seconds")
        if isinstance(recorded_p95, bool) \
                or not isinstance(recorded_p95, (int, float)) \
                or not math.isfinite(float(recorded_p95)) \
                or abs(p95 - float(recorded_p95)) > 1e-12:
            fail(f"{scenario} p95 does not recompute from samples")
        require_balanced_workers(record)
        if record["timingBoundary"] != CANCELLATION_TIMING_BOUNDARY:
            fail(
                f"{scenario} unexpected timingBoundary; expected "
                f"{CANCELLATION_TIMING_BOUNDARY!r}"
            )
        if record["nonPreemptibleSectionsExcluded"] != ["raw-decode", "cgimage-destination-encode"]:
            fail(f"{scenario} nonPreemptibleSectionsExcluded is inconsistent")
        computed_result = "PASS" if p95 <= 0.1 else "FAIL"
        if record["result"] != computed_result:
            fail(f"{scenario} result does not match recomputed p95")
        cancellation_pass = cancellation_pass and computed_result == "PASS" \
            and record["cancelOutcome"] == "cancelled-and-joined"
        cancellation_records.append({"scenario": scenario, "p95Seconds": p95})

    memory_matches = by_scenario.get("50-cancel-switch-preview", [])
    if len(memory_matches) != 1:
        fail("expected exactly one 50-cancel-switch-preview record")
    memory = memory_matches[0]
    counts = require_balanced_workers(memory)
    scheduler_counts = require_exact_keys(
        memory["schedulerCounts"], {"deliveredB", "discardedA", "failed"},
        "50-cancel-switch-preview schedulerCounts",
    )
    delivered_b = require_nonnegative_integer(
        scheduler_counts["deliveredB"], "50-cancel-switch-preview deliveredB"
    )
    discarded_a = require_nonnegative_integer(
        scheduler_counts["discardedA"], "50-cancel-switch-preview discardedA"
    )
    failed = require_nonnegative_integer(
        scheduler_counts["failed"], "50-cancel-switch-preview failed"
    )
    warmup_cycles = require_nonnegative_integer(
        memory["warmupCycles"], "50-cancel-switch-preview warmupCycles"
    )
    measured_cycles = require_nonnegative_integer(
        memory["measuredCycles"], "50-cancel-switch-preview measuredCycles", positive=True
    )
    expected_cycles = warmup_cycles + measured_cycles
    plateau = require_nonnegative_integer(
        memory["warmPlateauRSSBytes"], "50-cancel-switch-preview warmPlateauRSSBytes", positive=True
    )
    settled = require_nonnegative_integer(
        memory["settledRSSBytes"], "50-cancel-switch-preview settledRSSBytes", positive=True
    )
    rss_limit = require_nonnegative_integer(
        memory["rssLimitBytes"], "50-cancel-switch-preview rssLimitBytes", positive=True
    )
    if rss_limit != plateau + 32 * 1024 * 1024:
        fail("50-cancel-switch-preview rssLimitBytes must equal warm plateau +32 MiB")
    mapping_checks = require_nonnegative_integer(
        memory["mappingChecks"], "50-cancel-switch-preview mappingChecks"
    )
    histogram_checks = require_nonnegative_integer(
        memory["histogramChecks"], "50-cancel-switch-preview histogramChecks"
    )
    memory_pass = (
        warmup_cycles == 5
        and measured_cycles == 50
        and mapping_checks == expected_cycles
        and histogram_checks == expected_cycles
        and delivered_b == expected_cycles
        and discarded_a == expected_cycles
        and failed == 0
        and settled <= rss_limit
        and memory["cancelOutcome"] == "all-cancelled-and-joined"
    )
    if memory["result"] != ("PASS" if memory_pass else "FAIL"):
        fail("50-cancel-switch-preview result does not match recomputed lifecycle gate")

    gates = [
        {
            "gate": "PERF-COVERAGE",
            "result": "NOT RUN",
            "reason": "B/O production code has no non-overlapping validation, sampling, raster, blend/materialization wall-time boundaries; coverageIncludingSampling is diagnostic only",
        },
        {
            "gate": "PERF-CANCEL",
            "result": "PASS" if cancellation_pass else "FAIL",
            "budgetP95Seconds": 0.1,
            "measurements": cancellation_records,
        },
        {
            "gate": "PERF-MEM-50-CANCEL",
            "result": "PASS" if memory_pass else "FAIL",
            "warmPlateauRSSBytes": memory.get("warmPlateauRSSBytes"),
            "settledRSSBytes": memory.get("settledRSSBytes"),
            "rssLimitBytes": memory.get("rssLimitBytes"),
        },
    ]
    result = "FAIL" if any(gate["result"] == "FAIL" for gate in gates) else "DONE_WITH_CONCERNS"
    artifact = {
        "schemaVersion": 1,
        "productSHA": args.product_sha,
        "harnessSHA": args.harness_sha,
        "configuration": "release",
        "sampleCount": args.expected_samples,
        "records": [{key: record[key] for key in sorted(record)} for record in records],
        "gates": gates,
        "result": result,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {args.output}")
    print(f"result: {result}")


if __name__ == "__main__":
    main()
