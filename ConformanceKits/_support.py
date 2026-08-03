from __future__ import annotations

import hashlib
import os
import re
import signal
import subprocess
import tempfile
import time
from pathlib import Path


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_digest(root: Path) -> str:
    excluded = {".build", ".git", ".swiftpm", ".artifacts", "DerivedData"}
    hasher = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if not path.is_file() or any(part in excluded for part in path.relative_to(root).parts):
            continue
        relative = path.relative_to(root).as_posix().encode()
        payload = path.read_bytes()
        hasher.update(len(relative).to_bytes(4, "big"))
        hasher.update(relative)
        hasher.update(len(payload).to_bytes(8, "big"))
        hasher.update(payload)
    return hasher.hexdigest()


def command_output(command: list[str], cwd: Path, env: dict[str, str]) -> str:
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()


def working_tree_identity(repository: Path, env: dict[str, str]) -> str:
    top = command_output(["git", "rev-parse", "--show-toplevel"], repository, env)
    top_path = Path(top).resolve()
    with tempfile.TemporaryDirectory(prefix="fovea-conformance-index-") as temporary:
        index = Path(temporary) / "index"
        git_env = dict(env)
        git_env["GIT_INDEX_FILE"] = str(index)
        subprocess.run(
            ["git", "read-tree", "HEAD"],
            cwd=top_path,
            env=git_env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        subprocess.run(
            ["git", "add", "-A", "--", "."],
            cwd=top_path,
            env=git_env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return command_output(["git", "write-tree"], top_path, git_env)


def swift_string(value: str) -> str:
    import json

    return json.dumps(value)


def terminate_group(process: subprocess.Popen[str]) -> None:
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
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def run_swift_tests(
    command: list[str],
    cwd: Path,
    env: dict[str, str],
    timeout: int,
) -> tuple[int, str, float, bool]:
    started = time.monotonic()
    process = subprocess.Popen(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    timed_out = False
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        terminate_group(process)
        output, _ = process.communicate()
        output += f"\nconformance run timed out after {timeout} seconds\n"
    return (124 if timed_out else process.returncode, output, time.monotonic() - started, timed_out)


def xctest_summary(output: str) -> tuple[int, int]:
    summaries = re.findall(
        r"Executed ([0-9]+) tests, with ([0-9]+) failures",
        output,
    )
    return (
        max((int(count) for count, _ in summaries), default=-1),
        max((int(count) for _, count in summaries), default=-1),
    )
