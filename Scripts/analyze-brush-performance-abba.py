#!/usr/bin/env python3

import argparse
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path


REQUIRED_FIELDS = {
    "schemaVersion", "productSHA", "harnessSHA", "instrumentationDigest",
    "configuration", "defines", "scenario", "variant", "round", "order",
    "sampleOrdinal", "seed", "nativeSize", "decodedSize", "outputSize",
    "recipeIDs", "stageDurationsSeconds", "totalDurationSeconds", "pixelError",
    "workerCounts", "cancelOutcome", "rssBytes", "thermalState", "result",
}


def percentile_95(values):
    ordered = sorted(values)
    return ordered[max(math.ceil(0.95 * len(ordered)) - 1, 0)]


def summary(records):
    durations = [record["totalDurationSeconds"] for record in records]
    rss_values = [record["rssBytes"] for record in records if record["rssBytes"] is not None]
    return {
        "count": len(records),
        "p50Seconds": statistics.median(durations),
        "p95Seconds": percentile_95(durations),
        "peakRSSBytes": max(rss_values) if len(rss_values) == len(records) else None,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--expected-per-round", required=True, type=int)
    args = parser.parse_args()

    records = []
    errors = []
    for line_number, line in enumerate(Path(args.samples).read_text().splitlines(), start=1):
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            errors.append(f"line {line_number}: invalid JSON: {error}")
            continue
        missing = sorted(REQUIRED_FIELDS - record.keys())
        if missing:
            errors.append(f"line {line_number}: missing {','.join(missing)}")
        if record.get("schemaVersion") != 2:
            errors.append(f"line {line_number}: schemaVersion must be 2")
        if record.get("configuration") != "release" or record.get("defines") != []:
            errors.append(f"line {line_number}: expected standard Release with no defines")
        if record.get("result") != "MEASURED":
            errors.append(f"line {line_number}: non-measured result must be investigated")
        records.append(record)

    grouped = defaultdict(list)
    for record in records:
        grouped[(record["scenario"], record["maskCount"], record["round"], record["variant"])].append(record)

    summaries = {}
    gates = []
    for key, values in sorted(grouped.items()):
        scenario, mask_count, round_number, variant = key
        group_name = f"{scenario}/masks-{mask_count}/round-{round_number}/{variant}"
        summaries[group_name] = summary(values)
        if len(values) != args.expected_per_round:
            errors.append(
                f"{group_name}: expected {args.expected_per_round} samples, found {len(values)}"
            )

    scenarios = sorted({record["scenario"] for record in records})
    rounds = sorted({record["round"] for record in records})
    for scenario in scenarios:
        for round_number in rounds:
            def get(mask_count, variant):
                return summaries.get(f"{scenario}/masks-{mask_count}/round-{round_number}/{variant}")

            baseline_empty = get(0, "B")
            candidate_empty = get(0, "O")
            if baseline_empty and candidate_empty:
                p50_limit = baseline_empty["p50Seconds"] + max(0.005, baseline_empty["p50Seconds"] * 0.05)
                p95_limit = baseline_empty["p95Seconds"] + 0.010
                passed = (
                    candidate_empty["p50Seconds"] <= p50_limit
                    and candidate_empty["p95Seconds"] <= p95_limit
                )
                gates.append({
                    "gate": "PERF-EMPTY", "scenario": scenario, "round": round_number,
                    "result": "PASS" if passed else "FAIL",
                    "candidateP50Seconds": candidate_empty["p50Seconds"],
                    "candidateP95Seconds": candidate_empty["p95Seconds"],
                    "p50LimitSeconds": p50_limit, "p95LimitSeconds": p95_limit,
                })

            for mask_count, p50_budget, p95_budget in [(1, 0.030, 0.060), (10, 0.100, 0.150)]:
                candidate = get(mask_count, "O")
                if candidate_empty and candidate:
                    delta_p50 = candidate["p50Seconds"] - candidate_empty["p50Seconds"]
                    delta_p95 = candidate["p95Seconds"] - candidate_empty["p95Seconds"]
                    passed = delta_p50 <= p50_budget and delta_p95 <= p95_budget
                    gates.append({
                        "gate": "PERF-PREVIEW", "scenario": scenario, "round": round_number,
                        "maskCount": mask_count, "result": "PASS" if passed else "FAIL",
                        "deltaP50Seconds": delta_p50, "deltaP95Seconds": delta_p95,
                        "p50BudgetSeconds": p50_budget, "p95BudgetSeconds": p95_budget,
                    })

            for mask_count in (0, 1, 10):
                baseline = get(mask_count, "B")
                candidate = get(mask_count, "O")
                if baseline and candidate:
                    baseline_rss = baseline["peakRSSBytes"]
                    candidate_rss = candidate["peakRSSBytes"]
                    if baseline_rss is None or candidate_rss is None:
                        result = "NOT RUN"
                    else:
                        result = "PASS" if candidate_rss <= baseline_rss + 32 * 1024 * 1024 else "FAIL"
                    gates.append({
                        "gate": "PERF-MEM-PREVIEW", "scenario": scenario,
                        "round": round_number, "maskCount": mask_count, "result": result,
                        "baselinePeakRSSBytes": baseline_rss, "candidatePeakRSSBytes": candidate_rss,
                    })

    for gate, reason in [
        ("PERF-COVERAGE", "production B/O harness exposes total preview wall time only"),
        ("INTERACTIVE-150", "real RAW workload was not part of this artifact"),
        ("PERF-EXPORT", "export workload was not part of this artifact"),
        ("PERF-MEM-EXPORT", "export workload was not part of this artifact"),
        ("PERF-MEM-50-CANCEL", "50-cycle workload was not part of this artifact"),
        ("PERF-CANCEL", "reported by the separate cancellation acceptance record"),
        ("PERF-UI", "requires device interaction evidence"),
    ]:
        gates.append({"gate": gate, "result": "NOT RUN", "reason": reason})

    payload = {
        "schemaVersion": 1,
        "sampleArtifact": Path(args.samples).name,
        "recordCount": len(records),
        "validation": "PASS" if not errors else "FAIL",
        "validationErrors": errors,
        "summaries": summaries,
        "gates": gates,
        "overallResult": "DONE_WITH_CONCERNS" if not errors else "FAIL",
    }
    Path(args.output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(json.dumps({
        "gateArtifact": str(Path(args.output)),
        "recordCount": len(records),
        "validation": payload["validation"],
        "overallResult": payload["overallResult"],
    }, sort_keys=True))
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
