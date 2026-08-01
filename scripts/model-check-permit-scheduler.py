#!/usr/bin/env python3
"""穷举带权许可池的容量守恒与防饥饿保留反例族。"""

from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / ".artifacts/mathematics/permit-scheduler-model.json"
BYPASS_LIMIT = 8


@dataclass(frozen=True)
class Waiter:
    name: str
    units: int
    sequence: int
    work: int
    bypasses: int = 0


def choose(
    waiters: tuple[Waiter, ...], available: int, reservation_enabled: bool
) -> tuple[int | None, str | None]:
    starved = sorted(
        (item for item in waiters if item.bypasses >= BYPASS_LIMIT),
        key=lambda item: item.sequence,
    )
    if reservation_enabled and starved:
        reserved = starved[0]
        if reserved.units > available:
            return None, reserved.name
        return waiters.index(reserved), reserved.name

    fitting = [item for item in waiters if item.units <= available]
    if not fitting:
        return None, None
    selected = min(fitting, key=lambda item: (item.work, item.sequence))
    return waiters.index(selected), None


def run_case(capacity: int, reservation_enabled: bool) -> dict[str, object]:
    anchor_units = capacity - 1
    available = 1
    waiters: tuple[Waiter, ...] = (
        Waiter("whole-capacity", capacity, 0, 10_000),
        *(Waiter(f"small-{index}", 1, index + 1, 1) for index in range(BYPASS_LIMIT + 1)),
    )
    order: list[str] = []
    reserved_before_drain: str | None = None

    # 小任务立即完成并返还一个单位；长期 anchor 在 drain 之后才释放。
    while True:
        selected_index, reserved = choose(waiters, available, reservation_enabled)
        if selected_index is None:
            reserved_before_drain = reserved
            break
        selected = waiters[selected_index]
        assert selected.units <= available
        available -= selected.units
        remaining = tuple(
            replace(item, bypasses=min(BYPASS_LIMIT, item.bypasses + 1))
            for index, item in enumerate(waiters)
            if index != selected_index
        )
        order.append(selected.name)
        available += selected.units
        waiters = remaining
        if selected.name == "whole-capacity":
            break

    pre_drain_order = list(order)
    available += anchor_units
    assert available == capacity

    while waiters:
        selected_index, _ = choose(waiters, available, reservation_enabled)
        if selected_index is None:
            raise AssertionError("anchor 释放后仍无可调度请求")
        selected = waiters[selected_index]
        if selected.units > available:
            raise AssertionError("模型发生容量超配")
        available -= selected.units
        order.append(selected.name)
        waiters = tuple(item for index, item in enumerate(waiters) if index != selected_index)
        available += selected.units

    expected_prefix = [f"small-{index}" for index in range(BYPASS_LIMIT)]
    canonical_passed = (
        pre_drain_order == expected_prefix
        and reserved_before_drain == "whole-capacity"
        and order[BYPASS_LIMIT : BYPASS_LIMIT + 2] == ["whole-capacity", "small-8"]
        and available == capacity
    )
    return {
        "capacity": capacity,
        "anchorUnits": anchor_units,
        "preDrainOrder": pre_drain_order,
        "reservedBeforeDrain": reserved_before_drain,
        "finalOrder": order,
        "canonicalPassed": canonical_passed,
    }


def main() -> int:
    canonical = [run_case(capacity, True) for capacity in range(2, 9)]
    mutant = [run_case(capacity, False) for capacity in range(2, 9)]
    mutant_counterexamples = [
        case
        for case in mutant
        if case["finalOrder"].index("small-8")
        < case["finalOrder"].index("whole-capacity")
    ]
    source = ROOT / "Sources/FoveaCore/AsyncPermitPool.swift"
    report = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "finiteDomain": {
            "capacity": [2, 3, 4, 5, 6, 7, 8],
            "bypassLimit": BYPASS_LIMIT,
            "smallWaiters": BYPASS_LIMIT + 1,
            "longRunningAnchorUnits": "capacity - 1",
            "wholeCapacityWaiterUnits": "capacity",
        },
        "invariants": {
            "capacityConserved": all(case["canonicalPassed"] for case in canonical),
            "starvedWeightedWaiterReservesNextSufficientCapacity": all(
                case["reservedBeforeDrain"] == "whole-capacity" for case in canonical
            ),
            "noLaterSmallWaiterConsumesReservedFragment": all(
                case["preDrainOrder"] == [f"small-{index}" for index in range(BYPASS_LIMIT)]
                for case in canonical
            ),
        },
        "canonicalCases": canonical,
        "mutant": {
            "name": "fitting-only-aging-without-capacity-reservation",
            "counterexampleCount": len(mutant_counterexamples),
            "counterexamples": mutant_counterexamples,
        },
        "claimBoundary": (
            "该检查穷举一个参数化碎片化反例族，证明容量保留规则能杀死旧调度器的已知反例；"
            "它不证明任意到达过程、执行时长或多资源调度的无限状态活性。"
        ),
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    passed = all(case["canonicalPassed"] for case in canonical) and len(
        mutant_counterexamples
    ) == len(mutant)
    print(
        "Permit scheduler model: "
        f"cases={len(canonical)} canonicalPassed={all(case['canonicalPassed'] for case in canonical)} "
        f"mutantCounterexamples={len(mutant_counterexamples)}/{len(mutant)}"
    )
    print(f"Artifact: {OUTPUT.relative_to(ROOT)}")
    if not passed:
        print("error: 带权许可池有限模型未满足预期", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
