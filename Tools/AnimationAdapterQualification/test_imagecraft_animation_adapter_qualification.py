#!/usr/bin/env python3
from __future__ import annotations

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
QUALIFICATION = pathlib.Path(__file__).resolve().parent
VALIDATOR = QUALIFICATION / "validate_imagecraft_animation_adapter_qualification.py"
QUALIFIER = QUALIFICATION / "qualify_imagecraft_animation_adapter.py"
CAPTURE = ROOT / ".artifacts/qualification/w5-imagecraft-animation-adapter-current-contract"


class ImageCraftAnimationAdapterQualificationContractTests(unittest.TestCase):
    def qualify(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(QUALIFIER), "--output", str(CAPTURE)],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def validate(self, path: pathlib.Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(VALIDATOR), str(path)],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_capture_validates_and_tampering_fails_closed(self) -> None:
        qualified = self.qualify()
        self.assertEqual(qualified.returncode, 0, msg=qualified.stdout + qualified.stderr)
        valid = self.validate(CAPTURE)
        self.assertEqual(valid.returncode, 0, msg=valid.stdout + valid.stderr)
        with tempfile.TemporaryDirectory(prefix="fovea-adapter-tamper-") as temporary:
            copied = pathlib.Path(temporary) / "capture"
            shutil.copytree(CAPTURE, copied)

            log = copied / "qualification.log"
            original_log = log.read_bytes()
            log.write_bytes(original_log + b"tamper\n")
            changed_log = self.validate(copied)
            self.assertNotEqual(changed_log.returncode, 0)
            self.assertIn("log digest mismatch", changed_log.stdout + changed_log.stderr)
            log.write_bytes(original_log)

            report_path = copied / "report.json"
            report = json.loads(report_path.read_text())
            report["qualification"]["returnCode"] = 1
            report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
            changed_report = self.validate(copied)
            self.assertNotEqual(changed_report.returncode, 0)
            self.assertIn("did not pass", changed_report.stdout + changed_report.stderr)
            shutil.copy2(CAPTURE / "report.json", report_path)

            report = json.loads(report_path.read_text())
            report["componentSourceBindings"]["ImageCraft"]["checkoutHead"] = "0" * 40
            report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
            changed_binding = self.validate(copied)
            self.assertNotEqual(changed_binding.returncode, 0)
            self.assertIn("checkout revision mismatch", changed_binding.stdout + changed_binding.stderr)
            shutil.copy2(CAPTURE / "report.json", report_path)

            extra = copied / "unexpected.bin"
            extra.write_bytes(b"unexpected")
            extra_result = self.validate(copied)
            self.assertNotEqual(extra_result.returncode, 0)
            self.assertIn("unexpected adapter qualification artifacts", extra_result.stdout + extra_result.stderr)
            extra.unlink()

            final = self.validate(copied)
            self.assertEqual(final.returncode, 0, msg=final.stdout + final.stderr)


if __name__ == "__main__":
    unittest.main()
