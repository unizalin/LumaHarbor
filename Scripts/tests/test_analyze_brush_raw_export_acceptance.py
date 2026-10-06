import json
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
ANALYZER = REPO_ROOT / "Scripts/analyze-brush-raw-export-acceptance.py"
BASE_SHA = "a" * 40
OPTIMIZED_SHA = "b" * 40
HARNESS_SHA = "c" * 40
INSTRUMENTATION_DIGEST = "d" * 64


def size(width, height):
    return {"width": width, "height": height}


def valid_records(preview_samples=8, export_samples=4):
    records = []
    order = 0
    for scenario in ("cold", "warm", "changed"):
        for mask_count in (0, 1, 10):
            for variant, duration, rss in (
                ("B", 0.120, 200_000_000),
                ("O", 0.100, 180_000_000),
            ):
                for sample_ordinal in range(preview_samples):
                    records.append({
                        "schemaVersion": 1,
                        "productSHA": BASE_SHA if variant == "B" else OPTIMIZED_SHA,
                        "harnessSHA": HARNESS_SHA,
                        "instrumentationDigest": INSTRUMENTATION_DIGEST,
                        "configuration": "release",
                        "sourceKind": "real-raw",
                        "operation": "preview",
                        "scenario": scenario,
                        "variant": variant,
                        "order": order,
                        "sampleOrdinal": sample_ordinal,
                        "maskCount": mask_count,
                        "nativeSize": size(6_000, 4_000),
                        "decodedSize": size(1_600, 1_067),
                        "outputSize": size(1_600, 1_067),
                        "totalDurationSeconds": duration,
                        "peakRSSBytes": rss,
                        "timingBoundary": "submit-through-materialized-cgimage",
                        "publishedFileValidated": None,
                        "sourceFingerprintUnchanged": True,
                        "thermalState": "nominal",
                        "result": "MEASURED",
                    })
                    order += 1

    for source_kind in ("synthetic-24mp", "real-raw"):
        for mask_count in (1, 10):
            for variant, duration, rss in (
                ("B", 20.0, 600_000_000),
                ("O", 8.0, 500_000_000),
            ):
                for sample_ordinal in range(export_samples):
                    records.append({
                        "schemaVersion": 1,
                        "productSHA": BASE_SHA if variant == "B" else OPTIMIZED_SHA,
                        "harnessSHA": HARNESS_SHA,
                        "instrumentationDigest": INSTRUMENTATION_DIGEST,
                        "configuration": "release",
                        "sourceKind": source_kind,
                        "operation": "export",
                        "scenario": "full-resolution",
                        "variant": variant,
                        "order": order,
                        "sampleOrdinal": sample_ordinal,
                        "maskCount": mask_count,
                        "nativeSize": size(6_000, 4_000),
                        "decodedSize": size(6_000, 4_000),
                        "outputSize": size(6_000, 4_000),
                        "totalDurationSeconds": duration,
                        "peakRSSBytes": rss,
                        "timingBoundary": "submit-through-export-return-and-published-image-reopen",
                        "publishedFileValidated": True,
                        "sourceFingerprintUnchanged": True,
                        "thermalState": "nominal",
                        "result": "MEASURED",
                    })
                    order += 1
    return records


class AnalyzeBrushRawExportAcceptanceTests(unittest.TestCase):
    def run_analyzer(self, records, *, preview_samples=8, export_samples=4):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            samples = root / "samples.jsonl"
            output = root / "gates.json"
            samples.write_text(
                "".join(json.dumps(record) + "\n" for record in records),
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    "python3",
                    str(ANALYZER),
                    "--samples",
                    str(samples),
                    "--output",
                    str(output),
                    "--expected-preview-samples",
                    str(preview_samples),
                    "--expected-export-samples",
                    str(export_samples),
                ],
                text=True,
                capture_output=True,
            )
            payload = json.loads(output.read_text()) if output.exists() else None
            return completed, payload

    def test_valid_complete_matrix_emits_recomputable_gates(self):
        completed, payload = self.run_analyzer(valid_records())

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(payload["validation"], "PASS")
        self.assertEqual(payload["recordCount"], 176)
        self.assertEqual(
            {gate["gate"] for gate in payload["gates"]},
            {"INTERACTIVE-150", "PERF-MEM-PREVIEW", "PERF-EXPORT", "PERF-MEM-EXPORT"},
        )
        interactive_gates = [
            gate for gate in payload["gates"] if gate["gate"] == "INTERACTIVE-150"
        ]
        self.assertEqual(len(interactive_gates), 3)
        self.assertEqual({gate["scenario"] for gate in interactive_gates}, {"warm"})

    def test_missing_fixture_records_cannot_be_reported_as_pass(self):
        completed, payload = self.run_analyzer([])

        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(payload["validation"], "FAIL")
        self.assertFalse(any(gate["result"] == "PASS" for gate in payload["gates"]))

    def test_downscaled_export_is_rejected(self):
        records = valid_records()
        export = next(record for record in records if record["operation"] == "export")
        export["outputSize"] = size(1_600, 1_067)

        completed, payload = self.run_analyzer(records)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("full-resolution export size mismatch", "\n".join(payload["validationErrors"]))

    def test_export_timer_must_include_publish_and_reopen_validation(self):
        records = valid_records()
        export = next(record for record in records if record["operation"] == "export")
        export["publishedFileValidated"] = False

        completed, payload = self.run_analyzer(records)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("published output was not validated", "\n".join(payload["validationErrors"]))

    def test_unexpected_private_path_is_rejected(self):
        records = valid_records()
        records[0]["privatePath"] = "/private/example.raw"

        completed, payload = self.run_analyzer(records)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("unexpected privatePath", "\n".join(payload["validationErrors"]))

    def test_noncanonical_product_sha_is_rejected(self):
        records = valid_records()
        records[0]["productSHA"] = "abc1234"

        completed, payload = self.run_analyzer(records)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(
            "productSHA must be a full lowercase commit",
            "\n".join(payload["validationErrors"]),
        )

    def test_compound_values_fail_closed_without_crashing(self):
        records = valid_records()
        records[0]["productSHA"] = ["not", "a", "sha"]
        records[1]["scenario"] = {"unexpected": "object"}

        completed, payload = self.run_analyzer(records)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIsNotNone(payload)
        self.assertEqual(payload["validation"], "FAIL")
        self.assertIn(
            "productSHA must be a full lowercase commit",
            "\n".join(payload["validationErrors"]),
        )

    def test_real_raw_export_rss_has_no_24mp_absolute_cap(self):
        records = valid_records()
        for record in records:
            if record["operation"] == "export" and record["sourceKind"] == "real-raw":
                record["peakRSSBytes"] = (
                    900 * 1024 * 1024 if record["variant"] == "B" else 800 * 1024 * 1024
                )

        completed, payload = self.run_analyzer(records)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        real_raw_memory_gates = [
            gate for gate in payload["gates"]
            if gate["gate"] == "PERF-MEM-EXPORT" and gate["sourceKind"] == "real-raw"
        ]
        self.assertEqual(len(real_raw_memory_gates), 2)
        self.assertTrue(all(gate["result"] == "PASS" for gate in real_raw_memory_gates))
        self.assertTrue(all(gate["absoluteLimitBytes"] is None for gate in real_raw_memory_gates))


if __name__ == "__main__":
    unittest.main()
