#!/usr/bin/env python3
from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PERFORMANCE = pathlib.Path(__file__).resolve().parent
CAPTURE = PERFORMANCE / "capture_w5_apng_compressed_checkpoint_model.py"
VALIDATOR = PERFORMANCE / "validate_w5_apng_compressed_checkpoint_model.py"
BASE_PLAN = ROOT / "Benchmarks/ComparativeLab/apng-checkpoint-plan.json"
COMPRESSED_PLAN = ROOT / "Benchmarks/ComparativeLab/apng-compressed-checkpoint-plan.json"
ARTIFACTS = ROOT / ".artifacts/performance"


class W5APNGCompressedCheckpointCaptureTests(unittest.TestCase):
    def run_command(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            command,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def validator(self, output: pathlib.Path) -> subprocess.CompletedProcess[str]:
        return self.run_command([sys.executable, str(VALIDATOR), str(output)])

    def write_reduced_base_plan(self, path: pathlib.Path) -> None:
        plan = json.loads(BASE_PLAN.read_text())
        fixture_ids = {"FULL-NONE", "EXTREME-SPARSE"}
        scenario_ids = {"FULL-1024-60", "SPARSE-2048-256"}
        plan["sourceFixtures"] = [
            item for item in plan["sourceFixtures"] if item["id"] in fixture_ids
        ]
        plan["syntheticScenarios"] = [
            item for item in plan["syntheticScenarios"] if item["id"] in scenario_ids
        ]
        for scenario in plan["syntheticScenarios"]:
            scenario["frameCount"] = 8 if scenario["id"] == "FULL-1024-60" else 16
        plan["retainedBudgetMiB"] = [32, 64]
        plan["maximumReplayFrames"] = [8]
        path.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")

    def write_reduced_compressed_plan(self, path: pathlib.Path) -> None:
        plan = json.loads(COMPRESSED_PLAN.read_text())
        plan["checkpointBlobRatioPPM"] = [10000, 100000, 1000000]
        path.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")

    def test_capture_validates_and_tampering_fails_closed(self) -> None:
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix="w5-apng-compressed-contract-", dir=ARTIFACTS
        ) as temporary:
            root = pathlib.Path(temporary)
            base_plan = root / "base-plan-input.json"
            compressed_plan = root / "compressed-plan-input.json"
            output = root / "capture"
            self.write_reduced_base_plan(base_plan)
            self.write_reduced_compressed_plan(compressed_plan)
            completed = self.run_command(
                [
                    sys.executable,
                    str(CAPTURE),
                    "--base-plan",
                    str(base_plan),
                    "--compressed-plan",
                    str(compressed_plan),
                    "--output",
                    str(output),
                ]
            )
            self.assertEqual(
                completed.returncode,
                0,
                msg=completed.stdout + completed.stderr,
            )
            valid = self.validator(output)
            self.assertEqual(valid.returncode, 0, msg=valid.stdout + valid.stderr)
            report_path = output / "report.json"
            report = json.loads(report_path.read_text())
            summary = report["analysis"]["summary"]
            self.assertEqual(summary["matrixCaseCount"], 48)
            self.assertEqual(summary["referencePolicyCaseCount"], 24)
            self.assertGreater(summary["retainedFeasibleCaseCount"], 0)
            self.assertIs(summary["referencePolicyGlobalOptimalityClaim"], False)
            self.assertGreater(
                report["nativeCheckpointRoundTrip"]["checkpointBlobCount"], 0
            )

            original_report = report_path.read_bytes()
            report["analysis"]["summary"]["retainedFeasibleCaseCount"] += 1
            report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
            tampered_report = self.validator(output)
            self.assertNotEqual(tampered_report.returncode, 0)
            self.assertIn(
                "manifest report: identity mismatch",
                tampered_report.stdout + tampered_report.stderr,
            )
            report_path.write_bytes(original_report)

            blob_path = next((output / "checkpoints").glob("*.fapc"))
            original_blob = blob_path.read_bytes()
            altered = bytearray(original_blob)
            altered[-1] ^= 1
            blob_path.write_bytes(altered)
            tampered_blob = self.validator(output)
            self.assertNotEqual(tampered_blob.returncode, 0)
            self.assertIn(
                "checkpoint",
                tampered_blob.stdout + tampered_blob.stderr,
            )
            blob_path.write_bytes(original_blob)

            manifest_path = output / "capture-manifest.json"
            original_manifest = manifest_path.read_bytes()
            manifest = json.loads(manifest_path.read_text())
            manifest["sourceAfter"]["Fovea"]["workingTree"] = "0" * 40
            manifest_path.write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n"
            )
            tampered_source = self.validator(output)
            self.assertNotEqual(tampered_source.returncode, 0)
            self.assertIn(
                "source before/after mismatch",
                tampered_source.stdout + tampered_source.stderr,
            )
            manifest_path.write_bytes(original_manifest)

            extra = output / "unexpected.bin"
            extra.write_bytes(b"unexpected")
            extra_result = self.validator(output)
            self.assertNotEqual(extra_result.returncode, 0)
            self.assertIn(
                "unexpected root artifact",
                extra_result.stdout + extra_result.stderr,
            )
            extra.unlink()

            final = self.validator(output)
            self.assertEqual(final.returncode, 0, msg=final.stdout + final.stderr)


if __name__ == "__main__":
    unittest.main()
