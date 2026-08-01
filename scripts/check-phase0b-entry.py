#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATUS = ROOT / "docs/phase0b-status.json"
LOCK = ROOT / "docs/research/comparator-lock.json"
ARTIFACT = ROOT / ".artifacts/phase0b/entry-status.json"
REQUIRED_BLOCKERS = {
    "P0B-COMP-ADAPTERS",
    "P0B-DEVICE-PRIMARY",
    "P0B-DEVICE-SECONDARY",
    "P0B-FORMAL-W1-W2-W3",
    "P0B-STABLE-OS-REPLICATION",
    "P0B-TRUSTED-EVIDENCE",
    "P0B-INDEPENDENT-REVIEW",
    "P0B-GRADUATION-REPORT",
}
FORBIDDEN_DEVICE_KEYS = {
    "identifier",
    "udid",
    "serialNumber",
    "deviceName",
    "hostname",
    "appleID",
    "account",
}


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(f"unable to read {path.relative_to(ROOT)}: {error}")
    if not isinstance(value, dict):
        fail(f"{path.relative_to(ROOT)} must contain a JSON object")
    return value


def walk_keys(value: object) -> set[str]:
    keys: set[str] = set()
    if isinstance(value, dict):
        for key, child in value.items():
            keys.add(str(key))
            keys.update(walk_keys(child))
    elif isinstance(value, list):
        for child in value:
            keys.update(walk_keys(child))
    return keys


def main() -> int:
    status = read_json(STATUS)
    if status.get("schemaVersion") != 1:
        fail("phase0b status schemaVersion must be 1")
    if status.get("currentStage") != "phase0b-closeout":
        fail("currentStage must remain phase0b-closeout until graduation")
    if status.get("phase1PreparationAllowed") is not True:
        fail("phase1 preparation should be explicitly allowed")
    if status.get("phase1DeclarationAllowed") is not False:
        fail("phase1 declaration must remain false before graduation")

    blockers = status.get("blockers")
    if not isinstance(blockers, list):
        fail("phase0b blockers must be a list")
    blocker_ids = {item.get("id") for item in blockers if isinstance(item, dict)}
    missing_blockers = REQUIRED_BLOCKERS - blocker_ids
    if missing_blockers:
        fail(f"phase0b status is missing blockers: {sorted(missing_blockers)}")
    for blocker in blockers:
        if not isinstance(blocker, dict):
            fail("each phase0b blocker must be an object")
        if not isinstance(blocker.get("summary"), str) or len(blocker["summary"].strip()) < 20:
            fail(f"blocker {blocker.get('id')} needs a substantive summary")
        if blocker.get("status") in {"passed", "complete", "graduated"}:
            fail(f"unresolved blocker {blocker.get('id')} cannot be marked complete")

    lock = read_json(LOCK)
    if lock.get("schemaVersion") != 1:
        fail("comparator lock schemaVersion must be 1")
    comparators = lock.get("comparators")
    if not isinstance(comparators, list) or len(comparators) != 5:
        fail("comparator lock must contain four A-tier Git loaders and one B-tier retained loader")
    by_name = {item.get("name"): item for item in comparators if isinstance(item, dict)}
    expected = {
        "Nuke": ("13.0.6", "required", "A"),
        "Kingfisher": ("8.11.0", "required", "A"),
        "SDWebImage": ("5.21.7", "required", "A"),
        "PINRemoteImage": ("releases/p14.31", "required", "A"),
        "AlamofireImage": ("4.4.0", "required", "B"),
    }
    for name, (tag, role, tier) in expected.items():
        item = by_name.get(name)
        if item is None:
            fail(f"missing comparator lock for {name}")
        if item.get("tag") != tag or item.get("phase0bRole") != role or item.get("researchTier") != tier:
            fail(f"unexpected comparator tag, role or research tier for {name}")
        if not re.fullmatch(r"[0-9a-f]{40}", str(item.get("exactCommit", ""))):
            fail(f"{name} comparator must use a full 40-character commit")
        repository = item.get("repository")
        if not isinstance(repository, str) or not repository.startswith("https://github.com/"):
            fail(f"{name} comparator repository must be an HTTPS GitHub URL")
    matrix = lock.get("matrixPolicy", {})
    expected_a_tier = [
        "Apple URLSession + URLCache + ImageIO", "Apple AsyncImage", "Nuke", "Kingfisher",
        "SDWebImage", "PINRemoteImage", "Fovea",
    ]
    if matrix.get("aTierUnifiedApp") != expected_a_tier:
        fail("A-tier unified app matrix is incomplete or reordered")
    if matrix.get("bTierRetained") != ["AlamofireImage"]:
        fail("AlamofireImage must remain B-tier retained")
    project = (ROOT / "Benchmarks/ComparativeLab/Apps/project.yml").read_text()
    for token in (
        "AppleNativeComparatorBench:",
        "AsyncImageComparatorBench:",
        "FoveaSwiftUIComparatorBench:",
        "PINRemoteImageComparatorBench:",
    ):
        if token not in project:
            fail(f"unified app project is missing {token}")
    for relative in (
        "Benchmarks/AsyncImageLab/experiment-plan.json",
        "Benchmarks/AsyncImageLab/applicability.json",
    ):
        if not (ROOT / relative).is_file():
            fail(f"missing AsyncImage evidence contract: {relative}")

    profiles = status.get("deviceProfiles")
    if not isinstance(profiles, list) or len(profiles) != 1:
        fail("exactly one currently available physical device profile must be declared")
    device_path = ROOT / profiles[0]
    device = read_json(device_path)
    if device.get("schemaVersion") != 1:
        fail("device profile schemaVersion must be 1")
    if device.get("role") != "primary-current-mid":
        fail("iPhone 16e must be classified as primary-current-mid, not lower-performance")
    hardware = device.get("hardware", {})
    os_info = device.get("operatingSystem", {})
    privacy = device.get("privacy", {})
    if hardware.get("marketingName") != "iPhone 16e" or hardware.get("reality") != "physical":
        fail("device profile must describe a physical iPhone 16e")
    if os_info.get("family") != "iOS" or not str(os_info.get("version", "")).startswith("27"):
        fail("device profile must describe iOS 27")
    if os_info.get("channel") != "beta":
        fail("the current device profile must label iOS 27 as beta")
    if privacy.get("uniqueIdentifiersStored") is not False or privacy.get("deviceNameStored") is not False:
        fail("device profile must explicitly reject unique identifiers and device names")
    leaked_keys = walk_keys(device) & FORBIDDEN_DEVICE_KEYS
    if leaked_keys:
        fail(f"device profile contains forbidden identity keys: {sorted(leaked_keys)}")

    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    artifact = {
        "blockerIDs": sorted(blocker_ids),
        "gitComparatorCount": len(comparators),
        "aTierComparatorCount": 7,
        "bTierComparatorCount": 1,
        "currentStage": status["currentStage"],
        "deviceCaptureStatus": device.get("captureStatus"),
        "deviceProfileID": device.get("profileID"),
        "phase1DeclarationAllowed": False,
        "phase1PreparationAllowed": True,
        "schemaVersion": 1,
        "status": "passed",
    }
    ARTIFACT.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n")
    print(
        "Phase entry gate passed: preparation allowed, declaration blocked, "
        f"aTier=7 gitComparators={len(comparators)} blockers={len(blocker_ids)}"
    )
    print(f"Artifact: {ARTIFACT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
