#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
from pathlib import Path

from ios_example_process import command_output, workspace_tree

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / ".artifacts/verification/qualification-certificate.json"
ARTIFACT_ROOT = (ROOT / ".artifacts/verification/qualification-runs").resolve()
REQUIRED_ASSURANCES = {
    "deterministic-workbench-complete",
    "component-clean-copy",
    "component-rollback-forward-recovery",
    "production-coverage",
    "release-build",
    "thread-sanitizer",
    "address-sanitizer",
    "ios-simulator-package-tests",
    "critical-mutation-suite",
}


def digest(path: Path) -> str | None:
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def main() -> int:
    if os.environ.get("FOVEA_QUALIFICATION_ACTIVE") != "1":
        raise SystemExit(
            "qualification certificate writer may only run from the qualification profile"
        )
    run_id = os.environ.get("FOVEA_QUALIFICATION_RUN_ID", "").strip()
    if not run_id:
        raise SystemExit("qualification run identifier is missing")
    session_text = os.environ.get("FOVEA_QUALIFICATION_SESSION_DIR", "").strip()
    session = Path(session_text).resolve() if session_text else Path()
    expected_session = (ARTIFACT_ROOT / run_id).resolve()
    if session != expected_session or not session.is_dir():
        raise SystemExit("qualification session directory is missing or invalid")
    try:
        started_epoch = int(os.environ.get("FOVEA_QUALIFICATION_STARTED_EPOCH", ""))
    except ValueError as error:
        raise SystemExit("qualification start epoch is invalid") from error

    tree, dirty = workspace_tree()
    receipt_digests: dict[str, str] = {}
    for assurance in sorted(REQUIRED_ASSURANCES):
        path = session / f"{assurance}.json"
        try:
            receipt = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise SystemExit(f"qualification receipt is missing or invalid: {assurance}") from error
        expected = {
            "schemaVersion": 1,
            "status": "passed",
            "qualificationRunID": run_id,
            "assurance": assurance,
            "qualificationStartedEpoch": started_epoch,
            "verifiedTree": tree,
        }
        mismatches = [key for key, value in expected.items() if receipt.get(key) != value]
        if mismatches or int(receipt.get("recordedEpoch", -1)) < started_epoch:
            raise SystemExit(
                f"qualification receipt does not belong to this run/tree: {assurance}"
            )
        receipt_digests[assurance] = hashlib.sha256(path.read_bytes()).hexdigest()

    payload = {
        "schemaVersion": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "status": "passed",
        "qualificationRunID": run_id,
        "qualificationStartedEpoch": started_epoch,
        "verifiedTree": tree,
        "includesWorkingTreeChanges": dirty,
        "verifiedCommit": command_output(["git", "rev-parse", "HEAD"]),
        "xcodeVersion": command_output(["xcodebuild", "-version"], env=os.environ.copy()),
        "swiftVersion": command_output(["xcrun", "swift", "--version"], env=os.environ.copy()),
        "packageResolvedSha256": digest(ROOT / "Package.resolved"),
        "componentPinsSha256": digest(ROOT / "docs/project-memory/component-pins.json"),
        "assurances": sorted(REQUIRED_ASSURANCES),
        "assuranceReceiptSha256": receipt_digests,
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(f"Qualification certificate written: {OUTPUT.relative_to(ROOT)} tree={tree}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
