#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATASET = ROOT / ".artifacts/comparative-dataset"
DESTINATION = ROOT / "Benchmarks/ComparativeLab/Apps/GeneratedResources"
HEROES = ROOT / "Sources/FoveaTesting/Fixtures"
DEVICE = ROOT / ".artifacts/phase0b/device-profile.json"
PROBES = ROOT / "Benchmarks/ComparativeLab/Fixtures/correctness-probes.json"
PROGRESSIVE = HEROES / "progressive-people-usda-meeting-1920x1280.jpg"


def main() -> int:
    manifest = DATASET / "captured-dataset.json"
    if not manifest.is_file():
        print("captured comparative dataset is incomplete", file=sys.stderr)
        return 1
    data = json.loads(manifest.read_text())
    if data.get("assetCount") != 128:
        print("captured comparative dataset does not contain 128 assets", file=sys.stderr)
        return 1
    if not DEVICE.is_file():
        print("sanitized device profile is missing", file=sys.stderr)
        return 1
    staging = DESTINATION.with_name(DESTINATION.name + ".tmp")
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    shutil.copy2(manifest, staging / "captured-dataset.json")
    shutil.copytree(DATASET / "assets", staging / "assets")
    heroes = staging / "heroes"
    heroes.mkdir()
    for name in [
        "hero-12mp-4000x3000.jpg",
        "hero-24mp-6000x4000.jpg",
        "hero-48mp-8000x6000.jpg",
    ]:
        shutil.copy2(HEROES / name, heroes / name)
    probe_manifest = json.loads(PROBES.read_text())
    if probe_manifest.get("schemaVersion") != 1 or not probe_manifest.get("probes"):
        print("comparative correctness probe manifest is invalid", file=sys.stderr)
        return 1
    probe_directory = staging / "probes"
    probe_directory.mkdir()
    for probe in probe_manifest["probes"]:
        source = PROBES.parent / probe["sourceFile"]
        payload = source.read_bytes()
        digest = hashlib.sha256(payload).hexdigest()
        if digest != probe["sha256"]:
            print(f"correctness probe digest mismatch: {probe['identifier']}", file=sys.stderr)
            return 1
        shutil.copy2(source, probe_directory / probe["resourceName"])
    shutil.copy2(PROBES, staging / "correctness-probes.json")
    shutil.copy2(DEVICE, staging / "device-profile.json")
    progressive_payload = PROGRESSIVE.read_bytes()
    progressive_name = "w4-progressive-1920x1280.jpg"
    (staging / progressive_name).write_bytes(progressive_payload)
    metadata = {
        "schemaVersion": 1,
        "datasetDigest": data["datasetDigest"],
        "datasetAssetCount": data["assetCount"],
        "heroCount": 3,
        "correctnessProbeCount": len(probe_manifest["probes"]),
        "deviceProfileID": json.loads(DEVICE.read_text())["profileID"],
        "progressiveFixture": {
            "name": progressive_name,
            "byteCount": len(progressive_payload),
            "sha256": hashlib.sha256(progressive_payload).hexdigest(),
        },
    }
    (staging / "resource-bundle.json").write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n"
    )
    shutil.rmtree(DESTINATION, ignore_errors=True)
    staging.rename(DESTINATION)
    print(
        "Comparative app resources prepared: "
        f"assets={data['assetCount']} dataset={data['datasetDigest']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
