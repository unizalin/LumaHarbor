#!/usr/bin/env python3

import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import re
import statistics


REQUIRED_FIELDS = {
    "schemaVersion", "productSHA", "harnessSHA", "instrumentationDigest",
    "configuration", "defines", "scenario", "variant", "round", "order",
    "sampleOrdinal", "seed", "maskCount", "nativeSize", "decodedSize", "outputSize",
    "recipeIDs", "stageDurationsSeconds", "totalDurationSeconds", "pixelError",
    "workerCounts", "cancelOutcome", "rssBytes", "thermalState", "result",
    "unavailableReasons",
}
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")
VARIANTS = ("B", "O")
ROUNDS = (1, 2)
ROUND_PATTERNS = {1: ("B", "O", "O", "B"), 2: ("O", "B", "B", "O")}


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


def is_nonnegative_integer(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def is_finite_nonnegative(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    try:
        return math.isfinite(value) and value >= 0
    except OverflowError:
        return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-per-round", required=True, type=int)
    parser.add_argument("--expected-scenario", action="append", required=True)
    parser.add_argument("--expected-mask-count", action="append", required=True, type=int)
    args = parser.parse_args()

    errors = []
    expected_scenarios = args.expected_scenario
    expected_mask_counts = args.expected_mask_count
    if args.expected_per_round < 2 or args.expected_per_round % 2 != 0:
        errors.append("expected-per-round must be a positive even integer")
    if len(set(expected_scenarios)) != len(expected_scenarios):
        errors.append("expected-scenario values must be unique")
    if len(set(expected_mask_counts)) != len(expected_mask_counts):
        errors.append("expected-mask-count values must be unique")
    if any(value not in {0, 1, 10} for value in expected_mask_counts):
        errors.append("expected-mask-count values must be 0, 1, or 10")

    records = []
    try:
        lines = args.samples.read_text(encoding="utf-8", errors="strict").splitlines()
    except (OSError, UnicodeError) as error:
        lines = []
        errors.append(f"could not read sample artifact: {error}")

    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            errors.append(f"line {line_number}: invalid JSON: {error.msg}")
            continue
        if not isinstance(record, dict):
            errors.append(f"line {line_number}: record must be an object")
            continue
        line_error_count = len(errors)
        missing = sorted(REQUIRED_FIELDS - record.keys())
        unexpected = sorted(record.keys() - REQUIRED_FIELDS)
        if missing:
            errors.append(f"line {line_number}: missing {','.join(missing)}")
        if unexpected:
            errors.append(f"line {line_number}: unexpected {','.join(unexpected)}")
        if missing:
            continue

        for field in ("configuration", "scenario", "variant", "result"):
            if not isinstance(record[field], str):
                errors.append(f"line {line_number}: {field} must be a string")
        for field in ("nativeSize", "decodedSize", "outputSize"):
            size = record[field]
            if not isinstance(size, dict) or set(size) != {"width", "height"} \
                    or any(type(value) is not int for value in size.values()) \
                    or size != {"width": 1600, "height": 1067}:
                errors.append(f"line {line_number}: {field} must be 1600x1067 integer dimensions")
        if type(record["schemaVersion"]) is not int or record["schemaVersion"] != 2:
            errors.append(f"line {line_number}: schemaVersion must be 2")
        if not isinstance(record["productSHA"], str) or COMMIT_PATTERN.fullmatch(record["productSHA"]) is None:
            errors.append(f"line {line_number}: productSHA must be a full lowercase commit")
        if not isinstance(record["harnessSHA"], str) or COMMIT_PATTERN.fullmatch(record["harnessSHA"]) is None:
            errors.append(f"line {line_number}: harnessSHA must be a full lowercase commit")
        if not isinstance(record["instrumentationDigest"], str) or DIGEST_PATTERN.fullmatch(record["instrumentationDigest"]) is None:
            errors.append(f"line {line_number}: instrumentationDigest must be a SHA-256 digest")
        if record["configuration"] != "release" or record["defines"] != []:
            errors.append(f"line {line_number}: expected standard Release with no defines")
        if record["scenario"] not in expected_scenarios:
            errors.append(f"line {line_number}: unexpected scenario")
        if record["variant"] not in VARIANTS:
            errors.append(f"line {line_number}: variant must be B or O")
        if type(record["round"]) is not int or record["round"] not in ROUNDS:
            errors.append(f"line {line_number}: round must be 1 or 2")
        if type(record["maskCount"]) is not int or record["maskCount"] not in expected_mask_counts:
            errors.append(f"line {line_number}: unexpected maskCount")
        if not is_nonnegative_integer(record["order"]):
            errors.append(f"line {line_number}: order must be a nonnegative integer")
        if not is_nonnegative_integer(record["sampleOrdinal"]):
            errors.append(f"line {line_number}: sampleOrdinal must be a nonnegative integer")
        duration = record["totalDurationSeconds"]
        if not is_finite_nonnegative(duration):
            errors.append(f"line {line_number}: invalid totalDurationSeconds")
        rss = record["rssBytes"]
        if rss is not None and (not is_nonnegative_integer(rss) or not is_finite_nonnegative(rss)):
            errors.append(f"line {line_number}: invalid rssBytes")
        if record["result"] != "MEASURED":
            errors.append(f"line {line_number}: non-measured result must be investigated")
        if len(errors) == line_error_count:
            records.append(record)

    expected_record_count = (
        len(expected_scenarios) * len(expected_mask_counts) * len(ROUNDS)
        * len(VARIANTS) * max(args.expected_per_round, 0)
    )
    if len(records) != expected_record_count:
        errors.append(f"expected {expected_record_count} records, found {len(records)}")

    valid_order_records = [record for record in records if is_nonnegative_integer(record.get("order"))]
    if sorted(record["order"] for record in valid_order_records) != list(range(len(records))):
        errors.append("order values must be unique and contiguous from zero")

    harness_shas = {record.get("harnessSHA") for record in records if isinstance(record.get("harnessSHA"), str)}
    if records and len(harness_shas) != 1:
        errors.append("all samples must use one harnessSHA")
    instrumentation_digests = {
        record.get("instrumentationDigest") for record in records
        if isinstance(record.get("instrumentationDigest"), str)
    }
    if records and len(instrumentation_digests) != 1:
        errors.append("all samples must use one instrumentationDigest")

    product_shas = {}
    for variant in VARIANTS:
        values = {
            record.get("productSHA") for record in records
            if record.get("variant") == variant and isinstance(record.get("productSHA"), str)
        }
        product_shas[variant] = values
        if len(values) != 1:
            errors.append(f"variant {variant} must use exactly one productSHA")
    if all(len(product_shas[variant]) == 1 for variant in VARIANTS) and product_shas["B"] == product_shas["O"]:
        errors.append("baseline and optimized variants must use distinct productSHA values")

    grouped = defaultdict(list)
    for record in records:
        grouped[(record.get("scenario"), record.get("maskCount"), record.get("round"), record.get("variant"))].append(record)

    expected_groups = []
    expected_sequence = []
    if args.expected_per_round >= 2 and args.expected_per_round % 2 == 0:
        blocks = args.expected_per_round // 2
        for scenario in expected_scenarios:
            for mask_count in expected_mask_counts:
                for round_number in ROUNDS:
                    pattern = ROUND_PATTERNS[round_number] * blocks
                    variant_ordinals = {
                        variant: iter(range(
                            (round_number - 1) * args.expected_per_round,
                            round_number * args.expected_per_round,
                        ))
                        for variant in VARIANTS
                    }
                    for variant in pattern:
                        expected_sequence.append((scenario, mask_count, round_number, variant, next(variant_ordinals[variant])))
                    for variant in VARIANTS:
                        expected_groups.append((scenario, mask_count, round_number, variant))

    actual_sequence = [
        (record.get("scenario"), record.get("maskCount"), record.get("round"), record.get("variant"), record.get("sampleOrdinal"))
        for record in sorted(valid_order_records, key=lambda item: item["order"])
    ]
    if expected_sequence and actual_sequence != expected_sequence:
        errors.append("records must follow the exact round variant order and sampleOrdinal contract")

    summaries = {}
    for key in expected_groups:
        values = grouped.get(key, [])
        group_name = f"{key[0]}/masks-{key[1]}/round-{key[2]}/{key[3]}"
        if len(values) != args.expected_per_round:
            errors.append(f"{group_name}: expected {args.expected_per_round} samples, found {len(values)}")
        elif all(isinstance(value.get("totalDurationSeconds"), (int, float)) and not isinstance(value.get("totalDurationSeconds"), bool) for value in values):
            summaries[group_name] = summary(values)

    gates = []
    if not errors:
        for scenario in expected_scenarios:
            for round_number in ROUNDS:
                def get(mask_count, variant):
                    return summaries[f"{scenario}/masks-{mask_count}/round-{round_number}/{variant}"]

                if 0 in expected_mask_counts:
                    baseline_empty = get(0, "B")
                    candidate_empty = get(0, "O")
                    p50_limit = baseline_empty["p50Seconds"] + max(0.005, baseline_empty["p50Seconds"] * 0.05)
                    p95_limit = baseline_empty["p95Seconds"] + 0.010
                    passed = candidate_empty["p50Seconds"] <= p50_limit and candidate_empty["p95Seconds"] <= p95_limit
                    gates.append({
                        "gate": "PERF-EMPTY", "scenario": scenario, "round": round_number,
                        "result": "PASS" if passed else "FAIL",
                        "candidateP50Seconds": candidate_empty["p50Seconds"],
                        "candidateP95Seconds": candidate_empty["p95Seconds"],
                        "p50LimitSeconds": p50_limit, "p95LimitSeconds": p95_limit,
                    })
                    for mask_count, p50_budget, p95_budget in ((1, 0.030, 0.060), (10, 0.100, 0.150)):
                        if mask_count not in expected_mask_counts:
                            continue
                        candidate = get(mask_count, "O")
                        delta_p50 = candidate["p50Seconds"] - candidate_empty["p50Seconds"]
                        delta_p95 = candidate["p95Seconds"] - candidate_empty["p95Seconds"]
                        passed = delta_p50 <= p50_budget and delta_p95 <= p95_budget
                        gates.append({
                            "gate": "PERF-PREVIEW", "scenario": scenario, "round": round_number,
                            "maskCount": mask_count, "result": "PASS" if passed else "FAIL",
                            "deltaP50Seconds": delta_p50, "deltaP95Seconds": delta_p95,
                            "p50BudgetSeconds": p50_budget, "p95BudgetSeconds": p95_budget,
                        })
                for mask_count in expected_mask_counts:
                    baseline = get(mask_count, "B")
                    candidate = get(mask_count, "O")
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

    for gate, reason in (
        ("PERF-COVERAGE", "production B/O harness exposes total preview wall time only"),
        ("INTERACTIVE-150", "real RAW workload was not part of this artifact"),
        ("PERF-EXPORT", "export workload was not part of this artifact"),
        ("PERF-MEM-EXPORT", "export workload was not part of this artifact"),
        ("PERF-MEM-50-CANCEL", "50-cycle workload was not part of this artifact"),
        ("PERF-CANCEL", "reported by the separate cancellation acceptance record"),
        ("PERF-UI", "requires device interaction evidence"),
    ):
        gates.append({"gate": gate, "result": "NOT RUN", "reason": reason})

    payload = {
        "schemaVersion": 1,
        "sampleArtifact": args.samples.name,
        "recordCount": len(records),
        "validation": "PASS" if not errors else "FAIL",
        "validationErrors": errors,
        "summaries": summaries,
        "gates": gates,
        "overallResult": "DONE_WITH_CONCERNS" if not errors else "FAIL",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({
        "gateArtifact": str(args.output), "recordCount": len(records),
        "validation": payload["validation"], "overallResult": payload["overallResult"],
    }, sort_keys=True))
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
