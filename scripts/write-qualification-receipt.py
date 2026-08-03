#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
from pathlib import Path

from ios_example_process import command_output, workspace_tree

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_ROOT = (ROOT / ".artifacts/verification/qualification-runs").resolve()
RUN_ID = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9]+$")
ASSURANCES = {
    "deterministic-workbench-complete",
    "component-clean-copy",
    "production-coverage",
    "release-build",
    "thread-sanitizer",
    "address-sanitizer",
    "ios-simulator-package-tests",
    "critical-mutation-suite",
}


def main() -> int:
    parser = argparse.ArgumentParser(description="Write one qualification-stage receipt.")
    parser.add_argument("assurance", choices=sorted(ASSURANCES))
    args = parser.parse_args()

    if os.environ.get("FOVEA_QUALIFICATION_ACTIVE") != "1":
        raise SystemExit("qualification receipt writer requires an active qualification run")
    run_id = os.environ.get("FOVEA_QUALIFICATION_RUN_ID", "").strip()
    if RUN_ID.fullmatch(run_id) is None:
        raise SystemExit("qualification run identifier is invalid")
    started_text = os.environ.get("FOVEA_QUALIFICATION_STARTED_EPOCH", "").strip()
    try:
        started_epoch = int(started_text)
    except ValueError as error:
        raise SystemExit("qualification start epoch is invalid") from error

    expected_session = (ARTIFACT_ROOT / run_id).resolve()
    configured = os.environ.get("FOVEA_QUALIFICATION_SESSION_DIR", "").strip()
    if not configured or Path(configured).resolve() != expected_session:
        raise SystemExit("qualification session directory does not match the active run")
    expected_session.mkdir(parents=True, exist_ok=True)

    tree, dirty = workspace_tree()
    now = dt.datetime.now(dt.timezone.utc)
    recorded_epoch = int(now.timestamp())
    if recorded_epoch < started_epoch:
        raise SystemExit("qualification receipt predates the active run")
    payload = {
        "schemaVersion": 1,
        "status": "passed",
        "qualificationRunID": run_id,
        "assurance": args.assurance,
        "recordedAt": now.isoformat(),
        "recordedEpoch": recorded_epoch,
        "qualificationStartedEpoch": started_epoch,
        "verifiedTree": tree,
        "includesWorkingTreeChanges": dirty,
        "verifiedCommit": command_output(["git", "rev-parse", "HEAD"]),
    }
    path = expected_session / f"{args.assurance}.json"
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(f"Qualification receipt written: {path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
