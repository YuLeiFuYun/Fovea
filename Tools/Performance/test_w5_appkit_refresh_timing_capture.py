#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).with_name("capture_w5_appkit_refresh_timing.py")
spec = importlib.util.spec_from_file_location("capture_w5_appkit_refresh_timing", SCRIPT)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def report(mode: str, observations: list[tuple[int, int]]) -> dict[str, object]:
    control, driver = module.CONTROL[mode]
    return {
        "schemaVersion": 1,
        "evidenceVersion": "fovea-appkit-physical-refresh-sampled-timing-v1",
        "schedulingControl": control,
        "driverSchedulingMode": driver,
        "frameCount": 3,
        "frameDurationsNanoseconds": [10, 10, 10],
        "playbackStartNanoseconds": 100,
        "firstRefreshTimestampNanoseconds": 105,
        "firstRefreshOffsetFromPlaybackStartNanoseconds": 5,
        "refreshSampleCount": 7,
        "refreshIntervalsNanoseconds": [5, 5, 5, 5, 5, 5],
        "observations": [
            {"sequence": index, "elapsedNanoseconds": elapsed, "frameIndex": frame}
            for index, (elapsed, frame) in enumerate(observations)
        ],
        "observedSourceOrdinal": 3,
        "registeredDriverCountAfterCancel": 0,
        "checks": {"all": True},
    }


def main() -> int:
    exact = report("external", [(0, 0), (5, 1), (15, 2), (25, 0)])
    assert module.validate_report(exact, "external") == []
    exact_score = module.score_report(exact, 10)
    anchored_exact = module.score_report_anchored(exact, 10)
    assert exact_score["observedSkippedSourceFrameCount"] == 0
    assert anchored_exact["missedDeadlineCount"] == 0
    assert anchored_exact["earlyDeadlineCount"] == 0
    assert anchored_exact["p95AbsoluteTimingErrorNanoseconds"] == 0

    skipped = report("deadline", [(0, 0), (15, 2), (25, 0)])
    assert module.validate_report(skipped, "deadline") == []
    skipped_score = module.score_report_anchored(skipped, 10)
    assert skipped_score["observedSkippedSourceFrameCount"] == 1
    assert skipped_score["observedAbsoluteSourceOrdinal"] == 3

    wrong_mode = report("external", [(0, 0), (5, 1), (15, 2), (25, 0)])
    wrong_mode["driverSchedulingMode"] = "automatic-deadline-loop"
    assert "driver scheduling mode mismatch" in module.validate_report(wrong_mode, "external")

    regressing = report("external", [(0, 0), (20, 1), (10, 2), (30, 0)])
    errors = module.validate_report(regressing, "external")
    assert any("strictly monotonic" in item for item in errors), errors

    incomplete = report("deadline", [(0, 0), (10, 1)])
    incomplete["observedSourceOrdinal"] = 1
    assert "source progression did not reach one full loop" in module.validate_report(incomplete, "deadline")

    bad_cadence = report("external", [(0, 0), (5, 1), (15, 2), (25, 0)])
    bad_cadence["refreshSampleCount"] = 8
    assert "refresh sample count diverges from interval count" in module.validate_report(
        bad_cadence, "external"
    )

    print("W5 AppKit refresh timing capture contract passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
