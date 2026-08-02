#!/usr/bin/env python3
"""用精确分数实现 DRF progressive filling，并检查公平性质与误报反例。"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from fractions import Fraction
import argparse
import itertools
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / ".artifacts/mathematics/multi-resource-fairness.json"


@dataclass(frozen=True)
class User:
    name: str
    demand: tuple[int, ...]


@dataclass(frozen=True)
class Scenario:
    name: str
    capacities: tuple[int, ...]
    users: tuple[User, ...]


def dominant_coefficient(user: User, capacities: tuple[int, ...]) -> Fraction:
    return max(Fraction(demand, capacity) for demand, capacity in zip(user.demand, capacities))


def drf_allocate(
    users: tuple[User, ...], capacities: tuple[int, ...]
) -> tuple[Fraction, ...]:
    if not users or any(capacity <= 0 for capacity in capacities):
        raise ValueError("DRF 需要非空用户和正资源容量")
    if any(len(user.demand) != len(capacities) for user in users):
        raise ValueError("资源向量维度不一致")
    if any(all(value == 0 for value in user.demand) or any(value < 0 for value in user.demand) for user in users):
        raise ValueError("每个用户必须声明非负且非零的资源需求")

    dominant = tuple(dominant_coefficient(user, capacities) for user in users)
    allocation = [Fraction(0) for _ in users]
    remaining = [Fraction(value) for value in capacities]
    active = set(range(len(users)))

    while active:
        candidate_steps: list[tuple[Fraction, int]] = []
        for resource in range(len(capacities)):
            rate = sum(
                Fraction(users[index].demand[resource], 1) / dominant[index]
                for index in active
            )
            if rate > 0:
                candidate_steps.append((remaining[resource] / rate, resource))
        if not candidate_steps:
            break
        step = min(value for value, _ in candidate_steps)
        if step < 0:
            raise RuntimeError("DRF progressive filling 产生负步长")

        for index in active:
            allocation[index] += step / dominant[index]
        for resource in range(len(capacities)):
            used = sum(
                step / dominant[index] * users[index].demand[resource]
                for index in active
            )
            remaining[resource] -= used
            if remaining[resource] < 0 and abs(remaining[resource]) < Fraction(1, 10**12):
                remaining[resource] = Fraction(0)

        saturated = {
            resource
            for value, resource in candidate_steps
            if value == step
        }
        frozen = {
            index
            for index in active
            if any(users[index].demand[resource] > 0 for resource in saturated)
        }
        if not frozen:
            raise RuntimeError("DRF 未能冻结任何活动用户")
        active -= frozen

    return tuple(allocation)


def resource_use(
    users: tuple[User, ...], allocation: tuple[Fraction, ...], resources: int
) -> tuple[Fraction, ...]:
    return tuple(
        sum(allocation[index] * users[index].demand[resource] for index in range(len(users)))
        for resource in range(resources)
    )


def dominant_shares(
    users: tuple[User, ...], allocation: tuple[Fraction, ...], capacities: tuple[int, ...]
) -> tuple[Fraction, ...]:
    return tuple(
        max(
            allocation[index] * users[index].demand[resource] / capacities[resource]
            for resource in range(len(capacities))
        )
        for index in range(len(users))
    )


def true_utility(
    true_demand: tuple[int, ...],
    reported_demand: tuple[int, ...],
    reported_tasks: Fraction,
) -> Fraction:
    return min(
        reported_tasks * reported / true
        for true, reported in zip(true_demand, reported_demand)
        if true > 0
    )


def strategy_probe(scenario: Scenario, user_index: int) -> dict[str, object]:
    truthful_allocation = drf_allocate(scenario.users, scenario.capacities)
    true_demand = scenario.users[user_index].demand
    truthful_utility = truthful_allocation[user_index]
    maximum_gain = Fraction(0)
    best_report = true_demand
    reports_checked = 0

    value_domains = [range(1, max(4, value + 2)) for value in true_demand]
    for report in itertools.product(*value_domains):
        reports_checked += 1
        users = list(scenario.users)
        users[user_index] = User(users[user_index].name, tuple(report))
        allocation = drf_allocate(tuple(users), scenario.capacities)
        utility = true_utility(true_demand, tuple(report), allocation[user_index])
        gain = utility - truthful_utility
        if gain > maximum_gain:
            maximum_gain = gain
            best_report = tuple(report)

    return {
        "user": scenario.users[user_index].name,
        "reportsChecked": reports_checked,
        "truthfulUtility": fraction_json(truthful_utility),
        "maximumMisreportGain": fraction_json(maximum_gain),
        "bestMisreport": list(best_report),
        "strategyProofOnFiniteReportDomain": maximum_gain <= 0,
    }


def fraction_json(value: Fraction) -> dict[str, object]:
    return {
        "numerator": value.numerator,
        "denominator": value.denominator,
        "decimal": float(value),
    }


def scenario_report(scenario: Scenario) -> dict[str, object]:
    allocation = drf_allocate(scenario.users, scenario.capacities)
    use = resource_use(scenario.users, allocation, len(scenario.capacities))
    shares = dominant_shares(scenario.users, allocation, scenario.capacities)
    user_count = len(scenario.users)
    sharing_floor = Fraction(1, user_count)

    capacity_feasible = all(use[index] <= scenario.capacities[index] for index in range(len(use)))
    at_least_one_saturated = any(use[index] == scenario.capacities[index] for index in range(len(use)))
    sharing_incentive = all(share >= sharing_floor for share in shares)
    probes = [strategy_probe(scenario, index) for index in range(len(scenario.users))]

    return {
        "name": scenario.name,
        "capacities": list(scenario.capacities),
        "users": [
            {
                "name": user.name,
                "demand": list(user.demand),
                "allocatedTasks": fraction_json(allocation[index]),
                "dominantShare": fraction_json(shares[index]),
            }
            for index, user in enumerate(scenario.users)
        ],
        "resourceUse": [fraction_json(value) for value in use],
        "invariants": {
            "capacityFeasible": capacity_feasible,
            "atLeastOneResourceSaturated": at_least_one_saturated,
            "sharingIncentive": sharing_incentive,
            "finiteStrategyProbePassed": all(
                probe["strategyProofOnFiniteReportDomain"] for probe in probes
            ),
        },
        "strategyProbes": probes,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    scenarios = (
        Scenario(
            "fetch-decode-disk-asymmetric",
            (12, 12, 12),
            (
                User("network-heavy", (4, 1, 1)),
                User("decode-heavy", (1, 4, 1)),
                User("disk-heavy", (1, 1, 4)),
            ),
        ),
        Scenario(
            "public-private-mixed-demand",
            (24, 16, 20),
            (
                User("public-feed", (3, 2, 1)),
                User("private-gallery", (2, 4, 2)),
                User("analysis", (1, 3, 5)),
                User("hero", (5, 2, 2)),
            ),
        ),
        Scenario(
            "partial-resource-users",
            (18, 18, 12),
            (
                User("memory-only", (0, 3, 1)),
                User("network-only", (4, 0, 1)),
                User("balanced", (2, 2, 2)),
            ),
        ),
    )
    reports = [scenario_report(scenario) for scenario in scenarios]
    invariants = {
        name: all(report["invariants"][name] for report in reports)
        for name in (
            "capacityFeasible",
            "atLeastOneResourceSaturated",
            "sharingIncentive",
            "finiteStrategyProbePassed",
        )
    }
    report = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "scenarios": reports,
        "invariants": invariants,
        "claimBoundary": (
            "该分析用精确有理数执行三个有限资源向量场景，并在有限整数误报域中搜索"
            "获益反例。它提供 DRF 的实现基线，不证明未来 Fovea 工作负载估计准确，也"
            "不处理任务不可分割、时间变化、优先级或跨阶段抢占。"
        ),
    }
    output = args.output if args.output.is_absolute() else ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    print("Multi-resource fairness analysis:")
    for item in reports:
        shares = [user["dominantShare"]["decimal"] for user in item["users"]]
        print(f"  {item['name']}: dominant-shares={shares}")
    print(f"Artifact: {output.relative_to(ROOT)}")
    failed = [name for name, passed in invariants.items() if not passed]
    if failed:
        raise SystemExit(f"DRF 有限分析失败：{failed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
