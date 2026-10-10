#!/usr/bin/env python3

import argparse
import json
import math
from pathlib import Path
import re
import statistics
import sys
import uuid


SAMPLE_FIELDS = {
    "schemaVersion",
    "buildIdentifier",
    "variant",
    "buildConfiguration",
    "fixtureIdentifier",
    "gestureKind",
    "gestureID",
    "expectedHeartbeatIntervalNanoseconds",
    "monotonicStartNanoseconds",
    "pointerUpNanoseconds",
    "visibleFrameNanoseconds",
    "monotonicEndNanoseconds",
    "frames",
    "completeness",
    "cancellationReason",
}
FRAME_FIELDS = {
    "intervalNanoseconds",
    "extraDelayNanoseconds",
    "missedHeartbeatCount",
}
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")


def fail(message):
    raise SystemExit(f"error: {message}")


def is_nonnegative_integer(value, *, positive=False):
    minimum = 1 if positive else 0
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def require_exact_fields(value, expected, context):
    if not isinstance(value, dict):
        fail(f"{context} must be a JSON object")
    missing = sorted(expected - value.keys())
    if missing:
        fail(f"{context} missing {','.join(missing)}")
    unexpected = sorted(value.keys() - expected)
    if unexpected:
        fail(f"{context} unexpected {','.join(unexpected)}")


def rounded_missed_heartbeat_count(interval, expected):
    remainder = interval % expected
    rounding_threshold = expected // 2 + expected % 2
    rounded_periods = interval // expected + (1 if remainder >= rounding_threshold else 0)
    return max(rounded_periods - 1, 0)


def parse_samples(path, expected_variant, minimum_gestures):
    try:
        lines = path.read_text(encoding="utf-8", errors="strict").splitlines()
    except OSError as error:
        fail(f"cannot read {expected_variant} samples: {error}")

    samples = []
    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            sample = json.loads(line)
        except json.JSONDecodeError as error:
            fail(f"{expected_variant} line {line_number}: invalid JSON record: {error.msg}")
        context = f"{expected_variant} line {line_number}"
        require_exact_fields(sample, SAMPLE_FIELDS, context)

        if sample["schemaVersion"] != 1:
            fail(f"{context}: unsupported schemaVersion")
        if sample["variant"] != expected_variant:
            fail(f"{context}: expected variant {expected_variant}")
        if not isinstance(sample["buildIdentifier"], str) \
                or not COMMIT_PATTERN.fullmatch(sample["buildIdentifier"]):
            fail(f"{context}: buildIdentifier must be a 40-character lowercase hex commit")
        for key in ("buildConfiguration", "fixtureIdentifier", "gestureKind"):
            if not isinstance(sample[key], str) or not sample[key]:
                fail(f"{context}: {key} must be a non-empty string")
        try:
            parsed_uuid = uuid.UUID(sample["gestureID"])
        except (ValueError, TypeError, AttributeError):
            fail(f"{context}: gestureID must be a UUID")
        if str(parsed_uuid) != sample["gestureID"].lower():
            fail(f"{context}: gestureID must use canonical UUID form")

        expected = sample["expectedHeartbeatIntervalNanoseconds"]
        start = sample["monotonicStartNanoseconds"]
        pointer_up = sample["pointerUpNanoseconds"]
        visible = sample["visibleFrameNanoseconds"]
        end = sample["monotonicEndNanoseconds"]
        if not is_nonnegative_integer(expected, positive=True):
            fail(f"{context}: expected heartbeat interval must be positive")
        if not all(is_nonnegative_integer(value) for value in (start, pointer_up, visible, end)):
            fail(f"{context}: monotonic timestamps must be nonnegative integers")
        if not start <= pointer_up <= visible <= end:
            fail(f"{context}: gesture timestamps are not monotonic")
        if sample["completeness"] != "complete" or sample["cancellationReason"] is not None:
            fail(f"{context}: incomplete sample ({sample['cancellationReason']!r})")

        frames = sample["frames"]
        if not isinstance(frames, list) or not frames:
            fail(f"{context}: frames must be a non-empty array")
        for frame_index, frame in enumerate(frames):
            frame_context = f"{context} frame {frame_index}"
            require_exact_fields(frame, FRAME_FIELDS, frame_context)
            interval = frame["intervalNanoseconds"]
            extra = frame["extraDelayNanoseconds"]
            missed = frame["missedHeartbeatCount"]
            if not is_nonnegative_integer(interval, positive=True) \
                    or not is_nonnegative_integer(extra) \
                    or not is_nonnegative_integer(missed):
                fail(f"{frame_context}: timing fields must be nonnegative integers")
            if extra != max(interval - expected, 0):
                fail(f"{frame_context}: extraDelayNanoseconds does not recompute")
            if missed != rounded_missed_heartbeat_count(interval, expected):
                fail(f"{frame_context}: missedHeartbeatCount does not recompute")
        samples.append(sample)

    if len(samples) < minimum_gestures:
        fail(f"{expected_variant}: expected at least {minimum_gestures} gestures, found {len(samples)}")
    gesture_ids = [sample["gestureID"] for sample in samples]
    if len(set(gesture_ids)) != len(gesture_ids):
        fail(f"{expected_variant}: duplicate gestureID")
    for key in (
        "buildIdentifier",
        "buildConfiguration",
        "fixtureIdentifier",
        "expectedHeartbeatIntervalNanoseconds",
    ):
        if len({sample[key] for sample in samples}) != 1:
            fail(f"{expected_variant}: mixed {key} values")
    return samples


