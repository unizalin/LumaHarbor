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
            ordinals = {"B": 0, "O": 0}
            for round_number, pattern in ((1, ("B", "O", "O", "B")), (2, ("O", "B", "B", "O"))):
                for variant in pattern * (preview_samples // 2):
                    sample_ordinal = ordinals[variant]
                    ordinals[variant] += 1
                    duration = 0.120 if variant == "B" else 0.100
                    rss = 200_000_000 if variant == "B" else 180_000_000
                    records.append({
                        "schemaVersion": 2,
                        "productSHA": BASE_SHA if variant == "B" else OPTIMIZED_SHA,
                        "harnessSHA": HARNESS_SHA,
                        "instrumentationDigest": INSTRUMENTATION_DIGEST,
                        "configuration": "release",
                        "sourceKind": "real-raw",
                        "operation": "preview",
                        "scenario": scenario,
                        "variant": variant,
                        "round": round_number,
                        "order": order,
                        "sampleOrdinal": sample_ordinal,
                        "maskCount": mask_count,
                        "nativeSize": size(6_000, 4_000),
                        "decodedSize": size(1_600, 1_067),
                        "outputSize": size(1_600, 1_067),
                        "totalDurationSeconds": duration,
                        "peakRSSBytes": rss,
                        "contextLifecycle": (
                            "fresh-renderer-context-inside-timer" if scenario == "cold"
                            else "fresh-renderer-context-before-warmup-reused-for-timed-request"
                        ),
                        "contextCreationCountBeforeTimer": 0 if scenario == "cold" else (2 if variant == "B" else 1),
                        "contextCreationCountDuringTimer": 2 if scenario == "cold" and variant == "B" else (1 if variant == "O" and scenario == "cold" else (1 if variant == "B" else 0)),
                        "timingBoundary": "submit-through-materialized-cgimage",
                        "publishedFileValidated": None,
                        "sourceFingerprintUnchanged": True,
                        "thermalState": "nominal",
                        "result": "MEASURED",
                    })
                    order += 1

    for source_kind in ("synthetic-24mp", "real-raw"):
        for mask_count in (1, 10):
            ordinals = {"B": 0, "O": 0}
            for round_number, pattern in ((1, ("B", "O", "O", "B")), (2, ("O", "B", "B", "O"))):
                for variant in pattern * (export_samples // 2):
                    sample_ordinal = ordinals[variant]
                    ordinals[variant] += 1
                    duration = 20.0 if variant == "B" else 8.0
                    rss = 600_000_000 if variant == "B" else 500_000_000
                    records.append({
                        "schemaVersion": 2,
                        "productSHA": BASE_SHA if variant == "B" else OPTIMIZED_SHA,
                        "harnessSHA": HARNESS_SHA,
                        "instrumentationDigest": INSTRUMENTATION_DIGEST,
                        "configuration": "release",
                        "sourceKind": source_kind,
                        "operation": "export",
                        "scenario": "full-resolution",
                        "variant": variant,
                        "round": round_number,
                        "order": order,
                        "sampleOrdinal": sample_ordinal,
                        "maskCount": mask_count,
                        "nativeSize": size(6_000, 4_000),
                        "decodedSize": size(6_000, 4_000),
                        "outputSize": size(6_000, 4_000),
                        "totalDurationSeconds": duration,
                        "peakRSSBytes": rss,
                        "contextLifecycle": "fresh-exporter-context-inside-timer",
                        "contextCreationCountBeforeTimer": 0,
                        "contextCreationCountDuringTimer": 2 if variant == "B" else 1,
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
        self.assertEqual(payload["recordCount"], 352)
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

    def test_reverse_round_is_required(self):
        records = [record for record in valid_records() if record["round"] == 1]

        completed, payload = self.run_analyzer(records)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("expected 352 records", "\n".join(payload["validationErrors"]))

    def test_exact_abba_order_is_required(self):
        records = valid_records()
        records[0]["variant"], records[1]["variant"] = records[1]["variant"], records[0]["variant"]
        records[0]["productSHA"], records[1]["productSHA"] = records[1]["productSHA"], records[0]["productSHA"]

        completed, payload = self.run_analyzer(records)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("variant order", "\n".join(payload["validationErrors"]))

    def test_baseline_and_optimized_sha_must_differ(self):
        records = valid_records()
        for record in records:
            record["productSHA"] = BASE_SHA

        completed, payload = self.run_analyzer(records)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("distinct productSHA", "\n".join(payload["validationErrors"]))

    def test_context_creation_counts_are_required(self):
        records = valid_records()
        del records[0]["contextCreationCountDuringTimer"]

        completed, payload = self.run_analyzer(records)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("missing contextCreationCountDuringTimer", "\n".join(payload["validationErrors"]))

    def assert_rejected(self, records):
        completed, payload = self.run_analyzer(records)
        self.assertNotEqual(completed.returncode, 0)
        self.assertNotIn("Traceback", completed.stderr)
        self.assertIsNotNone(payload)
        self.assertEqual(payload["validation"], "FAIL")
        self.assertFalse(any(g["result"] == "PASS" for g in payload["gates"]))

    def v3_records(self):
        records = valid_records()
        for record in records:
            record["schemaVersion"] = 3
            record["contextCountEvidence"] = "declared-from-construction-path"
            for suffix in ("BeforeTimer", "DuringTimer"):
                record["expectedContextCreationCount" + suffix] = record.pop("contextCreationCount" + suffix)
        return records

    def test_context_evidence_is_explicit_for_both_versions(self):
        for records in (valid_records(), self.v3_records()):
            completed, payload = self.run_analyzer(records)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(payload["contextCountEvidence"], "declared-from-construction-path")
            self.assertIn("not measured", payload["contextCountLimitation"])

    def test_v3_requires_unambiguous_declaration_and_one_version(self):
        for value in (None, False, "measured"):
            records = self.v3_records()
            if value is None:
                del records[0]["contextCountEvidence"]
            else:
                records[0]["contextCountEvidence"] = value
            self.assert_rejected(records)
        records = self.v3_records()
        records[0]["contextCreationCountDuringTimer"] = 2
        self.assert_rejected(records)
        records = self.v3_records()
        records[0] = valid_records()[0]
        self.assert_rejected(records)
        for field in ("expectedContextCreationCountBeforeTimer", "expectedContextCreationCountDuringTimer"):
            for value in (None, True, 2.0, [], 99):
                with self.subTest(field=field, value=value):
                    records = self.v3_records()
                    if value is None:
                        del records[0][field]
                    else:
                        records[0][field] = value
                    self.assert_rejected(records)

    def test_scalar_types_fail_closed(self):
        for field in ("schemaVersion", "round", "maskCount", "order", "sampleOrdinal",
                      "contextCreationCountBeforeTimer", "contextCreationCountDuringTimer"):
            for value in (True, 1.0, [], {}):
                with self.subTest(field=field, value=value):
                    records = valid_records()
                    records[0][field] = value
                    self.assert_rejected(records)
        for field in ("sourceKind", "operation", "scenario", "variant", "contextLifecycle"):
            for value in ([], {}):
                with self.subTest(field=field, value=value):
                    records = valid_records()
                    next(r for r in records if r["operation"] == "export")[field] = value
                    self.assert_rejected(records)

    def test_preview_dimensions_and_fixture_consistency(self):
        for dimensions in ((1, 1), (800, 533), (1600, 800), (1600.0, 1067)):
            with self.subTest(dimensions=dimensions):
                records = valid_records()
                for record in records:
                    if record["operation"] == "preview":
                        record["decodedSize"] = record["outputSize"] = size(*dimensions)
                self.assert_rejected(records)
        records = valid_records()
        records[0]["nativeSize"] = size(12000, 8000)
        self.assert_rejected(records)
        records = valid_records()
        records[0]["decodedSize"] = records[0]["outputSize"] = size(1067, 1600)
        self.assert_rejected(records)

    def test_portrait_preview_and_oriented_export_are_valid(self):
        records = valid_records()
        for record in records:
            if record["operation"] == "preview":
                record["decodedSize"] = record["outputSize"] = size(1067, 1600)
            else:
                record["decodedSize"] = size(4000, 6000)
        completed, payload = self.run_analyzer(records)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(payload["validation"], "PASS")

    def test_synthetic_export_must_be_24mp(self):
        records = valid_records()
        for record in records:
            if record["sourceKind"] == "synthetic-24mp":
                for field in ("nativeSize", "decodedSize", "outputSize"):
                    record[field] = size(3000, 2000)
        self.assert_rejected(records)

    def test_invalid_numeric_measurements_fail_closed(self):
        for field in ("totalDurationSeconds", "peakRSSBytes"):
            for value in (True, [], {}, float("nan"), float("inf"), 10 ** 400):
                with self.subTest(field=field, value=str(value)):
                    records = valid_records()
                    records[0][field] = value
                    self.assert_rejected(records)


if __name__ == "__main__":
    unittest.main()
