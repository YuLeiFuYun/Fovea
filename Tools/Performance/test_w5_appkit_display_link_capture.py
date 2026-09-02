#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).with_name("capture_w5_appkit_display_link.py")
spec = importlib.util.spec_from_file_location("capture_w5_appkit_display_link", SCRIPT)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def stage(accepted: int, consumed: int, provider: int, *, paused: bool, visible: bool) -> dict[str, object]:
    return {
        "presentation": {
            "acceptedTargetCount": accepted,
            "consumedTargetCount": consumed,
            "supersededPendingTargetCount": accepted - consumed,
            "rejectedNonmonotonicTargetCount": 0,
            "lifecycleClearedPendingTargetCount": 0,
            "hasPendingTarget": False,
            "lastAcceptedTargetNanoseconds": accepted,
            "isDisplayLinkPaused": paused,
            "effectiveVisibility": visible,
        },
        "providerWindowCalls": provider,
        "providerFrameCount": provider,
    }


def valid_report() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "evidenceVersion": "fovea-appkit-physical-display-link-mechanism-v1",
        "checks": {"all": True},
        "active": stage(10, 9, 8, paused=False, visible=True),
        "hiddenSettled": stage(11, 10, 9, paused=True, visible=False),
        "hiddenEnd": stage(11, 10, 9, paused=True, visible=False),
        "resumed": stage(20, 18, 12, paused=False, visible=True),
        "registeredDriverCountAfterCancel": 0,
    }


def main() -> int:
    report = valid_report()
    assert module.validate_report(report) == []

    hidden_work = valid_report()
    hidden_work["hiddenEnd"]["providerFrameCount"] = 10
    assert "provider work advanced while hidden" in module.validate_report(hidden_work)

    no_resume = valid_report()
    no_resume["resumed"]["presentation"]["acceptedTargetCount"] = 11
    assert "display targets did not resume" in module.validate_report(no_resume)

    paused_resume = valid_report()
    paused_resume["resumed"]["presentation"]["isDisplayLinkPaused"] = True
    assert "resumed stage is not visible/unpaused" in module.validate_report(paused_resume)

    leaked = valid_report()
    leaked["registeredDriverCountAfterCancel"] = 1
    assert "runtime driver remained registered after cancel" in module.validate_report(leaked)

    print("W5 AppKit display-link capture contract passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
