#!/usr/bin/env python3
from __future__ import annotations

import os
import signal
import subprocess
import sys
from pathlib import Path

from comparative_simulator_support import assert_coresimulator_healthy

ROOT = Path(__file__).resolve().parents[1]


def run(command: list[str], *, env: dict[str, str], timeout: int = 30, check: bool = True) -> subprocess.CompletedProcess[str]:
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise
    result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    if check and result.returncode != 0:
        raise RuntimeError(stderr or stdout or f"command failed: {command}")
    return result


def main() -> int:
    try:
        artifact = assert_coresimulator_healthy(
            run_command=run,
            env=os.environ.copy(),
            root=ROOT,
        )
    except Exception as error:
        print(f"CoreSimulator health check failed: {error}", file=sys.stderr)
        return 1
    print(f"CoreSimulator health: {artifact['status']}")
    print("Artifact: .artifacts/comparative-coresimulator-health.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
