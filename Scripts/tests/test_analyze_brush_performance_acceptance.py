import json
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
ANALYZER = REPO_ROOT / "Scripts/analyze-brush-performance-acceptance.py"


def valid_records():
    records = []
    for mask_count in (0, 1, 10):
        durations = [0.001 + mask_count * 0.0001] * 8
        records.append({
            "schemaVersion": 3,
            "scenario": "synthetic-1600px",
            "variant": "O",
            "maskCount": mask_count,
            "width": 1600,
            "height": 1067,
            "strokeCountPerMask": 10,
            "pointCountPerStroke": 100,
            "sampleCount": 8,
            "coverageDurationsSeconds": durations,
            "durationsSeconds": durations,
            "stageDurationsSeconds": {
                "validationSampling": None,
                "coverageRaster": None,
                "coverageIncludingSampling": durations,
                "blendMaterialization": None,
                "totalMaterialized": durations,
            },
            "stageIsolation": {
                "result": "NOT RUN",
                "reason": "shared B/O stage boundaries are unavailable",
            },
            "preferMetal": True,
            "seed": "LH-BRUSH-PERF-ACCEPTANCE-20261006",
        })

    for scenario, p95 in (("preview-cancel", 0.001), ("export-cancel-24mp", 0.002)):
        records.append({
            "schemaVersion": 3,
            "scenario": scenario,
            "variant": "O",
            "sampleCount": 8,
            "durationsSeconds": [p95] * 8,
            "p95Seconds": p95,
            "workerCounts": {"started": 8, "finished": 8, "activeAfterJoin": 0},
            "cancelOutcome": "cancelled-and-joined",
            "timingBoundary": "coverage barrier release through parent and worker join",
            "nonPreemptibleSectionsExcluded": ["raw-decode", "cgimage-destination-encode"],
            "result": "PASS",
        })

    records.append({
        "schemaVersion": 3,
        "scenario": "50-cancel-switch-preview",
        "variant": "O",
        "warmupCycles": 5,
        "measuredCycles": 50,
        "warmPlateauRSSBytes": 100,
        "settledRSSBytes": 110,
        "rssLimitBytes": 100 + 32 * 1024 * 1024,
        "workerCounts": {"started": 55, "finished": 55, "activeAfterJoin": 0},
        "schedulerCounts": {"deliveredB": 55, "discardedA": 55, "failed": 0},
        "mappingChecks": 55,
        "histogramChecks": 55,
        "cancelOutcome": "all-cancelled-and-joined",
        "result": "PASS",
    })
    return records


class AnalyzeBrushPerformanceAcceptanceTests(unittest.TestCase):
    def run_analyzer(self, records, *, corrupt_line=None, product_sha="a" * 40):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            input_path = root / "input.log"
            output_path = root / "output.json"
            lines = ["XCTest diagnostic line"] + [json.dumps(record) for record in records]
            if corrupt_line is not None:
                lines.insert(2, corrupt_line)
            input_path.write_text("\n".join(lines) + "\n")
            completed = subprocess.run(
                [
                    "python3", str(ANALYZER),
                    "--input", str(input_path),
                    "--output", str(output_path),
                    "--product-sha", product_sha,
                    "--harness-sha", "b" * 40,
                    "--expected-samples", "8",
                ],
                text=True,
                capture_output=True,
            )
            output = json.loads(output_path.read_text()) if output_path.exists() else None
            return completed, output

    def test_valid_log_emits_recomputable_allowlist_artifact(self):
        completed, output = self.run_analyzer(valid_records())

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(output["result"], "DONE_WITH_CONCERNS")
        self.assertEqual(len(output["records"]), 6)
        self.assertEqual(
            {gate["gate"]: gate["result"] for gate in output["gates"]},
            {
                "PERF-COVERAGE": "NOT RUN",
                "PERF-CANCEL": "PASS",
                "PERF-MEM-50-CANCEL": "PASS",
            },
        )

    def test_missing_required_record_field_is_rejected(self):
        records = valid_records()
        del records[3]["timingBoundary"]

        completed, output = self.run_analyzer(records)

        self.assertNotEqual(completed.returncode, 0, output)
        self.assertIn("missing timingBoundary", completed.stderr)

    def test_unexpected_record_field_is_rejected_instead_of_silently_dropped(self):
        records = valid_records()
        records[4]["privatePath"] = "/private/example.raw"

        completed, output = self.run_analyzer(records)

        self.assertNotEqual(completed.returncode, 0, output)
        self.assertIn("unexpected privatePath", completed.stderr)

    def test_corrupt_json_record_is_rejected_instead_of_skipped(self):
        completed, output = self.run_analyzer(
            valid_records(),
            corrupt_line='{"schemaVersion":3,"scenario":"preview-cancel"',
        )

        self.assertNotEqual(completed.returncode, 0, output)
        self.assertIn("invalid JSON record", completed.stderr)

    def test_noncanonical_product_sha_is_rejected(self):
        completed, output = self.run_analyzer(valid_records(), product_sha="abc1234")

        self.assertNotEqual(completed.returncode, 0, output)
        self.assertIn("product-sha must be a 40-character lowercase hex commit", completed.stderr)

    def test_nonfinite_duration_is_rejected(self):
        records = valid_records()
        records[0]["durationsSeconds"][0] = float("nan")

        completed, output = self.run_analyzer(records)

        self.assertNotEqual(completed.returncode, 0, output)
        self.assertIn("contains an invalid duration", completed.stderr)


if __name__ == "__main__":
    unittest.main()
