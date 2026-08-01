"""Strict dual-device visual verification for FoveaWorkbench."""
from __future__ import annotations

import json
import os
import shutil
import signal
import sys
import time
from pathlib import Path

from ios_example_process import digest, run
from ios_example_xcode import (
    ensure_simulator_booted,
    is_simulator_infrastructure_failure,
    recover_core_simulator_service,
    restart_simulator,
    simulator,
)

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / ".artifacts/ios-example"
VISUAL_FAMILY_TIMEOUT_SECONDS = 600
VISUAL_CAPTURE_ATTEMPTS = 2
VISUAL_TEST_SELECTOR = "-only-testing:FoveaWorkbenchUITests/FoveaWorkbenchVisualTests"


def visual_process_groups(family: str, env: dict[str, str]) -> set[int]:
    bundle = str(ARTIFACTS / "visual-audit" / f"{family}.xcresult")
    listing = run(["ps", "-axo", "pid=,pgid=,command="], env=env, timeout=15)
    if listing.returncode != 0:
        return set()
    groups: set[int] = set()
    for line in listing.stdout.splitlines():
        fields = line.strip().split(maxsplit=2)
        if len(fields) != 3:
            continue
        _, pgid_text, command = fields
        if "xcodebuild" not in command or VISUAL_TEST_SELECTOR not in command or bundle not in command:
            continue
        try:
            groups.add(int(pgid_text))
        except ValueError:
            continue
    return groups


def signal_process_groups(groups: set[int], signum: signal.Signals) -> None:
    for pgid in groups:
        try:
            os.killpg(pgid, signum)
        except ProcessLookupError:
            pass


def living_process_groups(groups: set[int]) -> set[int]:
    living: set[int] = set()
    for pgid in groups:
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            continue
        except PermissionError:
            living.add(pgid)
        else:
            living.add(pgid)
    return living


def terminate_visual_family_xcodebuild(family: str, env: dict[str, str]) -> None:
    groups = visual_process_groups(family, env)
    signal_process_groups(groups, signal.SIGTERM)
    deadline = time.monotonic() + 5
    while groups and time.monotonic() < deadline:
        groups = living_process_groups(groups)
        if groups:
            time.sleep(0.1)
    signal_process_groups(groups, signal.SIGKILL)


def prepare_visual_family(family: str, identifier: str, env: dict[str, str]) -> None:
    terminate_visual_family_xcodebuild(family, env)
    recover_core_simulator_service(env)
    ensure_simulator_booted(identifier, env)


def visual_capture_command(family: str, identifier: str) -> list[str]:
    argument = "--ipad-id" if family == "ipad" else "--iphone-id"
    return [
        sys.executable,
        str(ROOT / "scripts/audit-workbench-visuals.py"),
        "--mode", "primary", "--capture", argument, identifier,
    ]


def isolated_family_environment(family: str, env: dict[str, str]) -> dict[str, str]:
    family_env = dict(env)
    opposite = "FOVEA_IPHONE_SIMULATOR_ID" if family == "ipad" else "FOVEA_IPAD_SIMULATOR_ID"
    family_env.pop(opposite, None)
    return family_env


def failed_visual_output(family: str, output: str, timed_out: bool) -> str:
    if not timed_out:
        return output
    return output + f"\nvisual family {family} timed out after {VISUAL_FAMILY_TIMEOUT_SECONDS} seconds"


def capture_visual_family(family: str, identifier: str, env: dict[str, str]) -> str:
    command = visual_capture_command(family, identifier)
    family_env = isolated_family_environment(family, env)
    outputs: list[str] = []
    for attempt in range(VISUAL_CAPTURE_ATTEMPTS):
        prepare_visual_family(family, identifier, family_env)
        completed = run(command, env=family_env, timeout=VISUAL_FAMILY_TIMEOUT_SECONDS)
        timed_out = completed.returncode == -1
        output = failed_visual_output(family, completed.stdout or "", timed_out)
        outputs.append(output)
        if completed.returncode == 0:
            return "\n".join(outputs)
        terminate_visual_family_xcodebuild(family, family_env)
        retryable = timed_out or is_simulator_infrastructure_failure(output)
        if attempt + 1 >= VISUAL_CAPTURE_ATTEMPTS or not retryable:
            tail = "\n".join(output.splitlines()[-120:])
            raise RuntimeError(
                f"FoveaWorkbench {family} visual audit failed after {attempt + 1} attempt(s):\n{tail}"
            )
        restart_simulator(identifier, env)
    raise RuntimeError(f"FoveaWorkbench {family} visual audit exhausted retry budget")


def validate_visual_attachments(report: dict[str, object]) -> None:
    attachments = report.get("attachments") or {}
    if not isinstance(attachments, dict):
        raise RuntimeError("Workbench visual report has invalid attachment metadata")
    expected = {"screenshotCount": 14, "geometryCount": 14, "accessibilityTreeCount": 14}
    for key, minimum in expected.items():
        if int(attachments.get(key) or 0) < minimum:
            raise RuntimeError(f"Workbench visual audit lacks {key}: {attachments.get(key)}")


def validate_visual_matrix(report: dict[str, object]) -> None:
    matrix = report.get("captureMatrix") or {}
    if not isinstance(matrix, dict):
        raise RuntimeError("Workbench visual report has invalid capture matrix")
    if matrix.get("deviceFamilies") != ["iphone", "ipad"]:
        raise RuntimeError(f"unexpected visual device matrix: {matrix}")
    if matrix.get("checkpointsPerFamily") != 7:
        raise RuntimeError(f"unexpected visual checkpoint count: {matrix}")


def validate_visual_report(report: dict[str, object]) -> None:
    if report.get("status") != "passed":
        raise RuntimeError("FoveaWorkbench visual report did not publish passed status")
    if report.get("oracleVersion") != "1.2.0":
        raise RuntimeError(f"unexpected Workbench visual oracle version: {report.get('oracleVersion')}")
    if report.get("captureErrors") != []:
        raise RuntimeError(f"Workbench visual capture errors: {report.get('captureErrors')}")
    validate_visual_attachments(report)
    validate_visual_matrix(report)


def verify_visual_assurance(env: dict[str, str]) -> Path:
    iphone, ipad = simulator(env, "iphone"), simulator(env, "ipad")
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    visual_root = ARTIFACTS / "visual-audit"
    for path in (visual_root / "attachments", visual_root / "iphone.xcresult", visual_root / "ipad.xcresult"):
        shutil.rmtree(path, ignore_errors=True)
    outputs = [
        capture_visual_family("iphone", iphone, env),
        capture_visual_family("ipad", ipad, env),
    ]
    (ARTIFACTS / "visual-audit.log").write_text("\n".join(outputs))
    report_path = visual_root / "primary.json"
    report = json.loads(report_path.read_text())
    validate_visual_report(report)
    print(
        "FoveaWorkbench strict visual audit passed: "
        f"{report_path.relative_to(ROOT)} sha256:{digest(report_path)}"
    )
    return report_path
