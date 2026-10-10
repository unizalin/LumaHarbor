import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid


REPO_ROOT = Path(__file__).resolve().parents[2]
ANALYZER = REPO_ROOT / "Scripts/analyze-brush-ui-heartbeat.py"


def sample(variant, ordinal, *, preview_ms=100, extra_ms=10, complete=True, fixture="fixture-a"):
    start = ordinal * 1_000_000_000
    pointer_up = start + 200_000_000
    visible = pointer_up + preview_ms * 1_000_000
    expected = 16_666_667
    interval = expected + extra_ms * 1_000_000
    return {
        "schemaVersion": 1,
        "buildIdentifier": ("a" if variant == "B" else "b") * 40,
        "variant": variant,
        "buildConfiguration": "Release",
        "fixtureIdentifier": fixture,
        "gestureKind": "paint",
        "gestureID": str(uuid.uuid5(uuid.NAMESPACE_DNS, f"{variant}-{ordinal}")),
        "expectedHeartbeatIntervalNanoseconds": expected,
        "monotonicStartNanoseconds": start,
        "pointerUpNanoseconds": pointer_up,
        "visibleFrameNanoseconds": visible,
        "monotonicEndNanoseconds": visible + expected,
        "frames": [{
            "intervalNanoseconds": interval,
            "extraDelayNanoseconds": extra_ms * 1_000_000,
            "missedHeartbeatCount": max(round(interval / expected) - 1, 0),
        }],
        "completeness": "complete" if complete else "incomplete",
        "cancellationReason": None if complete else "gestureCancelled",
    }


class AnalyzeBrushUIHeartbeatTests(unittest.TestCase):
    def run_analyzer(self, baseline, optimized):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline_path = root / "baseline.jsonl"
            optimized_path = root / "optimized.jsonl"
            output_path = root / "summary.json"
            baseline_path.write_text("\n".join(json.dumps(item) for item in baseline) + "\n")
            optimized_path.write_text("\n".join(json.dumps(item) for item in optimized) + "\n")
            completed = subprocess.run(
                [
                    "python3", str(ANALYZER),
                    "--baseline", str(baseline_path),
                    "--optimized", str(optimized_path),
                    "--output", str(output_path),
                    "--minimum-gestures", "30",
                ],
                text=True,
                capture_output=True,
            )
            output = json.loads(output_path.read_text()) if output_path.exists() else None
            return completed, output

    def test_valid_pair_passes_heartbeat_and_warm_preview_gates(self):
        baseline = [sample("B", index, preview_ms=100) for index in range(30)]
        optimized = [sample("O", index, preview_ms=105) for index in range(30)]

        completed, output = self.run_analyzer(baseline, optimized)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(output["result"], "PASS")
        self.assertEqual(
            {gate["gate"]: gate["result"] for gate in output["gates"]},
            {
                "PERF-UI-HEARTBEAT": "PASS",
                "PERF-UI-WARM-PREVIEW": "PASS",
                "PERF-UI": "PASS",
            },
        )

    def test_heartbeat_over_absolute_limit_fails(self):
        baseline = [sample("B", index) for index in range(30)]
        optimized = [sample("O", index, extra_ms=101) for index in range(30)]

        completed, output = self.run_analyzer(baseline, optimized)

        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(output["result"], "FAIL")
        self.assertEqual(output["gates"][0]["result"], "FAIL")

    def test_warm_preview_regression_over_ten_percent_fails(self):
        baseline = [sample("B", index, preview_ms=100) for index in range(30)]
        optimized = [sample("O", index, preview_ms=111) for index in range(30)]

        completed, output = self.run_analyzer(baseline, optimized)

        self.assertNotEqual(completed.returncode, 0)
        warm_gate = next(gate for gate in output["gates"] if gate["gate"] == "PERF-UI-WARM-PREVIEW")
        self.assertEqual(warm_gate["result"], "FAIL")

    def test_incomplete_sample_is_rejected(self):
        baseline = [sample("B", index) for index in range(30)]
        optimized = [sample("O", index, complete=index != 4) for index in range(30)]

        completed, output = self.run_analyzer(baseline, optimized)

        self.assertNotEqual(completed.returncode, 0, output)
        self.assertIn("incomplete sample", completed.stderr)

    def test_fixture_mismatch_is_rejected(self):
        baseline = [sample("B", index, fixture="fixture-a") for index in range(30)]
        optimized = [sample("O", index, fixture="fixture-b") for index in range(30)]

        completed, output = self.run_analyzer(baseline, optimized)

        self.assertNotEqual(completed.returncode, 0, output)
        self.assertIn("fixtureIdentifier mismatch", completed.stderr)

    def test_unexpected_field_is_rejected(self):
        baseline = [sample("B", index) for index in range(30)]
        optimized = [sample("O", index) for index in range(30)]
        optimized[0]["privatePath"] = "/private/example.raw"

        completed, output = self.run_analyzer(baseline, optimized)

        self.assertNotEqual(completed.returncode, 0, output)
        self.assertIn("unexpected privatePath", completed.stderr)


if __name__ == "__main__":
    unittest.main()
