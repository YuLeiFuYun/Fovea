#!/usr/bin/env python3
from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PERFORMANCE = pathlib.Path(__file__).resolve().parent
VALIDATOR = PERFORMANCE / "validate_w5_apng_imageio_cache_divergence.py"
FORMAL_CAPTURE = ROOT / ".artifacts/performance/w5-apng-imageio-cache-divergence-v1"


class W5APNGImageIOCacheDivergenceTests(unittest.TestCase):
    def run_command(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            command,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def validate(self) -> subprocess.CompletedProcess[str]:
        return self.run_command([sys.executable, str(VALIDATOR), str(FORMAL_CAPTURE)])

    def test_retained_capture_validates_and_tampering_fails_closed(self) -> None:
        self.assertTrue((FORMAL_CAPTURE / "bin/ImageCraftEvidence").is_file())
        valid = self.validate()
        self.assertEqual(valid.returncode, 0, msg=valid.stdout + valid.stderr)

        report_path = FORMAL_CAPTURE / "report.json"
        original_report = report_path.read_bytes()
        report = json.loads(original_report)
        self.assertEqual(report["reverseRandomAccessMismatchCount"], 23)
        try:
            report["reverseRandomAccessMismatchCount"] = 22
            report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
            tampered = self.validate()
            self.assertNotEqual(tampered.returncode, 0)
            self.assertIn("manifest report: identity mismatch", tampered.stdout + tampered.stderr)
        finally:
            report_path.write_bytes(original_report)

        extra = FORMAL_CAPTURE / "unexpected.bin"
        try:
            extra.write_bytes(b"unexpected")
            extra_result = self.validate()
            self.assertNotEqual(extra_result.returncode, 0)
            self.assertIn(
                "unexpected cache divergence root artifact",
                extra_result.stdout + extra_result.stderr,
            )
        finally:
            extra.unlink(missing_ok=True)

        frame = FORMAL_CAPTURE / "playback/frame-012.rgba"
        frame_original = frame.read_bytes()
        try:
            frame.write_bytes(frame_original[:-1] + bytes([frame_original[-1] ^ 0x01]))
            frame_tampered = self.validate()
            self.assertNotEqual(frame_tampered.returncode, 0)
            self.assertIn("cache divergence sequential frame is not reproducible", frame_tampered.stdout + frame_tampered.stderr)
        finally:
            frame.write_bytes(frame_original)

        final = self.validate()
        self.assertEqual(final.returncode, 0, msg=final.stdout + final.stderr)


if __name__ == "__main__":
    unittest.main()
