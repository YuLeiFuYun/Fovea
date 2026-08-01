#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPORT = ROOT / ".artifacts/ios-example/verification.json"
COMMIT = re.compile(r"^[0-9a-f]{40,64}$")
UUID = re.compile(r"^[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}$")
DIGEST = re.compile(r"^[0-9a-f]{64}$")
ALL_PHASES = {
    "build",
    "unit-tests",
    "live-network-tests",
    "ui-tests",
    "ipad-ui-tests",
}
PROFILE_PHASES = {
    "build-unit": {"build", "unit-tests"},
    "deterministic": {"build", "unit-tests", "ui-tests", "ipad-ui-tests"},
    "network-smoke": {"build", "unit-tests", "live-network-tests"},
    "complete": ALL_PHASES,
}
PROFILE_SATISFACTION = {
    "build-unit": {"build-unit"},
    "network-smoke": {"build-unit", "network-smoke"},
    "deterministic": {"build-unit", "deterministic"},
    "complete": {"build-unit", "network-smoke", "deterministic", "complete"},
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resolve_relative(relative: str) -> Path:
    path = (ROOT / relative).resolve()
    path.relative_to(ROOT.resolve())
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate FoveaWorkbench verification evidence.")
    parser.add_argument("report", nargs="?", default=str(DEFAULT_REPORT))
    parser.add_argument("--expected-commit")
    parser.add_argument("--expected-tree")
    parser.add_argument(
        "--required-profile",
        choices=tuple(PROFILE_PHASES),
        default="deterministic",
        help="minimum requested verification profile; complete additionally requires live networking",
    )
    args = parser.parse_args()
    try:
        report_path = Path(args.report).resolve()
        data = json.loads(report_path.read_text())
        require(data.get("schemaVersion") == 2, "schemaVersion must be 2")
        generated_at = data.get("generatedAt")
        require(isinstance(generated_at, str), "generatedAt is required")
        dt.datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
        commit = data.get("verifiedCommit")
        require(
            isinstance(commit, str) and COMMIT.fullmatch(commit) is not None,
            "invalid verifiedCommit",
        )
        if args.expected_commit:
            require(commit == args.expected_commit, "verifiedCommit does not match expected commit")
        tree = data.get("verifiedTree")
        require(
            isinstance(tree, str) and COMMIT.fullmatch(tree) is not None,
            "invalid verifiedTree",
        )
        if args.expected_tree:
            require(tree == args.expected_tree, "verifiedTree does not match expected tree")
        require(
            isinstance(data.get("includesWorkingTreeChanges"), bool),
            "includesWorkingTreeChanges must be boolean",
        )
        require(
            isinstance(data.get("xcodeVersion"), str) and data["xcodeVersion"],
            "xcodeVersion is required",
        )
        require(
            isinstance(data.get("swiftVersion"), str) and data["swiftVersion"],
            "swiftVersion is required",
        )
        require(data.get("status") == "passed", "requested verification phases must pass")
        profile = data.get("verificationProfile")
        require(profile in PROFILE_PHASES, "invalid verificationProfile")
        require(
            args.required_profile in PROFILE_SATISFACTION[profile],
            f"profile {profile} does not satisfy required profile {args.required_profile}",
        )
        require(data.get("deploymentTarget") == "15.0", "deployment target must remain iOS 15.0")
        require(
            data.get("externalNetworkingDefault") is False,
            "deterministic networking must default on; real networking requires explicit opt-in",
        )
        expected_xcodegen = (
            ROOT / "Examples/FoveaWorkbenchApp/.xcodegen-version"
        ).read_text().strip()
        require(data.get("xcodegenVersion") == expected_xcodegen, "xcodegen version mismatch")
        project_relative = data.get("project")
        require(
            project_relative
            == "Examples/FoveaWorkbenchApp/FoveaWorkbench.xcodeproj/project.pbxproj",
            "unexpected project path",
        )
        project = resolve_relative(project_relative)
        project_digest = data.get("projectSha256")
        require(
            isinstance(project_digest, str) and DIGEST.fullmatch(project_digest) is not None,
            "invalid project digest",
        )
        require(project.is_file() and sha256(project) == project_digest, "project digest mismatch")

        phases = data.get("phases")
        require(isinstance(phases, list), "phases must be an array")
        names: set[str] = set()
        for phase in phases:
            require(isinstance(phase, dict), "phase must be an object")
            name = phase.get("name")
            require(name in ALL_PHASES, "invalid phase name")
            require(name not in names, "duplicate phase")
            names.add(name)
            device_family = phase.get("deviceFamily")
            require(device_family in {"iphone", "ipad"}, "invalid device family")
            if name == "ipad-ui-tests":
                require(device_family == "ipad", "iPad UI phase must use an iPad")
            else:
                require(device_family == "iphone", f"{name} must use an iPhone")
            simulator_id = phase.get("simulatorID")
            require(
                isinstance(simulator_id, str) and UUID.fullmatch(simulator_id) is not None,
                "invalid simulator ID",
            )
            log_relative = phase.get("log")
            require(
                isinstance(log_relative, str)
                and log_relative.startswith(".artifacts/ios-example/"),
                "invalid log path",
            )
            log = resolve_relative(log_relative)
            log_digest = phase.get("logSha256")
            require(
                isinstance(log_digest, str) and DIGEST.fullmatch(log_digest) is not None,
                "invalid log digest",
            )
            require(log.is_file() and sha256(log) == log_digest, f"log digest mismatch: {name}")
            count = phase.get("testCount")
            require(isinstance(count, int) and count >= 0, f"invalid test count: {name}")
            if name == "build":
                require(count == 0, "build phase must not claim tests")
            elif name == "unit-tests":
                require(count >= 30, "unit/integration phase must execute at least 30 tests")
            elif name == "live-network-tests":
                require(count >= 1, "live-network phase must execute at least 1 test")
            elif name == "ui-tests":
                require(count >= 5, "iPhone UI phase must execute at least 5 behavior tests")
            else:
                require(
                    count >= 3,
                    "iPad UI phase must execute at least 3 regular-width behavior tests",
                )

        expected_phases = PROFILE_PHASES[profile]
        require(names == expected_phases, f"phase set mismatch for {profile}: {sorted(names)}")
        skipped = data.get("skippedPhases")
        require(
            isinstance(skipped, list)
            and all(isinstance(item, str) and item in ALL_PHASES for item in skipped),
            "invalid skippedPhases",
        )
        require(len(skipped) == len(set(skipped)), "duplicate skipped phase")
        require(set(skipped) == ALL_PHASES - names, "skippedPhases do not complement executed phases")
        print(
            "FoveaWorkbench verification report valid: "
            f"{report_path.relative_to(ROOT)} sha256:{sha256(report_path)}"
        )
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"FoveaWorkbench verification report invalid: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
