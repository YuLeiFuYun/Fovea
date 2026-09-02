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
IMAGECRAFT = ROOT.parent / "ImageCraft"
CAPTURE = PERFORMANCE / "capture_w5_apng_public_decoder_mac_performance.py"
VALIDATOR = PERFORMANCE / "validate_w5_apng_public_decoder_mac_performance.py"
ARTIFACTS = ROOT / ".artifacts/performance"


class W5APNGPublicDecoderMacPerformanceTests(unittest.TestCase):
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

    def binary(self) -> pathlib.Path:
        completed = self.run_command(
            [
                "xcrun",
                "swift",
                "build",
                "--package-path",
                str(IMAGECRAFT),
                "--product",
                "ImageCraftEvidence",
                "--show-bin-path",
            ]
        )
        self.assertEqual(completed.returncode, 0, msg=completed.stdout + completed.stderr)
        return pathlib.Path(completed.stdout.strip()) / "ImageCraftEvidence"

    def test_capture_validates_and_tampering_fails_closed(self) -> None:
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix="w5-apng-public-mac-performance-", dir=ARTIFACTS
        ) as temporary:
            output = pathlib.Path(temporary) / "capture"
            completed = self.run_command(
                [
                    sys.executable,
                    str(CAPTURE),
                    "--output",
                    str(output),
                    "--binary",
                    str(self.binary()),
                    "--scenarios",
                    "OWNED-PIA-6",
                    "--iterations",
                    "4",
                    "--warmups",
                    "1",
                ]
            )
            self.assertEqual(completed.returncode, 0, msg=completed.stdout + completed.stderr)
            valid = self.validator(output)
            self.assertEqual(valid.returncode, 0, msg=valid.stdout + valid.stderr)
            report_path = output / "report.json"
            report = json.loads(report_path.read_text())
            self.assertEqual(report["scenarioCount"], 1)
            self.assertEqual(report["iterations"], 4)
            result = report["scenarios"]["OWNED-PIA-6"]["result"]
            self.assertEqual(result["backingDiagnostics"]["backingKind"], "ownedAPNG")
            self.assertTrue(result["selectedFramePixelsExact"])

            original_report = report_path.read_bytes()
            report["iterations"] += 1
            report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
            tampered_report = self.validator(output)
            self.assertNotEqual(tampered_report.returncode, 0)
            self.assertIn(
                "manifest report: identity mismatch",
                tampered_report.stdout + tampered_report.stderr,
            )
            report_path.write_bytes(original_report)

            timing_path = output / "reports/OWNED-PIA-6.json"
            original_timing = timing_path.read_bytes()
            timing = json.loads(timing_path.read_text())
            timing["imageCraftSequentialAllFrames"]["samplesNanoseconds"][0] += 1
            timing_path.write_text(json.dumps(timing, indent=2, sort_keys=True) + "\n")
            tampered_timing = self.validator(output)
            self.assertNotEqual(tampered_timing.returncode, 0)
            self.assertIn(
                "OWNED-PIA-6 timing: identity mismatch",
                tampered_timing.stdout + tampered_timing.stderr,
            )
            timing_path.write_bytes(original_timing)

            manifest_path = output / "capture-manifest.json"
            original_manifest = manifest_path.read_bytes()
            manifest = json.loads(manifest_path.read_text())
            manifest["sourceAfter"]["ImageCraft"]["workingTree"] = "0" * 40
            manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
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
                "unexpected Mac performance root artifact",
                extra_result.stdout + extra_result.stderr,
            )
            extra.unlink()

            final = self.validator(output)
            self.assertEqual(final.returncode, 0, msg=final.stdout + final.stderr)


if __name__ == "__main__":
    unittest.main()
