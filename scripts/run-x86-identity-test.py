#!/usr/bin/env python3
"""Cross-build and execute the x86_64 identity vector under Rosetta."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRATCH = ROOT / ".build/identity-x86_64"
TRIPLE = "x86_64-apple-macosx14.0"
TEST_SELECTOR = (
    "FoveaTests.IdentityTests/"
    "testPersistentIdentityGoldenVectorsAreArchitectureStable_CACHE_PT_017"
)


def require_file(path: Path, label: str) -> Path:
    if not path.is_file():
        raise RuntimeError(f"missing {label}: {path}")
    return path


def lipo_architectures(path: Path, environment: dict[str, str]) -> list[str]:
    completed = subprocess.run(
        ["xcrun", "lipo", "-archs", str(path)],
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"could not inspect architectures for {path}: {completed.stdout}")
    return completed.stdout.split()


def xctest_command(runner: Path, bundle: Path) -> list[str]:
    return [
        "/usr/bin/arch",
        "-x86_64",
        str(runner),
        "-XCTest",
        TEST_SELECTOR,
        str(bundle),
    ]


def append_search_path(environment: dict[str, str], key: str, path: Path) -> None:
    existing = environment.get(key)
    environment[key] = f"{path}:{existing}" if existing else str(path)


def main() -> int:
    environment = os.environ.copy()
    developer_dir_value = environment.get("DEVELOPER_DIR")
    if not developer_dir_value:
        print("error: DEVELOPER_DIR must be selected before x86 identity verification", file=sys.stderr)
        return 64
    developer_dir = Path(developer_dir_value)
    strict_runner = require_file(ROOT / "scripts/run-swift-strict.py", "strict Swift runner")

    build = subprocess.run(
        [
            sys.executable,
            str(strict_runner),
            "build",
            "--scratch-path",
            str(SCRATCH),
            "--triple",
            TRIPLE,
            "--build-tests",
        ],
        cwd=ROOT,
        env=environment,
        check=False,
    )
    if build.returncode != 0:
        return build.returncode

    bin_path_result = subprocess.run(
        [
            "xcrun",
            "swift",
            "build",
            "--scratch-path",
            str(SCRATCH),
            "--triple",
            TRIPLE,
            "--show-bin-path",
        ],
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if bin_path_result.returncode != 0:
        print(bin_path_result.stdout, file=sys.stderr)
        return bin_path_result.returncode
    bin_path = Path(bin_path_result.stdout.strip())
    bundle = bin_path / "FoveaTests.xctest"
    executable = require_file(bundle / "Contents/MacOS/FoveaTests", "x86_64 test executable")
    executable_architectures = lipo_architectures(executable, environment)
    if executable_architectures != ["x86_64"]:
        print(
            f"error: expected x86_64-only test executable, got {executable_architectures}",
            file=sys.stderr,
        )
        return 65

    runner = require_file(developer_dir / "usr/bin/xctest", "XCTest runner")
    runner_architectures = lipo_architectures(runner, environment)
    if "x86_64" not in runner_architectures:
        print(f"error: XCTest runner has no x86_64 slice: {runner_architectures}", file=sys.stderr)
        return 66

    platform_developer = developer_dir / "Platforms/MacOSX.platform/Developer"
    append_search_path(
        environment,
        "DYLD_FRAMEWORK_PATH",
        platform_developer / "Library/Frameworks",
    )
    append_search_path(
        environment,
        "DYLD_LIBRARY_PATH",
        platform_developer / "usr/lib",
    )
    environment["FOVEA_EXPECTED_TEST_ARCH"] = "x86_64"

    command = xctest_command(runner, bundle)
    completed = subprocess.run(
        command,
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    sys.stdout.write(completed.stdout)
    if completed.returncode != 0:
        return completed.returncode
    required_output = (
        "testPersistentIdentityGoldenVectorsAreArchitectureStable_CACHE_PT_017]' passed",
        "Executed 1 test, with 0 failures",
    )
    missing = [marker for marker in required_output if marker not in completed.stdout]
    if missing:
        print(f"error: x86_64 identity output missing markers: {missing}", file=sys.stderr)
        return 67
    print(
        "x86_64 identity vector passed under Rosetta: "
        f"bundle={bundle} selector={TEST_SELECTOR}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
