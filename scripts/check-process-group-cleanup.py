#!/usr/bin/env python3
from __future__ import annotations

import errno
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_mutation_runner():
    path = ROOT / "scripts/run-critical-mutants.py"
    spec = importlib.util.spec_from_file_location("fovea_mutation_runner", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load mutation runner")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError as error:
        if error.errno == errno.ESRCH:
            return False
        raise


def main() -> int:
    runner = load_mutation_runner()
    with tempfile.TemporaryDirectory(prefix="fovea-process-cleanup-") as temporary:
        pid_path = Path(temporary) / "child.pid"
        command = [
            "/bin/sh",
            "-c",
            f"sleep 60 & child=$!; printf '%s' \"$child\" > {pid_path}; wait",
        ]
        try:
            runner.run(command, ROOT, os.environ.copy(), 1)
            print("process cleanup check failed: timeout command completed", file=sys.stderr)
            return 1
        except subprocess.TimeoutExpired:
            pass

        for _ in range(50):
            if pid_path.is_file() and pid_path.read_text().strip():
                break
            time.sleep(0.01)
        if not pid_path.is_file():
            print("process cleanup check failed: child PID was not recorded", file=sys.stderr)
            return 1
        child_pid = int(pid_path.read_text())
        for _ in range(50):
            if not process_exists(child_pid):
                print("Process-group timeout cleanup passed.")
                return 0
            time.sleep(0.01)
        try:
            os.kill(child_pid, 9)
        except OSError:
            pass
        print(f"process cleanup check failed: child {child_pid} survived timeout", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
