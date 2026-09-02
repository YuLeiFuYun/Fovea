#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import os
import sys
from collections import namedtuple
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("check-verification-capacity.py")
spec = importlib.util.spec_from_file_location("fovea_verification_capacity", SCRIPT)
assert spec is not None and spec.loader is not None
capacity = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = capacity
spec.loader.exec_module(capacity)
DiskUsage = namedtuple("DiskUsage", "total used free")


def main() -> int:
    with patch.object(capacity.shutil, "disk_usage", return_value=DiskUsage(100, 60, 40)):
        assert capacity.capacity_report(minimum_free_bytes=40)["passed"] is True
        assert capacity.capacity_report(minimum_free_bytes=41)["passed"] is False
    original = os.environ.get("FOVEA_VERIFY_MIN_FREE_BYTES")
    try:
        os.environ["FOVEA_VERIFY_MIN_FREE_BYTES"] = "1234"
        assert capacity.configured_minimum_free_bytes() == 1234
        os.environ["FOVEA_VERIFY_MIN_FREE_BYTES"] = "not-an-integer"
        try:
            capacity.configured_minimum_free_bytes()
        except ValueError as error:
            assert "must be an integer" in str(error)
        else:
            raise AssertionError("invalid capacity configuration must fail")
        os.environ["FOVEA_VERIFY_MIN_FREE_BYTES"] = "-1"
        try:
            capacity.configured_minimum_free_bytes()
        except ValueError as error:
            assert "supported range" in str(error)
        else:
            raise AssertionError("negative capacity configuration must fail")
    finally:
        if original is None:
            os.environ.pop("FOVEA_VERIFY_MIN_FREE_BYTES", None)
        else:
            os.environ["FOVEA_VERIFY_MIN_FREE_BYTES"] = original
    print("verification capacity contract passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
