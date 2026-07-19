#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(command: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def main() -> int:
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = subprocess.run(
        [str(ROOT / "scripts/select-xcode.sh")],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()

    for product in ("FoveaNetworkLab", "FoveaGalleryDemo"):
        completed = run(
            ["xcrun", "swift", "build", "--product", product, "-Xswiftc", "-warnings-as-errors"],
            env,
        )
        if completed.returncode != 0:
            print(completed.stdout, file=sys.stderr)
            print(completed.stderr, file=sys.stderr)
            print(f"Demo build failed: {product}", file=sys.stderr)
            return 1

    refusal = run(
        ["xcrun", "swift", "run", "--skip-build", "FoveaNetworkLab"],
        env,
    )
    if refusal.returncode != 2 or "--live" not in refusal.stderr:
        print(refusal.stdout, file=sys.stderr)
        print(refusal.stderr, file=sys.stderr)
        print("FoveaNetworkLab must refuse network access without explicit --live", file=sys.stderr)
        return 1

    print("Demo verification passed: both products build and live networking is opt-in.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
