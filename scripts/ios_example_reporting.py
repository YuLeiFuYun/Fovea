"""Verification profile and schema-2 report generation."""
from __future__ import annotations

import datetime as dt
import json
import subprocess
import sys
from pathlib import Path

from ios_example_process import command_output, digest, workspace_tree

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "Examples/FoveaWorkbenchApp"
PROJECT = EXAMPLE / "FoveaWorkbench.xcodeproj"
PBXPROJ = PROJECT / "project.pbxproj"
XCODEGEN_VERSION_FILE = EXAMPLE / ".xcodegen-version"
ARTIFACTS = ROOT / ".artifacts/ios-example"


def verification_profile(phases: list[dict[str, str]]) -> tuple[str, set[str]]:
    executed = {phase["name"] for phase in phases}
    all_phases = {
        "build", "unit-tests", "live-network-tests", "ui-tests", "ipad-ui-tests",
        "ui-smoke", "ipad-ui-smoke",
    }
    profiles = {
        frozenset({"build", "unit-tests", "live-network-tests", "ui-tests", "ipad-ui-tests"}): "complete",
        frozenset({"build", "unit-tests", "ui-tests", "ipad-ui-tests"}): "deterministic",
        frozenset({"build", "unit-tests", "live-network-tests"}): "network-smoke",
        frozenset({"unit-tests"}): "unit-only",
        frozenset({"unit-tests", "ui-smoke", "ipad-ui-smoke"}): "ui-smoke",
        frozenset({"build", "unit-tests", "ui-smoke", "ipad-ui-smoke"}): "ui-smoke-release",
        frozenset({"build", "unit-tests"}): "build-unit",
    }
    profile = profiles.get(frozenset(executed))
    if profile is None:
        raise RuntimeError(f"unsupported Workbench phase combination: {sorted(executed)}")
    return profile, all_phases - executed


def report_payload(
    phases: list[dict[str, str]], env: dict[str, str], profile: str, skipped: set[str]
) -> dict[str, object]:
    verified_commit = command_output(["git", "rev-parse", "HEAD"])
    verified_tree, dirty = workspace_tree()
    return {
        "schemaVersion": 2,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "verifiedCommit": verified_commit,
        "verifiedTree": verified_tree,
        "includesWorkingTreeChanges": dirty,
        "xcodeVersion": command_output(["xcodebuild", "-version"], env=env),
        "swiftVersion": command_output(["xcrun", "swift", "--version"], env=env),
        "status": "passed",
        "verificationProfile": profile,
        "skippedPhases": sorted(skipped),
        "deploymentTarget": "15.0",
        "externalNetworkingDefault": False,
        "xcodegenVersion": XCODEGEN_VERSION_FILE.read_text().strip(),
        "project": str(PBXPROJ.relative_to(ROOT)),
        "projectSha256": digest(PBXPROJ),
        "phases": phases,
    }


def validate_report(
    report_path: Path, report: dict[str, object], profile: str
) -> None:
    validation = subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts/validate-ios-example-report.py"),
            str(report_path),
            "--expected-commit", str(report["verifiedCommit"]),
            "--expected-tree", str(report["verifiedTree"]),
            "--required-profile", profile,
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if validation.returncode != 0:
        raise RuntimeError(validation.stdout.strip())
    print(validation.stdout.strip())


def write_verification_report(
    phases: list[dict[str, str]], env: dict[str, str]
) -> Path:
    profile, skipped = verification_profile(phases)
    report = report_payload(phases, env, profile, skipped)
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    report_path = ARTIFACTS / "verification.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    validate_report(report_path, report, profile)
    return report_path
