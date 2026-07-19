#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import signal
import subprocess
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run the opt-in Fovea public HTTPS network laboratory."
    )
    parser.add_argument("--url", action="append", default=[])
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument(
        "--output", default=".artifacts/live-network/network-lab.json"
    )
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    output = (root / args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = subprocess.run(
        [str(root / "scripts/select-xcode.sh")],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()
    command = ["xcrun", "swift", "run", "-c", "release", "FoveaNetworkLab", "--live"]
    for url in args.url:
        command.extend(["--url", url])

    process = subprocess.Popen(
        command,
        cwd=root,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=max(1, args.timeout))
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
        print("Live network laboratory timed out", file=sys.stderr)
        if stderr:
            print(stderr, file=sys.stderr)
        return 1

    try:
        lab = json.loads(stdout)
    except json.JSONDecodeError as error:
        print(f"Live network laboratory produced invalid JSON: {error}", file=sys.stderr)
        print(stdout, file=sys.stderr)
        print(stderr, file=sys.stderr)
        return 1

    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()
    artifact = {
        "schemaVersion": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "verifiedCommit": commit,
        "status": "passed"
        if process.returncode == 0
        and lab.get("allSucceeded")
        and lab.get("allInvariantsSatisfied")
        else "failed",
        "exitCode": process.returncode,
        "lab": lab,
        "stderrLineCount": len(stderr.splitlines()),
    }
    output.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n")
    print(f"Live network artifact: {output.relative_to(root)}")
    print(f"status={artifact['status']} verifiedCommit={commit}")
    return 0 if artifact["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
