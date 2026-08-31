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
CAPTURE = PERFORMANCE / "capture_w5_apng_checkpoint_model.py"
VALIDATOR = PERFORMANCE / "validate_w5_apng_checkpoint_model.py"
PLAN = ROOT / "Benchmarks/ComparativeLab/apng-checkpoint-plan.json"
ARTIFACTS = ROOT / ".artifacts/performance"


class W5APNGCheckpointCaptureTests(unittest.TestCase):
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

    def write_reduced_plan(self, path: pathlib.Path) -> None:
        plan = json.loads(PLAN.read_text())
        fixture_ids = {"FULL-NONE", "SUBRECT-NONE"}
        scenario_ids = {"FULL-1024-60", "SUBRECT-NONE-1024-60"}
        plan["sourceFixtures"] = [
            item for item in plan["sourceFixtures"] if item["id"] in fixture_ids
        ]
        plan["syntheticScenarios"] = [
            item for item in plan["syntheticScenarios"] if item["id"] in scenario_ids
        ]
        plan["retainedBudgetMiB"] = [32]
        plan["maximumReplayFrames"] = [8]
        path.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")

    def test_capture_validates_and_tampering_fails_closed(self) -> None:
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix="w5-apng-checkpoint-contract-", dir=ARTIFACTS
        ) as temporary:
            root = pathlib.Path(temporary)
            plan_path = root / "contract-plan.json"
            output = root / "capture"
            self.write_reduced_plan(plan_path)
            completed = self.run_command(
                [
                    sys.executable,
                    str(CAPTURE),
                    "--plan",
                    str(plan_path),
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
            self.assertEqual(summary["matrixCaseCount"], 8)
            self.assertEqual(summary["referencePolicyCaseCount"], 8)
            self.assertGreater(summary["feasibleCaseCount"], 0)
            self.assertGreater(summary["infeasibleCaseCount"], 0)

            original_report = report_path.read_bytes()
            report["analysis"]["summary"]["feasibleCaseCount"] += 1
            report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
            tampered_report = self.validator(output)
            self.assertNotEqual(tampered_report.returncode, 0)
            self.assertIn(
                "manifest report: identity mismatch",
                tampered_report.stdout + tampered_report.stderr,
            )
            report_path.write_bytes(original_report)

            input_path = output / "inputs/SUBRECT-NONE.apng"
            original_input = input_path.read_bytes()
            input_path.write_bytes(original_input + b"x")
            tampered_input = self.validator(output)
            self.assertNotEqual(tampered_input.returncode, 0)
            self.assertIn(
                "SUBRECT-NONE input: identity mismatch",
                tampered_input.stdout + tampered_input.stderr,
            )
            input_path.write_bytes(original_input)

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
                "artifact set mismatch",
                extra_result.stdout + extra_result.stderr,
            )
            extra.unlink()

            final = self.validator(output)
            self.assertEqual(final.returncode, 0, msg=final.stdout + final.stderr)


if __name__ == "__main__":
    unittest.main()
