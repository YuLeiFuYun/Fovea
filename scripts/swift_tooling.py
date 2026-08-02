from __future__ import annotations

import os
import subprocess
from pathlib import Path


def selected_environment(root: Path) -> dict[str, str]:
    env = os.environ.copy()
    if not env.get("DEVELOPER_DIR"):
        env["DEVELOPER_DIR"] = subprocess.run(
            [str(root / "scripts/select-xcode.sh")],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout.strip()
    return env


def build_product(
    root: Path,
    env: dict[str, str],
    product: str,
    *,
    configuration: str = "debug",
    warnings_as_errors: bool = True,
) -> Path:
    if warnings_as_errors and (root / "scripts/run-swift-strict.py").is_file():
        command = [
            "python3",
            "scripts/run-swift-strict.py",
            "build",
            "-c",
            configuration,
            "--product",
            product,
        ]
    else:
        command = [
            "xcrun",
            "swift",
            "build",
            "-c",
            configuration,
            "--product",
            product,
        ]
        if warnings_as_errors:
            command.extend(["-Xswiftc", "-warnings-as-errors"])
    completed = subprocess.run(
        command,
        cwd=root,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stdout.strip() or f"failed to build {product}")
    bin_path = subprocess.run(
        [
            "xcrun",
            "swift",
            "build",
            "-c",
            configuration,
            "--show-bin-path",
        ],
        cwd=root,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()
    executable = Path(bin_path) / product
    if not executable.is_file():
        raise RuntimeError(f"built executable is missing: {executable}")
    return executable
