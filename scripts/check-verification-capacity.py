#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MINIMUM_FREE_BYTES = 2 * 1024 * 1024 * 1024
MAXIMUM_CONFIGURED_FREE_BYTES = 1024 * 1024 * 1024 * 1024


def configured_minimum_free_bytes() -> int:
    raw = os.environ.get("FOVEA_VERIFY_MIN_FREE_BYTES")
    if raw is None or not raw.strip():
        return DEFAULT_MINIMUM_FREE_BYTES
    try:
        value = int(raw)
    except ValueError as error:
        raise ValueError("FOVEA_VERIFY_MIN_FREE_BYTES must be an integer") from error
    if value < 0 or value > MAXIMUM_CONFIGURED_FREE_BYTES:
        raise ValueError("FOVEA_VERIFY_MIN_FREE_BYTES is outside the supported range")
    return value


def capacity_report(
    root: Path = ROOT,
    *,
    minimum_free_bytes: int | None = None,
) -> dict[str, int | bool | str]:
    minimum = configured_minimum_free_bytes() if minimum_free_bytes is None else minimum_free_bytes
    if minimum < 0 or minimum > MAXIMUM_CONFIGURED_FREE_BYTES:
        raise ValueError("minimum free bytes is outside the supported range")
    usage = shutil.disk_usage(root)
    return {
        "path": str(root),
        "minimumFreeBytes": minimum,
        "availableFreeBytes": usage.free,
        "totalBytes": usage.total,
        "usedBytes": usage.used,
        "passed": usage.free >= minimum,
    }


def main() -> int:
    try:
        report = capacity_report()
    except (OSError, ValueError) as error:
        print(json.dumps({"passed": False, "error": str(error)}, sort_keys=True))
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
