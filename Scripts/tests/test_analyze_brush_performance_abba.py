import json
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
ANALYZER = REPO_ROOT / "Scripts/analyze-brush-performance-abba.py"
SCENARIOS = (
    "cold-first-open-production-preview",
    "warm-unchanged-production-preview",
    "parameter-changed-production-preview",
    "stroke-appended-production-preview",
    "stress-vectors-production-preview",
)
MASK_COUNTS = (0, 1, 10)
BASE_SHA = "a" * 40
OPTIMIZED_SHA = "b" * 40
HARNESS_SHA = "c" * 40
INSTRUMENTATION_DIGEST = "d" * 64


def valid_records(expected_per_round=2):
    records = []
    order = 0
    for scenario in SCENARIOS:
        for mask_count in MASK_COUNTS:
            ordinals = {"B": 0, "O": 0}
            for round_number, pattern in ((1, ("B", "O", "O", "B")), (2, ("O", "B", "B", "O"))):
                for variant in pattern * (expected_per_round // 2):
                    sample_ordinal = ordinals[variant]
                    ordinals[variant] += 1
                    records.append({
                        "schemaVersion": 2,
                        "productSHA": BASE_SHA if variant == "B" else OPTIMIZED_SHA,
                        "harnessSHA": HARNESS_SHA,
                        "instrumentationDigest": INSTRUMENTATION_DIGEST,
                        "configuration": "release",
                        "defines": [],
                        "scenario": scenario,
                        "variant": variant,
                        "round": round_number,
                        "order": order,
                        "sampleOrdinal": sample_ordinal,
                        "seed": "LH-BRUSH-PERF-ACCEPTANCE-20261006",
                        "maskCount": mask_count,
                        "nativeSize": {"width": 1600, "height": 1067},
                        "decodedSize": {"width": 1600, "height": 1067},
                        "outputSize": {"width": 1600, "height": 1067},
                        "recipeIDs": [],
                        "stageDurationsSeconds": {"total": 0.1},
                        "totalDurationSeconds": 0.1,
                        "pixelError": None,
                        "workerCounts": None,
                        "cancelOutcome": None,
                        "rssBytes": 200_000_000,
                        "thermalState": "nominal",
                        "result": "MEASURED",
                        "unavailableReasons": {},
                    })
                    order += 1
    return records


class AnalyzeBrushPerformanceABBATests(unittest.TestCase):
    def run_analyzer(self, records, *, expected_per_round=2):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            samples = root / "samples.jsonl"
            output = root / "gates.json"
            samples.write_text(
                "".join(json.dumps(record) + "\n" for record in records),
                encoding="utf-8",
            )
            command = [
                "python3", str(ANALYZER),
                "--samples", str(samples),
                "--output", str(output),
                "--expected-per-round", str(expected_per_round),
            ]
            for scenario in SCENARIOS:
                command.extend(("--expected-scenario", scenario))
            for mask_count in MASK_COUNTS:
                command.extend(("--expected-mask-count", str(mask_count)))
            completed = subprocess.run(command, text=True, capture_output=True)
            payload = json.loads(output.read_text()) if output.exists() else None
            return completed, payload

    def test_complete_exact_matrix_passes(self):
        completed, payload = self.run_analyzer(valid_records())

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(payload["validation"], "PASS")
        self.assertEqual(payload["recordCount"], 120)

    def test_truncated_matrix_fails(self):
        completed, payload = self.run_analyzer(valid_records()[:16])

        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(payload["validation"], "FAIL")
        self.assertIn("expected 120 records", "\n".join(payload["validationErrors"]))

    def test_wrong_block_order_fails(self):
        records = valid_records()
        records[0]["variant"], records[1]["variant"] = records[1]["variant"], records[0]["variant"]
        records[0]["productSHA"], records[1]["productSHA"] = records[1]["productSHA"], records[0]["productSHA"]

        completed, payload = self.run_analyzer(records)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("variant order", "\n".join(payload["validationErrors"]))

    def test_same_baseline_and_optimized_sha_fails(self):
        records = valid_records()
        for record in records:
            record["productSHA"] = BASE_SHA

        completed, payload = self.run_analyzer(records)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("distinct productSHA", "\n".join(payload["validationErrors"]))

    def test_variant_ordinals_must_match_round_contract(self):
        records = valid_records()
        records[0]["sampleOrdinal"] = 99

        completed, payload = self.run_analyzer(records)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("sampleOrdinal", "\n".join(payload["validationErrors"]))


if __name__ == "__main__":
    unittest.main()
