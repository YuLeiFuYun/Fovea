#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

SCRIPT = Path(__file__).with_name("capture_w5_appkit_deadline_clock_experiment.py")
spec = importlib.util.spec_from_file_location("capture_w5_appkit_deadline_clock_experiment", SCRIPT)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def main() -> int:
    assert module.block_order(1, "timing") == ("external", "taskDeadline", "strictDeadline")
    assert module.block_order(2, "timing") == ("taskDeadline", "strictDeadline", "external")
    assert module.block_order(3, "timing") == ("strictDeadline", "external", "taskDeadline")
    assert module.block_order(1, "resource") == ("taskDeadline", "strictDeadline", "external")
    assert module.block_order(6, "resource") == ("external", "taskDeadline", "strictDeadline")
    assert module.mode_arguments("external") == ["--scheduling-control", "platform-default"]
    assert module.mode_arguments("taskDeadline") == ["--scheduling-control", "automatic-deadline"]
    assert module.mode_arguments("strictDeadline") == [
        "--scheduling-control", "automatic-deadline", "--deadline-clock", "strict-dispatch"
    ]
    assert module.validate_clock_binding({"deadlineClockControl": "strict-dispatch"}, "strictDeadline") == []
    assert module.validate_clock_binding({"deadlineClockControl": "system-task-sleep"}, "strictDeadline")
    assert module.ratio(3, 2) == 1.5
    assert module.ratio(3, 0) is None
    print("W5 AppKit deadline-clock experiment contract passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
