#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    fixture = {
        "result": {
            "devices": [
                {
                    "identifier": "DO-NOT-EXPORT",
                    "deviceProperties": {
                        "name": "Private Device Name",
                        "osBuildUpdate": "24A5355p",
                        "osVersionNumber": "27.0",
                    },
                    "hardwareProperties": {
                        "marketingName": "iPhone 16e",
                        "productType": "iPhone17,5",
                        "reality": "physical",
                        "udid": "DO-NOT-EXPORT",
                    },
                }
            ]
        }
    }
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        input_path = root / "devices.json"
        output_path = root / "profile.json"
        input_path.write_text(json.dumps(fixture))
        subprocess.run(
            [
                "python3",
                str(ROOT / "scripts/capture-ios-device-profile.py"),
                "--input-json",
                str(input_path),
                "--output",
                str(output_path),
            ],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        data = output_path.read_text()
        profile = json.loads(data)
        assert profile["captureStatus"] == "captured"
        assert profile["hardware"]["marketingName"] == "iPhone 16e"
        assert profile["hardware"]["productType"] == "iPhone17,5"
        assert profile["operatingSystem"]["build"] == "24A5355p"
        assert "DO-NOT-EXPORT" not in data
        assert "Private Device Name" not in data
        def keys(value):
            if isinstance(value, dict):
                result = set(value)
                for child in value.values():
                    result.update(keys(child))
                return result
            if isinstance(value, list):
                result = set()
                for child in value:
                    result.update(keys(child))
                return result
            return set()
        assert not ({"identifier", "udid", "deviceName", "serialNumber"} & keys(profile))
    print("Phase 0b device capture tests passed: physical selection and identity redaction")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
