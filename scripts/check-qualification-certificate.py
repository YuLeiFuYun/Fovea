#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from pathlib import Path

from ios_example_process import command_output, workspace_tree

ROOT = Path(__file__).resolve().parents[1]
CERTIFICATE = ROOT / ".artifacts/verification/qualification-certificate.json"
ARTIFACT_ROOT = (ROOT / ".artifacts/verification/qualification-runs").resolve()
RUN_ID = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9]+$")


def digest(path: Path) -> str | None:
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def main() -> int:
    try:
        data = json.loads(CERTIFICATE.read_text())
        tree, _dirty = workspace_tree()
        expected = {
            "verifiedTree": tree,
            "xcodeVersion": command_output(["xcodebuild", "-version"], env=os.environ.copy()),
            "swiftVersion": command_output(["xcrun", "swift", "--version"], env=os.environ.copy()),
            "packageResolvedSha256": digest(ROOT / "Package.resolved"),
            "componentPinsSha256": digest(ROOT / "docs/project-memory/component-pins.json"),
        }
        if data.get("schemaVersion") != 1 or data.get("status") != "passed":
            raise ValueError("certificate schema/status is invalid")
        mismatches = [key for key, value in expected.items() if data.get(key) != value]
        if mismatches:
            raise ValueError("stale fields: " + ", ".join(mismatches))
        required = {
            "deterministic-workbench-complete",
            "component-clean-copy",
                    "production-coverage",
            "release-build",
            "thread-sanitizer",
            "address-sanitizer",
            "ios-simulator-package-tests",
            "critical-mutation-suite",
        }
        if not required.issubset(set(data.get("assurances") or [])):
            raise ValueError("certificate omits required qualification assurances")
        run_id = data.get("qualificationRunID")
        receipt_digests = data.get("assuranceReceiptSha256")
        started_epoch = data.get("qualificationStartedEpoch")
        if (
            not isinstance(run_id, str)
            or RUN_ID.fullmatch(run_id) is None
            or not isinstance(receipt_digests, dict)
            or not isinstance(started_epoch, int)
        ):
            raise ValueError("certificate omits valid qualification receipt bindings")
        session = (ARTIFACT_ROOT / run_id).resolve()
        if session.parent != ARTIFACT_ROOT:
            raise ValueError("qualification receipt directory escapes its artifact root")
        for assurance in required:
            path = session / f"{assurance}.json"
            if not path.is_file() or receipt_digests.get(assurance) != hashlib.sha256(path.read_bytes()).hexdigest():
                raise ValueError(f"qualification receipt is missing or changed: {assurance}")
            try:
                receipt = json.loads(path.read_text())
            except json.JSONDecodeError as error:
                raise ValueError(f"qualification receipt is invalid JSON: {assurance}") from error
            expected_receipt = {
                "schemaVersion": 1,
                "status": "passed",
                "qualificationRunID": run_id,
                "qualificationStartedEpoch": started_epoch,
                "assurance": assurance,
                "verifiedTree": tree,
            }
            receipt_mismatches = [
                key for key, value in expected_receipt.items()
                if receipt.get(key) != value
            ]
            if receipt_mismatches or not isinstance(receipt.get("recordedEpoch"), int) or receipt["recordedEpoch"] < started_epoch:
                raise ValueError(f"qualification receipt content is stale: {assurance}")
        print(f"Qualification certificate valid for tree {tree}")
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(
            "Qualification evidence is missing or stale: "
            f"{error}. Run FOVEA_VERIFY_PROFILE=qualification scripts/verify.sh once for this exact tree.",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
