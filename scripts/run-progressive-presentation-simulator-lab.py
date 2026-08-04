#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / ".artifacts/progressive-presentation-simulator"
TEST_CLASS = "FoveaTests/ProgressivePresentationHostTests"
TEST_METHODS = [
    "testChunkedURLSessionPreviewReachesDisplayLinkBeforeFinal_UI_PT_029",
    "testIdentityReplacementClosesPublicationFenceBeforeOldPreview_UI_PT_030",
]


def run(*args: str, check: bool = True, capture: bool = True, env: dict[str, str] | None = None):
    return subprocess.run(
        list(args), cwd=ROOT, check=check, text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
        env=env,
    )


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_output(*args: str) -> str:
    return run("git", *args).stdout.strip()


def package_revision(identity: str) -> str:
    data = json.loads((ROOT / "Package.resolved").read_text())
    pin = next(x for x in data["pins"] if x["identity"] == identity)
    return pin["state"]["revision"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 20:
        parser.error("--iterations must be between 1 and 20")

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    result_bundle = output / "ProgressivePresentationHost.xcresult"
    log_path = output / "xcodebuild.log"
    summary_path = output / "xcresult-summary.json"
    report_path = output / "report.json"
    if result_bundle.exists():
        shutil.rmtree(result_bundle)

    developer = run(str(ROOT / "scripts/select-xcode.sh")).stdout.strip()
    simulator = run(sys.executable, str(ROOT / "scripts/select-ios-simulator.py")).stdout.strip()
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = developer
    command = [
        "xcodebuild", "-scheme", "Fovea-Package",
        "-destination", f"platform=iOS Simulator,id={simulator}",
        "-collect-test-diagnostics", "never",
        "-resultBundlePath", str(result_bundle),
        "-test-iterations", str(args.iterations),
        "-test-repetition-relaunch-enabled", "YES",
        "APPINTENTS_METADATA_PROCESSING_ENABLED=NO",
        f"-only-testing:{TEST_CLASS}", "test",
    ]
    completed = run(*command, check=False, env=env)
    log_path.write_text(completed.stdout)
    if not result_bundle.exists():
        print(completed.stdout[-4000:], file=sys.stderr)
        return completed.returncode or 1

    summary_text = run(
        "xcrun", "xcresulttool", "get", "test-results", "summary",
        "--path", str(result_bundle), "--format", "json", env=env,
    ).stdout
    summary_path.write_text(summary_text)
    summary = json.loads(summary_text)
    expected_unique = len(TEST_METHODS)
    expected_executions = expected_unique * args.iterations
    passed_unique = summary.get("passedTests")
    result = summary.get("result")
    execution_pattern = re.compile(
        r"Test Case '-\[FoveaTests\.ProgressivePresentationHostTests "
        r"(?:" + "|".join(re.escape(method) for method in TEST_METHODS) + r")\]' passed"
    )
    passed_executions = len(execution_pattern.findall(completed.stdout))
    worktree = git_output("status", "--porcelain")
    report = {
        "schemaVersion": 1,
        "labID": "fovea-progressive-presentation-simulator-v1",
        "capturedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "boundary": (
            "URLSessionDataDelegate -> ImageCraft progressive session -> "
            "FoveaImageView identity/publication fence -> CADisplayLink observation; "
            "CADisplayLink callback is not Core Animation/GPU scanout proof"
        ),
        "command": command,
        "iterationsPerTest": args.iterations,
        "expectedUniqueTests": expected_unique,
        "expectedTestExecutions": expected_executions,
        "testClass": TEST_CLASS,
        "testMethods": TEST_METHODS,
        "result": result,
        "passedUniqueTests": passed_unique,
        "passedTestExecutions": passed_executions,
        "failedTests": summary.get("failedTests"),
        "skippedTests": summary.get("skippedTests"),
        "devicesAndConfigurations": summary.get("devicesAndConfigurations"),
        "environmentDescription": summary.get("environmentDescription"),
        "foveaCommit": git_output("rev-parse", "HEAD"),
        "foveaTree": git_output("rev-parse", "HEAD^{tree}"),
        "includesWorkingTreeChanges": bool(worktree),
        "workingTreeStatus": worktree.splitlines(),
        "imageCraftRevision": package_revision("imagecraft"),
        "akashicRevision": package_revision("akashic"),
        "xcodeVersion": run("xcodebuild", "-version", env=env).stdout.strip(),
        "swiftVersion": run("xcrun", "swift", "--version", env=env).stdout.strip(),
        "artifacts": {
            "xcodebuildLog": {"path": str(log_path), "sha256": sha256(log_path)},
            "xcresultSummary": {"path": str(summary_path), "sha256": sha256(summary_path)},
            "xcresultBundle": {"path": str(result_bundle)},
        },
        "claims": {
            "supported": [
                "A URLSession delegate can feed ImageCraft progressive JPEG generations into FoveaImageView.",
                "CADisplayLink observes at least one preview identity before the final identity in the retained scenario.",
                "Closing the publication fence before cancellation suppresses a generated old-identity preview.",
            ],
            "unsupported": [
                "Physical display scanout or GPU presentation latency.",
                "Production URLSessionTransport streaming support.",
                "Cross-device performance, energy, or universal generation counts.",
            ],
        },
    }
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "Progressive presentation lab: "
        f"{result}, unique={passed_unique}/{expected_unique}, "
        f"executions={passed_executions}/{expected_executions}"
    )
    print(f"Report: {report_path} sha256:{sha256(report_path)}")
    if (
        completed.returncode != 0
        or result != "Passed"
        or passed_unique != expected_unique
        or passed_executions != expected_executions
    ):
        print(completed.stdout[-8000:], file=sys.stderr)
        return completed.returncode or 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
