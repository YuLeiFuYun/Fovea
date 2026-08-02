#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import signal
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from swift_tooling import build_product, selected_environment


def command_output(root: Path, command: list[str], *, env: dict[str, str] | None = None) -> str:
    return subprocess.run(
        command,
        cwd=root,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()


def workspace_tree(root: Path) -> tuple[str, bool]:
    dirty = bool(command_output(root, ["git", "status", "--porcelain"]))
    with tempfile.TemporaryDirectory(prefix="fovea-live-network-index-") as temporary:
        index = Path(temporary) / "index"
        env = os.environ.copy()
        env["GIT_INDEX_FILE"] = str(index)
        command_output(root, ["git", "read-tree", "HEAD"], env=env)
        subprocess.run(
            ["git", "add", "-A", "--", "."],
            cwd=root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        tree = command_output(root, ["git", "write-tree"], env=env)
    return tree, dirty


def terminate(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    process.wait()


def run_attempt(
    root: Path,
    command: list[str],
    env: dict[str, str],
    timeout: int,
) -> tuple[int, str, str, bool]:
    process = subprocess.Popen(
        command,
        cwd=root,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=max(1, timeout))
    except subprocess.TimeoutExpired:
        timed_out = True
        terminate(process)
        stdout, stderr = process.communicate()
    return process.returncode if process.returncode is not None else -1, stdout, stderr, timed_out


def lab_passes(lab: dict[str, Any], exit_code: int) -> bool:
    cases = lab.get("cases")
    if not isinstance(cases, list) or len(cases) < 4:
        return False
    origins = {case.get("originLabel") for case in cases if isinstance(case, dict)}
    successful = [case for case in cases if isinstance(case, dict) and case.get("success") is True]
    return (
        exit_code == 0
        and lab.get("allSucceeded") is True
        and lab.get("allExpectationsSatisfied") is True
        and lab.get("allInvariantsSatisfied") is True
        and len(origins) >= 4
        and len(successful) == len(cases)
        and all(case.get("networkMetricsObserved") is True for case in successful)
        and all(case.get("networkTimingObserved") is True for case in successful)
        and all((case.get("networkTaskDurationNanoseconds") or 0) > 0 for case in successful)
        and all(case.get("singleFlightObserved") is True for case in successful)
        and any((case.get("redirectCount") or 0) >= 1 for case in successful)
        and any((case.get("networkTransactionCount") or 0) >= 2 for case in successful)
        and all(bool(case.get("networkProtocolNames")) for case in successful)
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run the required Fovea public HTTPS network laboratory."
    )
    parser.add_argument("--url", action="append", default=[])
    parser.add_argument("--allow-origin", action="append", default=[])
    parser.add_argument("--timeout", type=int, default=240)
    parser.add_argument("--attempts", type=int, default=2)
    parser.add_argument(
        "--output", default=".artifacts/live-network/network-lab.json"
    )
    args = parser.parse_args()
    if args.attempts < 1 or args.attempts > 3:
        parser.error("--attempts must be between 1 and 3")

    root = Path(__file__).resolve().parents[1]
    output = (root / args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    env = selected_environment(root)
    try:
        executable = build_product(
            root,
            env,
            "FoveaNetworkLab",
            configuration="release",
        )
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    command = [str(executable), "--live"]
    for url in args.url:
        command.extend(["--url", url])
    for origin in args.allow_origin:
        command.extend(["--allow-origin", origin])

    attempts: list[dict[str, Any]] = []
    final_lab: dict[str, Any] = {}
    final_exit_code = -1
    final_stderr = ""
    for attempt_number in range(1, args.attempts + 1):
        exit_code, stdout, stderr, timed_out = run_attempt(
            root, command, env, args.timeout
        )
        parsed: dict[str, Any] = {}
        parse_error: str | None = None
        try:
            value = json.loads(stdout)
            if isinstance(value, dict):
                parsed = value
            else:
                parse_error = "top-level JSON is not an object"
        except json.JSONDecodeError as error:
            parse_error = str(error)
        passed = not timed_out and parse_error is None and lab_passes(parsed, exit_code)
        attempts.append(
            {
                "attempt": attempt_number,
                "exitCode": exit_code,
                "timedOut": timed_out,
                "stderrLineCount": len(stderr.splitlines()),
                "stdoutSha256": hashlib.sha256(stdout.encode()).hexdigest(),
                "parseError": parse_error,
                "passed": passed,
            }
        )
        final_lab = parsed
        final_exit_code = exit_code
        final_stderr = stderr
        if passed:
            break

    commit = command_output(root, ["git", "rev-parse", "HEAD"])
    tree, dirty = workspace_tree(root)
    artifact = {
        "schemaVersion": 2,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "verifiedCommit": commit,
        "verifiedTree": tree,
        "includesWorkingTreeChanges": dirty,
        "status": "passed" if attempts[-1]["passed"] else "failed",
        "exitCode": final_exit_code,
        "attempts": attempts,
        "lab": final_lab,
        "stderrLineCount": len(final_stderr.splitlines()),
        "xcodeVersion": command_output(root, ["xcodebuild", "-version"], env=env),
        "swiftVersion": command_output(root, ["xcrun", "swift", "--version"], env=env),
    }
    output.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n")

    validation = subprocess.run(
        [
            sys.executable,
            str(root / "scripts/validate-live-network-report.py"),
            str(output),
            "--expected-commit",
            commit,
            "--expected-tree",
            tree,
        ],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if validation.stdout:
        print(validation.stdout.strip())
    print(f"Live network artifact: {output.relative_to(root)}")
    print(f"status={artifact['status']} verifiedTree={tree}")
    if artifact["status"] != "passed" and final_stderr:
        print(final_stderr, file=sys.stderr)
    return 0 if artifact["status"] == "passed" and validation.returncode == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