def nearest_rank_p95(values):
    if not values:
        fail("cannot compute p95 from an empty sample list")
    ordered = sorted(values)
    return ordered[max(math.ceil(0.95 * len(ordered)) - 1, 0)]


def summarize(samples):
    extra_delays_ms = [
        frame["extraDelayNanoseconds"] / 1_000_000
        for sample in samples
        for frame in sample["frames"]
    ]
    warm_preview_ms = [
        (sample["visibleFrameNanoseconds"] - sample["pointerUpNanoseconds"]) / 1_000_000
        for sample in samples
    ]
    return {
        "buildIdentifier": samples[0]["buildIdentifier"],
        "variant": samples[0]["variant"],
        "buildConfiguration": samples[0]["buildConfiguration"],
        "fixtureIdentifier": samples[0]["fixtureIdentifier"],
        "expectedHeartbeatIntervalNanoseconds": samples[0]["expectedHeartbeatIntervalNanoseconds"],
        "gestureCount": len(samples),
        "frameCount": len(extra_delays_ms),
        "heartbeatExtraDelayP50Milliseconds": statistics.median(extra_delays_ms),
        "heartbeatExtraDelayP95Milliseconds": nearest_rank_p95(extra_delays_ms),
        "heartbeatExtraDelayMaxMilliseconds": max(extra_delays_ms),
        "warmPreviewP50Milliseconds": statistics.median(warm_preview_ms),
        "warmPreviewP95Milliseconds": nearest_rank_p95(warm_preview_ms),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--optimized", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--minimum-gestures", type=int, default=30)
    args = parser.parse_args()

    if args.minimum_gestures < 1:
        fail("minimum-gestures must be positive")

    baseline_samples = parse_samples(args.baseline, "B", args.minimum_gestures)
    optimized_samples = parse_samples(args.optimized, "O", args.minimum_gestures)
    if len(baseline_samples) != len(optimized_samples):
        fail("B/O gesture count mismatch")
    if [sample["gestureKind"] for sample in baseline_samples] != [
        sample["gestureKind"] for sample in optimized_samples
    ]:
        fail("B/O gesture sequence mismatch")
    for key in (
        "buildConfiguration",
        "fixtureIdentifier",
        "expectedHeartbeatIntervalNanoseconds",
    ):
        if baseline_samples[0][key] != optimized_samples[0][key]:
            fail(f"B/O {key} mismatch")
    if baseline_samples[0]["buildIdentifier"] == optimized_samples[0]["buildIdentifier"]:
        fail("B/O buildIdentifier must identify different commits")

    baseline = summarize(baseline_samples)
    optimized = summarize(optimized_samples)
    heartbeat_passed = (
        optimized["heartbeatExtraDelayP95Milliseconds"] <= 50
        and optimized["heartbeatExtraDelayMaxMilliseconds"] <= 100
    )
    warm_preview_limit = baseline["warmPreviewP95Milliseconds"] * 1.10
    warm_preview_passed = optimized["warmPreviewP95Milliseconds"] <= warm_preview_limit
    overall_passed = heartbeat_passed and warm_preview_passed

    gates = [
        {
            "gate": "PERF-UI-HEARTBEAT",
            "result": "PASS" if heartbeat_passed else "FAIL",
            "optimizedP95Milliseconds": optimized["heartbeatExtraDelayP95Milliseconds"],
            "optimizedMaxMilliseconds": optimized["heartbeatExtraDelayMaxMilliseconds"],
            "p95LimitMilliseconds": 50,
            "maxLimitMilliseconds": 100,
        },
        {
            "gate": "PERF-UI-WARM-PREVIEW",
            "result": "PASS" if warm_preview_passed else "FAIL",
            "baselineP95Milliseconds": baseline["warmPreviewP95Milliseconds"],
            "optimizedP95Milliseconds": optimized["warmPreviewP95Milliseconds"],
            "optimizedLimitMilliseconds": warm_preview_limit,
            "maximumRegressionPercent": 10,
        },
        {
            "gate": "PERF-UI",
            "result": "PASS" if overall_passed else "FAIL",
        },
    ]
    artifact = {
        "schemaVersion": 1,
        "result": "PASS" if overall_passed else "FAIL",
        "baseline": baseline,
        "optimized": optimized,
        "gates": gates,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(artifact, sort_keys=True))
    return 0 if overall_passed else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(1)
