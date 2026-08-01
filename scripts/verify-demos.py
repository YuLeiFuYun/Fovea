#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from swift_tooling import build_product, selected_environment

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
    env = selected_environment(ROOT)
    try:
        network_lab = build_product(ROOT, env, "FoveaNetworkLab")
        _ = build_product(ROOT, env, "FoveaGalleryDemo")
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1

    refusal = run([str(network_lab)], env)
    if refusal.returncode != 2 or "--live" not in refusal.stderr:
        print(refusal.stdout, file=sys.stderr)
        print(refusal.stderr, file=sys.stderr)
        print("FoveaNetworkLab must refuse execution without explicit --live", file=sys.stderr)
        return 1

    print(
        "Demo verification passed: products build and the NetworkLab binary "
        "refuses implicit network execution."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
