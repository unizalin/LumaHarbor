#!/usr/bin/env python3

import argparse
import json
import math
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def nearest_rank_p95(samples: list[float]) -> float:
    if not samples:
        fail("duration sample list is empty")
    ordered = sorted(samples)
    return ordered[max(math.ceil(0.95 * len(ordered)) - 1, 0)]


def parse_records(path: Path) -> list[dict]:
    records: list[dict] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        candidate = line.strip()
        if not candidate.startswith("{"):
            continue
        try:
            value = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and "scenario" in value and "schemaVersion" in value:
            records.append(value)
    return records


def require_number_list(record: dict, key: str, expected_count: int) -> list[float]:
    value = record.get(key)
    if not isinstance(value, list) or len(value) != expected_count:
        fail(f"{record.get('scenario')} {key} must contain {expected_count} samples")
    if any(not isinstance(item, (int, float)) or item < 0 for item in value):
        fail(f"{record.get('scenario')} {key} contains an invalid duration")
    return [float(item) for item in value]


def sanitized_record(record: dict) -> dict:
    allowed = {
        "schemaVersion", "scenario", "variant", "maskCount", "width", "height",
        "strokeCountPerMask", "pointCountPerStroke", "sampleCount",
        "coverageDurationsSeconds", "durationsSeconds", "stageDurationsSeconds",
        "stageIsolation", "preferMetal", "seed", "p95Seconds", "workerCounts",
        "schedulerCounts", "cancelOutcome", "timingBoundary",
        "nonPreemptibleSectionsExcluded", "warmupCycles", "measuredCycles",
        "warmPlateauRSSBytes", "settledRSSBytes", "rssLimitBytes",
        "mappingChecks", "histogramChecks", "result",
    }
    return {key: record[key] for key in sorted(allowed) if key in record}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--product-sha", required=True)
    parser.add_argument("--harness-sha", required=True)
    parser.add_argument("--expected-samples", type=int, default=8)
    args = parser.parse_args()

    records = parse_records(args.input)
    by_scenario: dict[str, list[dict]] = {}
    for record in records:
        if record.get("schemaVersion") != 3:
            fail(f"unsupported record schemaVersion for {record.get('scenario')}")
        by_scenario.setdefault(record["scenario"], []).append(record)

    synthetic = by_scenario.get("synthetic-1600px", [])
    if sorted(record.get("maskCount") for record in synthetic) != [0, 1, 10]:
        fail("synthetic-1600px must contain exactly mask counts 0, 1, and 10")
    for record in synthetic:
        require_number_list(record, "coverageDurationsSeconds", args.expected_samples)
        require_number_list(record, "durationsSeconds", args.expected_samples)
        stages = record.get("stageDurationsSeconds")
        if not isinstance(stages, dict) or stages.get("validationSampling") is not None \
                or stages.get("coverageRaster") is not None \
                or stages.get("blendMaterialization") is not None:
            fail("unisolated synthetic stages must remain null")
        if record.get("stageIsolation", {}).get("result") != "NOT RUN":
            fail("stage isolation must remain NOT RUN without isolated B/O boundaries")

    cancellation_records = []
    cancellation_pass = True
    for scenario in ("preview-cancel", "export-cancel-24mp"):
        matches = by_scenario.get(scenario, [])
        if len(matches) != 1:
            fail(f"expected exactly one {scenario} record")
        record = matches[0]
        samples = require_number_list(record, "durationsSeconds", args.expected_samples)
        p95 = nearest_rank_p95(samples)
        if abs(p95 - float(record.get("p95Seconds", -1))) > 1e-12:
            fail(f"{scenario} p95 does not recompute from samples")
        counts = record.get("workerCounts", {})
        balanced = isinstance(counts.get("started"), int) and counts.get("started", 0) > 0 \
            and counts.get("started") == counts.get("finished") and counts.get("activeAfterJoin") == 0
        cancellation_pass = cancellation_pass and p95 <= 0.1 and balanced \
            and record.get("cancelOutcome") == "cancelled-and-joined"
        cancellation_records.append({"scenario": scenario, "p95Seconds": p95})

    memory_matches = by_scenario.get("50-cancel-switch-preview", [])
    if len(memory_matches) != 1:
        fail("expected exactly one 50-cancel-switch-preview record")
    memory = memory_matches[0]
    counts = memory.get("workerCounts", {})
    scheduler_counts = memory.get("schedulerCounts", {})
    memory_pass = (
        memory.get("measuredCycles") == 50
        and memory.get("mappingChecks") == 55
        and memory.get("histogramChecks") == 55
        and isinstance(counts.get("started"), int)
        and counts.get("started", 0) > 0
        and counts.get("started") == counts.get("finished")
        and counts.get("activeAfterJoin") == 0
        and scheduler_counts.get("deliveredB") == 55
        and scheduler_counts.get("discardedA") == 55
        and scheduler_counts.get("failed") == 0
        and memory.get("settledRSSBytes", math.inf) <= memory.get("rssLimitBytes", -1)
    )

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
        "records": [sanitized_record(record) for record in records],
        "gates": gates,
        "result": result,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {args.output}")
    print(f"result: {result}")


if __name__ == "__main__":
    main()
