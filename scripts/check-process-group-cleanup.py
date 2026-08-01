#!/usr/bin/env python3
from __future__ import annotations

import errno
import importlib.util
import os
import signal
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




def wait_for_child_pid(pid_path: Path) -> int:
    for _ in range(100):
        if pid_path.is_file() and pid_path.read_text().strip():
            return int(pid_path.read_text())
        time.sleep(0.01)
    raise RuntimeError("child PID was not recorded")


def wait_until_gone(pid: int) -> bool:
    for _ in range(100):
        if not process_exists(pid):
            return True
        time.sleep(0.01)
    return False


def check_external_termination(temporary: Path) -> bool:
    pid_path = temporary / "signal-child.pid"
    runner_path = ROOT / "scripts/run-critical-mutants.py"
    shell_command = (
        f"sleep 60 & child=$!; printf '%s' \"$child\" > {pid_path}; wait"
    )
    helper = f"""
import importlib.util
import os
import sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('mutation_runner_signal_test', {str(runner_path)!r})
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
command = ['/bin/sh', '-c', {shell_command!r}]
try:
    module.run(command, Path({str(ROOT)!r}), os.environ.copy(), 60)
except module.ProcessGroupInterrupted as error:
    raise SystemExit(128 + error.signum)
"""
    parent = subprocess.Popen([sys.executable, "-c", helper])
    try:
        child_pid = wait_for_child_pid(pid_path)
        os.kill(parent.pid, signal.SIGTERM)
        parent.wait(timeout=10)
        return wait_until_gone(child_pid)
    finally:
        if parent.poll() is None:
            parent.kill()
            parent.wait()
        if pid_path.is_file() and pid_path.read_text().strip():
            child_pid = int(pid_path.read_text())
            if process_exists(child_pid):
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except OSError:
                    pass


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

        try:
            child_pid = wait_for_child_pid(pid_path)
        except RuntimeError as error:
            print(f"process cleanup check failed: {error}", file=sys.stderr)
            return 1
        if not wait_until_gone(child_pid):
            try:
                os.kill(child_pid, signal.SIGKILL)
            except OSError:
                pass
            print(f"process cleanup check failed: child {child_pid} survived timeout", file=sys.stderr)
            return 1
        if not check_external_termination(Path(temporary)):
            print("process cleanup check failed: child survived runner SIGTERM", file=sys.stderr)
            return 1
        print("Process-group timeout and signal cleanup passed.")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
