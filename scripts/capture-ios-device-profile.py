#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "Benchmarks/ComparativeLab/device-profiles/iphone-16e-ios27-beta.json"


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def load_devices(input_path: Path | None) -> list[dict]:
    if input_path is not None:
        payload = json.loads(input_path.read_text())
    else:
        with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as handle:
            output = Path(handle.name)
        try:
            command = ["xcrun", "devicectl", "list", "devices", "--json-output", str(output)]
            result = subprocess.run(command, check=False, capture_output=True, text=True)
            if result.returncode != 0:
                fail(f"devicectl failed: {result.stderr.strip() or result.stdout.strip()}")
            payload = json.loads(output.read_text())
        finally:
            output.unlink(missing_ok=True)
    devices = payload.get("result", {}).get("devices")
    if not isinstance(devices, list):
        fail("devicectl JSON did not contain result.devices")
    return [item for item in devices if isinstance(item, dict)]


def physical_candidates(devices: list[dict], expected_model: str) -> list[dict]:
    result: list[dict] = []
    for device in devices:
        hardware = device.get("hardwareProperties", {})
        if hardware.get("reality") != "physical":
            continue
        if hardware.get("marketingName") != expected_model:
            continue
        result.append(device)
    return result


def sanitized_profile(device: dict, channel: str) -> dict:
    hardware = device.get("hardwareProperties", {})
    software = device.get("deviceProperties", {})
    version = str(software.get("osVersionNumber") or "")
    build = software.get("osBuildUpdate")
    marketing_name = hardware.get("marketingName")
    product_type = hardware.get("productType")
    if marketing_name != "iPhone 16e":
        fail(f"expected iPhone 16e, found {marketing_name!r}")
    if not version.startswith("27"):
        fail(f"expected iOS 27, found {version!r}")
    if not isinstance(product_type, str) or not product_type.startswith("iPhone"):
        fail("physical device did not expose a valid iPhone product type")
    if not isinstance(build, str) or not build:
        fail("physical device did not expose an OS build")

    return {
        "captureStatus": "captured",
        "capturedOn": dt.date.today().isoformat(),
        "hardware": {
            "chip": "A18",
            "displayPixels": {"height": 2532, "width": 1170},
            "gpuCoreCount": 4,
            "marketingName": marketing_name,
            "productType": product_type,
            "reality": "physical",
        },
        "operatingSystem": {
            "build": build,
            "channel": channel,
            "family": "iOS",
            "version": version,
        },
        "privacy": {
            "deviceNameStored": False,
            "uniqueIdentifiersStored": False,
        },
        "profileID": "iphone-16e-ios27-beta-primary-v1",
        "role": "primary-current-mid",
        "schemaVersion": 1,
        "source": {
            "deviceFacts": "sanitized xcrun devicectl capture",
            "hardwareReference": "Apple iPhone 16e technical specifications",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Capture a sanitized physical iPhone benchmark profile without UDID or device name."
    )
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--input-json", type=Path, help="Use saved devicectl JSON for testing.")
    parser.add_argument("--channel", choices=("beta", "stable"), default="beta")
    args = parser.parse_args()

    devices = load_devices(args.input_json)
    candidates = physical_candidates(devices, "iPhone 16e")
    if not candidates:
        fail(
            "No connected physical iPhone 16e was found. Unlock the phone, trust this Mac, "
            "enable Developer Mode, and connect it by USB or paired network debugging."
        )
    if len(candidates) > 1:
        fail("Multiple physical iPhone 16e devices are connected; disconnect all but the benchmark device.")

    profile = sanitized_profile(candidates[0], args.channel)
    output = args.output if args.output.is_absolute() else ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(profile, indent=2, sort_keys=True) + "\n")
    try:
        display_path = output.relative_to(ROOT)
    except ValueError:
        display_path = output
    print(f"Sanitized device profile written: {display_path}")
    print("Stored identity fields: none")
    return 0


if __name__ == "__main__":
    os.chdir(ROOT)
    raise SystemExit(main())
