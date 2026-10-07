#!/usr/bin/env python3

import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import re
import statistics


REQUIRED_FIELDS = {
    "schemaVersion",
    "productSHA",
    "harnessSHA",
    "instrumentationDigest",
    "configuration",
    "sourceKind",
    "operation",
    "scenario",
    "variant",
    "round",
    "order",
    "sampleOrdinal",
    "maskCount",
    "nativeSize",
    "decodedSize",
    "outputSize",
    "totalDurationSeconds",
    "peakRSSBytes",
    "contextLifecycle",
    "contextCreationCountBeforeTimer",
    "contextCreationCountDuringTimer",
    "timingBoundary",
    "publishedFileValidated",
    "sourceFingerprintUnchanged",
    "thermalState",
    "result",
}
LEGACY_COUNT_FIELDS = {"contextCreationCountBeforeTimer", "contextCreationCountDuringTimer"}
EXPECTED_COUNT_FIELDS = {"expectedContextCreationCountBeforeTimer", "expectedContextCreationCountDuringTimer"}
V3_REQUIRED_FIELDS = (REQUIRED_FIELDS - LEGACY_COUNT_FIELDS) | EXPECTED_COUNT_FIELDS | {"contextCountEvidence"}
CONTEXT_EVIDENCE = "declared-from-construction-path"
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")
PREVIEW_SCENARIOS = ("cold", "warm", "changed")
MASK_COUNTS = (0, 1, 10)
EXPORT_MASK_COUNTS = (1, 10)
VARIANTS = ("B", "O")
ROUNDS = (1, 2)
ROUND_PATTERNS = {1: ("B", "O", "O", "B"), 2: ("O", "B", "B", "O")}


def percentile_95(values):
    ordered = sorted(values)
    return ordered[max(math.ceil(0.95 * len(ordered)) - 1, 0)]


def is_nonnegative_integer(value, *, positive=False):
    minimum = 1 if positive else 0
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def size_tuple(value):
    if not isinstance(value, dict) or set(value) != {"width", "height"}:
        return None
    width = value["width"]
    height = value["height"]
    if not is_nonnegative_integer(width, positive=True) or not is_nonnegative_integer(height, positive=True):
        return None
    return width, height


