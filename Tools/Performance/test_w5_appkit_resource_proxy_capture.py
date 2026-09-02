#!/usr/bin/env python3
from __future__ import annotations
import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).with_name("capture_w5_appkit_resource_proxy.py")
spec = importlib.util.spec_from_file_location("capture_w5_appkit_resource_proxy", SCRIPT)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

SAMPLE = """        10.42 real         0.31 user         0.09 sys
            43139072  maximum resident set size
                  98  voluntary context switches
                3094  involuntary context switches
           580824353  instructions retired
           659593539  cycles elapsed
            10224528  peak memory footprint
"""

def report(mode: str) -> dict[str, object]:
    control, driver = module.CONTROL[mode]
    value: dict[str, object] = {
        "schemaVersion": 1,
        "evidenceVersion": "fovea-appkit-physical-resource-proxy-v1",
        "schedulingControl": control,
        "driverSchedulingMode": driver,
        "requestedDurationNanoseconds": module.DURATION_SECONDS * 1_000_000_000,
        "measuredDurationNanoseconds": module.DURATION_SECONDS * 1_000_000_000 + 20_000_000,
        "providerFrameCount": 120,
        "registeredDriverCountAfterCancel": 0,
        "providerCancelCountAfterCancel": 1,
        "thermalStateBefore": "nominal",
        "thermalStateAfter": "nominal",
        "checks": {"all": True},
    }
    if mode == "external":
        value["presentationTargetAcceptedCount"] = 600
    return value


def main() -> int:
    parsed = module.parse_time_l(SAMPLE)
    assert parsed["totalCPUSeconds"] == 0.4, parsed
    assert parsed["totalContextSwitches"] == 3192, parsed
    assert parsed["cyclesElapsed"] == 659593539, parsed
    assert parsed["instructionsRetired"] == 580824353, parsed
    assert module.validate_report(report("external"), "external") == []
    assert module.validate_report(report("deadline"), "deadline") == []
    bad = report("deadline"); bad["presentationTargetAcceptedCount"] = 1
    assert "deadline control unexpectedly owns presentation-target diagnostics" in module.validate_report(bad, "deadline")
    short = report("external"); short["measuredDurationNanoseconds"] = 1
    assert "measured duration outside bounded wall-time window" in module.validate_report(short, "external")
    print("W5 AppKit resource proxy capture contract passed")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
