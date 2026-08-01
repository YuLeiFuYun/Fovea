"""Process, hashing, and working-tree helpers for iOS example verification."""
from __future__ import annotations

import hashlib
import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def process_group_exists(identifier: int) -> bool:
    try:
        os.killpg(identifier, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def terminate_process_group(process: subprocess.Popen[str]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    except PermissionError:
        if process.poll() is None:
            process.terminate()

    deadline = time.monotonic() + 5
    while process_group_exists(process.pid) and time.monotonic() < deadline:
        time.sleep(0.1)
    if not process_group_exists(process.pid):
        if process.poll() is None:
            process.wait(timeout=1)
        return

    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    except PermissionError:
        if process.poll() is None:
            process.kill()
    if process.poll() is None:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass


def run(
    command: list[str], *, env: dict[str, str], timeout: int = 600
) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryFile(mode="w+t") as output:
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            env=env,
            text=True,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        timed_out = False
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            terminate_process_group(process)
            process.wait()
        output.flush()
        output.seek(0)
        stdout = output.read()
    return subprocess.CompletedProcess(command, -1 if timed_out else process.returncode, stdout, None)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command_output(command: list[str], *, env: dict[str, str] | None = None) -> str:
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()


def workspace_tree() -> tuple[str, bool]:
    dirty = bool(command_output(["git", "status", "--porcelain"]))
    with tempfile.TemporaryDirectory(prefix="fovea-workbench-index-") as temporary:
        index = Path(temporary) / "index"
        env = os.environ.copy()
        env["GIT_INDEX_FILE"] = str(index)
        command_output(["git", "read-tree", "HEAD"], env=env)
        subprocess.run(
            ["git", "add", "-A", "--", "."], cwd=ROOT, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
        )
        tree = command_output(["git", "write-tree"], env=env)
    return tree, dirty


def inactivity_expired(
    last_activity: float, now: float, timeout_seconds: int | None
) -> bool:
    if timeout_seconds is None:
        return False
    if timeout_seconds <= 0:
        raise ValueError("inactivity timeout must be positive")
    return now - last_activity >= timeout_seconds