def sample_summary(records):
    durations = [record["totalDurationSeconds"] for record in records]
    return {
        "count": len(records),
        "p50Seconds": statistics.median(durations),
        "p95Seconds": percentile_95(durations),
        "peakRSSBytes": max(record["peakRSSBytes"] for record in records),
    }


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
    parser.add_argument("--expected-preview-samples", type=int, default=8)
    parser.add_argument("--expected-export-samples", type=int, default=4)
    args = parser.parse_args()

    errors = []
    if args.expected_preview_samples < 1:
        errors.append("expected-preview-samples must be positive")
    if args.expected_export_samples < 1:
        errors.append("expected-export-samples must be positive")

    records = []
    sample_versions = set()
    try:
        lines = args.samples.read_text(encoding="utf-8", errors="strict").splitlines()
    except (OSError, UnicodeError) as error:
        lines = []
        errors.append(f"could not read sample artifact: {error}")

    for line_number, line in enumerate(lines, start=1):
        candidate = line.strip()
        if not candidate:
            continue
        try:
            record = json.loads(candidate)
        except json.JSONDecodeError as error:
            errors.append(f"line {line_number}: invalid JSON: {error.msg}")
            continue
        if not isinstance(record, dict):
            errors.append(f"line {line_number}: record must be an object")
            continue

        line_error_count = len(errors)
        version = record.get("schemaVersion")
        if type(version) is not int or version not in (2, 3):
            errors.append(f"line {line_number}: schemaVersion must be integer 2 or 3")
            continue
        sample_versions.add(version)
        required_fields = V3_REQUIRED_FIELDS if version == 3 else REQUIRED_FIELDS
        missing = sorted(required_fields - record.keys())
        unexpected = sorted(record.keys() - required_fields)
        if missing:
            errors.append(f"line {line_number}: missing {','.join(missing)}")
        if unexpected:
            errors.append(f"line {line_number}: unexpected {','.join(unexpected)}")
        if missing:
            continue

        count_prefix = "expectedContextCreationCount" if version == 3 else "contextCreationCount"
        if version == 3 and record["contextCountEvidence"] != CONTEXT_EVIDENCE:
            errors.append(f"line {line_number}: contextCountEvidence must declare construction-path expectations")
        scalar_fields = ("configuration", "sourceKind", "operation", "scenario", "variant",
                         "contextLifecycle", "timingBoundary", "thermalState", "result")
        invalid_scalars = [field for field in scalar_fields if not isinstance(record[field], str)]
        if invalid_scalars:
            errors.append(f"line {line_number}: {','.join(invalid_scalars)} must be strings")
            # Do not allow compound values to reach enum sets or grouping keys.
            continue
        if not isinstance(record["productSHA"], str) \
                or COMMIT_PATTERN.fullmatch(record["productSHA"]) is None:
            errors.append(f"line {line_number}: productSHA must be a full lowercase commit")
        if not isinstance(record["harnessSHA"], str) \
                or COMMIT_PATTERN.fullmatch(record["harnessSHA"]) is None:
            errors.append(f"line {line_number}: harnessSHA must be a full lowercase commit")
        if not isinstance(record["instrumentationDigest"], str) \
                or DIGEST_PATTERN.fullmatch(record["instrumentationDigest"]) is None:
            errors.append(f"line {line_number}: instrumentationDigest must be a SHA-256 digest")
        if record["configuration"] != "release":
            errors.append(f"line {line_number}: configuration must be release")
        if record["variant"] not in VARIANTS:
            errors.append(f"line {line_number}: variant must be B or O")
        if type(record["round"]) is not int or record["round"] not in ROUNDS:
            errors.append(f"line {line_number}: round must be 1 or 2")
        if not is_nonnegative_integer(record["order"]):
            errors.append(f"line {line_number}: order must be a nonnegative integer")
        if not is_nonnegative_integer(record["sampleOrdinal"]):
            errors.append(f"line {line_number}: sampleOrdinal must be a nonnegative integer")
        if type(record["maskCount"]) is not int or record["maskCount"] not in MASK_COUNTS:
            errors.append(f"line {line_number}: invalid maskCount")
        if size_tuple(record["nativeSize"]) is None:
            errors.append(f"line {line_number}: invalid nativeSize")
        if size_tuple(record["decodedSize"]) is None:
            errors.append(f"line {line_number}: invalid decodedSize")
        if size_tuple(record["outputSize"]) is None:
            errors.append(f"line {line_number}: invalid outputSize")
        duration = record["totalDurationSeconds"]
        if not is_finite_nonnegative(duration):
            errors.append(f"line {line_number}: invalid totalDurationSeconds")
        if not is_nonnegative_integer(record["peakRSSBytes"], positive=True) or not is_finite_nonnegative(record["peakRSSBytes"]):
            errors.append(f"line {line_number}: invalid peakRSSBytes")
        if not isinstance(record["contextLifecycle"], str) or not record["contextLifecycle"]:
            errors.append(f"line {line_number}: contextLifecycle must be nonempty")
        if not is_nonnegative_integer(record[count_prefix + "BeforeTimer"]):
            errors.append(f"line {line_number}: invalid contextCreationCountBeforeTimer")
        if not is_nonnegative_integer(record[count_prefix + "DuringTimer"]):
            errors.append(f"line {line_number}: invalid contextCreationCountDuringTimer")
        if record["sourceFingerprintUnchanged"] is not True:
            errors.append(f"line {line_number}: source fingerprint changed or was not checked")
        if not isinstance(record["thermalState"], str) or not record["thermalState"]:
            errors.append(f"line {line_number}: thermalState must be nonempty")
        if record["result"] != "MEASURED":
            errors.append(f"line {line_number}: result must be MEASURED")

        native = size_tuple(record["nativeSize"])
        decoded = size_tuple(record["decodedSize"])
        output = size_tuple(record["outputSize"])
        if record["operation"] == "preview":
            if record["sourceKind"] != "real-raw":
                errors.append(f"line {line_number}: preview sourceKind must be real-raw")
            if record["scenario"] not in PREVIEW_SCENARIOS:
                errors.append(f"line {line_number}: invalid preview scenario")
            if record["timingBoundary"] != "submit-through-materialized-cgimage":
                errors.append(f"line {line_number}: invalid preview timing boundary")
            if record["publishedFileValidated"] is not None:
                errors.append(f"line {line_number}: preview publishedFileValidated must be null")
            expected_lifecycle = (
                "fresh-renderer-context-inside-timer" if record["scenario"] == "cold"
                else "fresh-renderer-context-before-warmup-reused-for-timed-request"
            )
            if record["contextLifecycle"] != expected_lifecycle:
                errors.append(f"line {line_number}: invalid preview context lifecycle")
            if decoded and output and decoded != output:
                errors.append(f"line {line_number}: preview decoded/output size mismatch")
            if native and output and (
                max(output) != 1_600 or max(native) <= 1_600
                or abs(min(output) * max(native) - 1600 * min(native)) > max(native)
            ):
                errors.append(f"line {line_number}: preview was not a bounded 1600px decode")
        elif record["operation"] == "export":
            if record["sourceKind"] not in {"real-raw", "synthetic-24mp"}:
                errors.append(f"line {line_number}: invalid export sourceKind")
            if record["sourceKind"] == "synthetic-24mp" and native and sorted(native) != [4000, 6000]:
                errors.append(f"line {line_number}: synthetic-24mp native size must be 6000x4000")
            if record["scenario"] != "full-resolution":
                errors.append(f"line {line_number}: export scenario must be full-resolution")
            if record["maskCount"] not in EXPORT_MASK_COUNTS:
                errors.append(f"line {line_number}: export maskCount must be 1 or 10")
            if record["timingBoundary"] != "submit-through-export-return-and-published-image-reopen":
                errors.append(f"line {line_number}: export timer does not include publish/reopen")
            if record["publishedFileValidated"] is not True:
                errors.append(f"line {line_number}: published output was not validated")
            if record["contextLifecycle"] != "fresh-exporter-context-inside-timer":
                errors.append(f"line {line_number}: invalid export context lifecycle")
            if native and decoded and output and not (
                sorted(native) == sorted(decoded) == sorted(output)
            ):
                errors.append(f"line {line_number}: full-resolution export size mismatch")
        else:
            errors.append(f"line {line_number}: operation must be preview or export")

        if record["operation"] == "preview" and record["scenario"] != "cold":
            expected_before = 2 if record["variant"] == "B" else 1
            expected_during = 1 if record["variant"] == "B" else 0
        else:
            expected_before = 0
            expected_during = 2 if record["variant"] == "B" else 1
        if record[count_prefix + "BeforeTimer"] != expected_before:
            errors.append(f"line {line_number}: unexpected context creations before timer")
        if record[count_prefix + "DuringTimer"] != expected_during:
            errors.append(f"line {line_number}: unexpected context creations during timer")

        if len(errors) == line_error_count:
            records.append(record)

    if len(sample_versions) > 1:
        errors.append("all records must use one sample schemaVersion")
    for source_kind in ("real-raw", "synthetic-24mp"):
        native_sizes = {size_tuple(r["nativeSize"]) for r in records if r["sourceKind"] == source_kind}
        if len(native_sizes) > 1:
            errors.append(f"{source_kind}: native size must be consistent across the fixture")
    preview_sizes = {size_tuple(r["outputSize"]) for r in records if r["operation"] == "preview"}
    if len(preview_sizes) > 1:
        errors.append("preview output size and orientation must be consistent across B/O and groups")

    expected_record_count = (
        len(PREVIEW_SCENARIOS) * len(MASK_COUNTS) * len(ROUNDS) * len(VARIANTS)
        * args.expected_preview_samples
        + 2 * len(EXPORT_MASK_COUNTS) * len(ROUNDS) * len(VARIANTS)
        * args.expected_export_samples
    )
    if len(records) != expected_record_count:
        errors.append(f"expected {expected_record_count} records, found {len(records)}")

    orders = [record["order"] for record in records if is_nonnegative_integer(record.get("order"))]
    if sorted(orders) != list(range(len(records))):
        errors.append("order values must be unique and contiguous from zero")
    harness_shas = {
        record["harnessSHA"] for record in records
        if isinstance(record.get("harnessSHA"), str)
    }
    if records and len(harness_shas) != 1:
        errors.append("all records must use one harnessSHA")
    instrumentation_digests = {
        record["instrumentationDigest"] for record in records
        if isinstance(record.get("instrumentationDigest"), str)
    }
    if records and len(instrumentation_digests) != 1:
        errors.append("all records must use one instrumentationDigest")
    for variant in VARIANTS:
        product_shas = {
            record["productSHA"] for record in records
            if record.get("variant") == variant
            and isinstance(record.get("productSHA"), str)
        }
        if len(product_shas) != 1:
            errors.append(f"variant {variant} must use exactly one productSHA")
    baseline_shas = {
        record["productSHA"] for record in records
        if record.get("variant") == "B" and isinstance(record.get("productSHA"), str)
    }
    optimized_shas = {
        record["productSHA"] for record in records
        if record.get("variant") == "O" and isinstance(record.get("productSHA"), str)
    }
    if len(baseline_shas) == 1 and baseline_shas == optimized_shas:
        errors.append("baseline and optimized variants must use distinct productSHA values")

    grouped = defaultdict(list)
    ordered_records = []
    for record in records:
        operation = record.get("operation")
        scenario = record.get("scenario")
        source_kind = record.get("sourceKind")
        mask_count = record.get("maskCount")
        variant = record.get("variant")
        if operation == "preview" \
                and scenario in PREVIEW_SCENARIOS \
                and mask_count in MASK_COUNTS \
                and variant in VARIANTS:
            grouped[("preview", scenario, mask_count, record.get("round"), variant)].append(record)
            ordered_records.append(record)
        elif operation == "export" \
                and source_kind in {"synthetic-24mp", "real-raw"} \
                and mask_count in EXPORT_MASK_COUNTS \
                and variant in VARIANTS:
            grouped[("export", source_kind, mask_count, record.get("round"), variant)].append(record)
            ordered_records.append(record)

    expected_sequence = []

    def append_expected_group(operation, source_kind, scenario, mask_count, samples_per_variant):
        ordinals = {variant: 0 for variant in VARIANTS}
        blocks = samples_per_variant // 2
        for round_number in ROUNDS:
            for variant in ROUND_PATTERNS[round_number] * blocks:
                expected_sequence.append((
                    operation,
                    source_kind,
                    scenario,
                    mask_count,
                    round_number,
                    variant,
                    ordinals[variant],
                ))
                ordinals[variant] += 1

    for scenario in PREVIEW_SCENARIOS:
        for mask_count in MASK_COUNTS:
            append_expected_group("preview", "real-raw", scenario, mask_count, args.expected_preview_samples)
    for source_kind in ("synthetic-24mp", "real-raw"):
        for mask_count in EXPORT_MASK_COUNTS:
            append_expected_group("export", source_kind, "full-resolution", mask_count, args.expected_export_samples)

    if len(ordered_records) == len(records) and all(
        is_nonnegative_integer(record.get("order")) for record in records
    ):
        actual_sequence = []
        for record in sorted(ordered_records, key=lambda item: item["order"]):
            actual_sequence.append((
                record.get("operation"),
                record.get("sourceKind"),
                record.get("scenario"),
                record.get("maskCount"),
                record.get("round"),
                record.get("variant"),
                record.get("sampleOrdinal"),
            ))
        if actual_sequence != expected_sequence:
            errors.append("records must follow the exact round variant order and sampleOrdinal contract")

    expected_groups = []
    for scenario in PREVIEW_SCENARIOS:
        for mask_count in MASK_COUNTS:
            for round_number in ROUNDS:
                for variant in VARIANTS:
                    expected_groups.append((
                        ("preview", scenario, mask_count, round_number, variant),
                        args.expected_preview_samples,
                    ))
    for source_kind in ("synthetic-24mp", "real-raw"):
        for mask_count in EXPORT_MASK_COUNTS:
            for round_number in ROUNDS:
                for variant in VARIANTS:
                    expected_groups.append((
                        ("export", source_kind, mask_count, round_number, variant),
                        args.expected_export_samples,
                    ))

    for key, expected_count in expected_groups:
        values = grouped.get(key, [])
        if len(values) != expected_count:
            errors.append(f"{'/'.join(map(str, key))}: expected {expected_count} samples, found {len(values)}")
            continue
        ordinals = [record["sampleOrdinal"] for record in values]
        expected_ordinal_start = (key[3] - 1) * expected_count
        expected_ordinals = list(range(expected_ordinal_start, expected_ordinal_start + expected_count))
        if not all(is_nonnegative_integer(ordinal) for ordinal in ordinals) \
                or sorted(ordinals) != expected_ordinals:
            errors.append(
                f"{'/'.join(map(str, key))}: sampleOrdinal must cover "
                f"{expected_ordinal_start} through {expected_ordinals[-1]} within the round"
            )

    summaries = {}
    gates = []
    if not errors:
        summary_groups = defaultdict(list)
        for key, values in grouped.items():
            if key[0] == "preview":
                summary_key = (key[0], key[1], key[2], key[4])
            else:
                summary_key = (key[0], key[1], key[2], key[4])
            summary_groups[summary_key].extend(values)
        for key, values in summary_groups.items():
            summaries["/".join(map(str, key))] = sample_summary(values)

        for scenario in PREVIEW_SCENARIOS:
            for mask_count in MASK_COUNTS:
                baseline = summaries[f"preview/{scenario}/{mask_count}/B"]
                optimized = summaries[f"preview/{scenario}/{mask_count}/O"]
                if scenario == "warm":
                    interactive_pass = (
                        optimized["p50Seconds"] <= 0.150
                        and optimized["p95Seconds"] <= 0.150
                    )
                    gates.append({
                        "gate": "INTERACTIVE-150",
                        "scenario": scenario,
                        "maskCount": mask_count,
                        "result": "PASS" if interactive_pass else "FAIL",
                        "optimizedP50Seconds": optimized["p50Seconds"],
                        "optimizedP95Seconds": optimized["p95Seconds"],
                        "budgetSeconds": 0.150,
                    })
                memory_limit = baseline["peakRSSBytes"] + 32 * 1024 * 1024
                gates.append({
                    "gate": "PERF-MEM-PREVIEW",
                    "scenario": scenario,
                    "maskCount": mask_count,
                    "result": "PASS" if optimized["peakRSSBytes"] <= memory_limit else "FAIL",
                    "baselinePeakRSSBytes": baseline["peakRSSBytes"],
                    "optimizedPeakRSSBytes": optimized["peakRSSBytes"],
                    "optimizedLimitBytes": memory_limit,
                })

        for source_kind in ("synthetic-24mp", "real-raw"):
            for mask_count, absolute_budget in ((1, 5.0), (10, 15.0)):
                baseline = summaries[f"export/{source_kind}/{mask_count}/B"]
                optimized = summaries[f"export/{source_kind}/{mask_count}/O"]
                baseline_median = baseline["p50Seconds"]
                optimized_median = optimized["p50Seconds"]
                if baseline_median <= absolute_budget:
                    performance_pass = (
                        optimized_median <= absolute_budget
                        and optimized_median <= baseline_median * 1.05
                    )
                    rule = "absolute-budget-and-max-five-percent-regression"
                    limit = min(absolute_budget, baseline_median * 1.05)
                else:
                    performance_pass = optimized_median <= baseline_median * 0.5
                    rule = "minimum-fifty-percent-improvement"
                    limit = baseline_median * 0.5
                gates.append({
                    "gate": "PERF-EXPORT",
                    "sourceKind": source_kind,
                    "maskCount": mask_count,
                    "result": "PASS" if performance_pass else "FAIL",
                    "baselineMedianSeconds": baseline_median,
                    "optimizedMedianSeconds": optimized_median,
                    "optimizedLimitSeconds": limit,
                    "rule": rule,
                })

                absolute_memory_limit = (
                    768 * 1024 * 1024 if source_kind == "synthetic-24mp" else None
                )
                memory_pass = optimized["peakRSSBytes"] <= baseline["peakRSSBytes"]
                if absolute_memory_limit is not None:
                    memory_pass = (
                        memory_pass
                        and optimized["peakRSSBytes"] <= absolute_memory_limit
                    )
                gates.append({
                    "gate": "PERF-MEM-EXPORT",
                    "sourceKind": source_kind,
                    "maskCount": mask_count,
                    "result": "PASS" if memory_pass else "FAIL",
                    "baselinePeakRSSBytes": baseline["peakRSSBytes"],
                    "optimizedPeakRSSBytes": optimized["peakRSSBytes"],
                    "absoluteLimitBytes": absolute_memory_limit,
                })

    payload = {
        "schemaVersion": 1,
        "sampleArtifact": args.samples.name,
        "contextCountEvidence": CONTEXT_EVIDENCE,
        "contextCountLimitation": "Context allocations are not measured; v2 and v3 counts are construction-path declarations only.",
        "recordCount": len(records),
        "validation": "PASS" if not errors else "FAIL",
        "validationErrors": errors,
        "baselineProductSHA": next(
            (record["productSHA"] for record in records
             if record.get("variant") == "B"
             and isinstance(record.get("productSHA"), str)
             and COMMIT_PATTERN.fullmatch(record["productSHA"])),
            None,
        ),
        "optimizedProductSHA": next(
            (record["productSHA"] for record in records
             if record.get("variant") == "O"
             and isinstance(record.get("productSHA"), str)
             and COMMIT_PATTERN.fullmatch(record["productSHA"])),
            None,
        ),
        "harnessSHA": next(iter(harness_shas), None)
            if len(harness_shas) == 1 and COMMIT_PATTERN.fullmatch(next(iter(harness_shas)))
            else None,
        "instrumentationDigest": next(iter(instrumentation_digests), None)
            if len(instrumentation_digests) == 1
            and DIGEST_PATTERN.fullmatch(next(iter(instrumentation_digests)))
            else None,
        "summaries": summaries,
        "gates": gates,
        "overallResult": "DONE_WITH_CONCERNS" if not errors else "FAIL",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({
        "gateArtifact": str(args.output),
        "recordCount": len(records),
        "validation": payload["validation"],
        "overallResult": payload["overallResult"],
    }, sort_keys=True))
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
