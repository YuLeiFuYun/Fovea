#!/usr/bin/env python3
"""对已验证编码 handoff 的有限 trace 求精确 oracle，并比较在线文件缓存策略。"""
from __future__ import annotations

from dataclasses import dataclass
from fractions import Fraction
from itertools import combinations, product
import json
from pathlib import Path
from statistics import mean

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / ".artifacts/mathematics/encoded-handoff-policy-analysis.json"


@dataclass(frozen=True)
class ObjectSpec:
    key: str
    size: int
    cost: int


@dataclass(frozen=True)
class Scenario:
    name: str
    capacity: int
    objects: tuple[ObjectSpec, ...]
    maximum_trace_length: int


SCENARIOS = (
    Scenario(
        name="uniform",
        capacity=2,
        objects=(
            ObjectSpec("a", 1, 1),
            ObjectSpec("b", 1, 1),
            ObjectSpec("c", 1, 1),
        ),
        maximum_trace_length=7,
    ),
    Scenario(
        name="mixed-size",
        capacity=4,
        objects=(
            ObjectSpec("a", 1, 1),
            ObjectSpec("b", 2, 1),
            ObjectSpec("c", 3, 1),
        ),
        maximum_trace_length=7,
    ),
    Scenario(
        name="mixed-retrieval-cost",
        capacity=4,
        objects=(
            ObjectSpec("a", 1, 1),
            ObjectSpec("b", 2, 4),
            ObjectSpec("c", 3, 9),
        ),
        maximum_trace_length=7,
    ),
    Scenario(
        name="large-expensive-versus-small-scan",
        capacity=5,
        objects=(
            ObjectSpec("a", 1, 1),
            ObjectSpec("b", 1, 1),
            ObjectSpec("c", 4, 12),
        ),
        maximum_trace_length=8,
    ),
)


def feasible_subsets(objects: tuple[ObjectSpec, ...], capacity: int) -> tuple[frozenset[str], ...]:
    by_key = {item.key: item for item in objects}
    keys = tuple(by_key)
    subsets: list[frozenset[str]] = []
    for length in range(len(keys) + 1):
        for values in combinations(keys, length):
            if sum(by_key[key].size for key in values) <= capacity:
                subsets.append(frozenset(values))
    return tuple(subsets)


def exact_offline_cost(scenario: Scenario, trace: tuple[str, ...]) -> int:
    by_key = {item.key: item for item in scenario.objects}
    feasible = feasible_subsets(scenario.objects, scenario.capacity)
    current: dict[frozenset[str], int] = {frozenset(): 0}
    for requested in trace:
        next_cost: dict[frozenset[str], int] = {}
        for resident, cost in current.items():
            miss = requested not in resident
            available = resident | {requested}
            request_cost = by_key[requested].cost if miss else 0
            for after in feasible:
                if after <= available:
                    candidate = cost + request_cost
                    previous = next_cost.get(after)
                    if previous is None or candidate < previous:
                        next_cost[after] = candidate
        current = next_cost
    return min(current.values())


class LRU:
    def __init__(self, scenario: Scenario):
        self.scenario = scenario
        self.by_key = {item.key: item for item in scenario.objects}
        self.order: list[str] = []
        self.cost = 0

    def request(self, key: str) -> None:
        if key in self.order:
            self.order.remove(key)
            self.order.append(key)
            return
        item = self.by_key[key]
        self.cost += item.cost
        if item.size > self.scenario.capacity:
            return
        while self.resident_size() + item.size > self.scenario.capacity:
            self.order.pop(0)
        self.order.append(key)

    def resident_size(self) -> int:
        return sum(self.by_key[key].size for key in self.order)


class SIEVE:
    def __init__(self, scenario: Scenario):
        self.scenario = scenario
        self.by_key = {item.key: item for item in scenario.objects}
        self.order: list[str] = []
        self.visited: set[str] = set()
        self.hand: str | None = None
        self.cost = 0

    def request(self, key: str) -> None:
        if key in self.order:
            self.visited.add(key)
            return
        item = self.by_key[key]
        self.cost += item.cost
        if item.size > self.scenario.capacity:
            return
        while self.resident_size() + item.size > self.scenario.capacity:
            victim = self.next_victim()
            self.remove(victim)
        self.order.append(key)

    def resident_size(self) -> int:
        return sum(self.by_key[key].size for key in self.order)

    def next_victim(self) -> str:
        if self.hand not in self.order:
            self.hand = self.order[0]
        while True:
            assert self.hand is not None
            index = self.order.index(self.hand)
            candidate = self.hand
            next_key = self.order[(index + 1) % len(self.order)]
            if candidate in self.visited:
                self.visited.remove(candidate)
                self.hand = next_key
                continue
            self.hand = next_key if len(self.order) > 1 else None
            return candidate

    def remove(self, key: str) -> None:
        index = self.order.index(key)
        self.order.remove(key)
        self.visited.discard(key)
        if not self.order:
            self.hand = None
        elif self.hand == key or self.hand not in self.order:
            self.hand = self.order[index % len(self.order)]


class Landlord:
    """Landlord 的精确有理数研究实现；zero-credit tie 规则必须显式选择。"""

    def __init__(self, scenario: Scenario, *, flush_all_zero: bool):
        self.scenario = scenario
        self.by_key = {item.key: item for item in scenario.objects}
        self.credits: dict[str, Fraction] = {}
        self.recency: list[str] = []
        self.flush_all_zero = flush_all_zero
        self.cost = 0

    def request(self, key: str) -> None:
        item = self.by_key[key]
        if key in self.credits:
            # Young 的第 7 步允许把 credit 提升到当前值与 cost 之间；此变体取上界。
            self.credits[key] = Fraction(item.cost)
            self.touch(key)
            return
        self.cost += item.cost
        if item.size > self.scenario.capacity:
            return
        while self.resident_size() + item.size > self.scenario.capacity:
            delta = min(
                self.credits[resident] / self.by_key[resident].size
                for resident in self.credits
            )
            for resident in tuple(self.credits):
                self.credits[resident] -= delta * self.by_key[resident].size
            zero = [key for key in self.recency if self.credits.get(key) == 0]
            if not zero:
                raise AssertionError("Landlord pressure step produced no zero-credit object")
            victims = zero if self.flush_all_zero else zero[:1]
            for victim in victims:
                del self.credits[victim]
                self.recency.remove(victim)
        self.credits[key] = Fraction(item.cost)
        self.touch(key)

    def touch(self, key: str) -> None:
        if key in self.recency:
            self.recency.remove(key)
        self.recency.append(key)

    def resident_size(self) -> int:
        return sum(self.by_key[key].size for key in self.credits)


class LandlordLRUTie(Landlord):
    def __init__(self, scenario: Scenario):
        super().__init__(scenario, flush_all_zero=False)


class LandlordFlushTie(Landlord):
    def __init__(self, scenario: Scenario):
        super().__init__(scenario, flush_all_zero=True)

def policy_cost(policy_type: type[LRU] | type[SIEVE] | type[Landlord], scenario: Scenario, trace: tuple[str, ...]) -> int:
    policy = policy_type(scenario)
    for key in trace:
        policy.request(key)
    return policy.cost


def analyze(scenario: Scenario) -> dict[str, object]:
    keys = tuple(item.key for item in scenario.objects)
    policy_types = {
        "lru": LRU,
        "sieve": SIEVE,
        "landlord-lru-tie": LandlordLRUTie,
        "landlord-flush-tie": LandlordFlushTie,
    }
    totals = {name: 0 for name in policy_types}
    regrets = {name: [] for name in policy_types}
    ratios = {name: [] for name in policy_types}
    worst: dict[str, tuple[int, tuple[str, ...], int, int] | None] = {
        name: None for name in policy_types
    }
    pairwise_wins = {
        left: {right: 0 for right in policy_types if right != left}
        for left in policy_types
    }
    trace_count = 0

    for length in range(1, scenario.maximum_trace_length + 1):
        for trace in product(keys, repeat=length):
            trace_count += 1
            oracle = exact_offline_cost(scenario, trace)
            costs = {
                name: policy_cost(policy_type, scenario, trace)
                for name, policy_type in policy_types.items()
            }
            for name, cost in costs.items():
                if cost < oracle:
                    raise AssertionError(f"{scenario.name}:{name} beat oracle on {trace}")
                regret = cost - oracle
                ratio = Fraction(cost, oracle) if oracle > 0 else Fraction(1)
                totals[name] += cost
                regrets[name].append(regret)
                ratios[name].append(float(ratio))
                previous = worst[name]
                if previous is None or regret > previous[0]:
                    worst[name] = (regret, trace, cost, oracle)
            for left in policy_types:
                for right in policy_types:
                    if left != right and costs[left] < costs[right]:
                        pairwise_wins[left][right] += 1

    policies: dict[str, object] = {}
    for name in policy_types:
        assert worst[name] is not None
        regret, trace, cost, oracle = worst[name]
        policies[name] = {
            "aggregateCost": totals[name],
            "meanRegret": mean(regrets[name]),
            "maximumRegret": regret,
            "maximumCompetitiveRatioObserved": max(ratios[name]),
            "worstTrace": list(trace),
            "worstTraceCost": cost,
            "worstTraceOracle": oracle,
            "pairwiseStrictWins": pairwise_wins[name],
        }

    domination: list[dict[str, object]] = []
    for left in policy_types:
        for right in policy_types:
            if left == right:
                continue
            left_never_worse = True
            left_strict = False
            for length in range(1, scenario.maximum_trace_length + 1):
                for trace in product(keys, repeat=length):
                    lc = policy_cost(policy_types[left], scenario, trace)
                    rc = policy_cost(policy_types[right], scenario, trace)
                    if lc > rc:
                        left_never_worse = False
                        break
                    left_strict = left_strict or lc < rc
                if not left_never_worse:
                    break
            if left_never_worse and left_strict:
                domination.append({"dominates": left, "dominated": right})

    return {
        "name": scenario.name,
        "capacity": scenario.capacity,
        "objects": [item.__dict__ for item in scenario.objects],
        "maximumTraceLength": scenario.maximum_trace_length,
        "traceCount": trace_count,
        "policies": policies,
        "finiteTraceDominance": domination,
    }


def main() -> int:
    results = [analyze(scenario) for scenario in SCENARIOS]
    document = {
        "schemaVersion": 1,
        "scope": "finite exhaustive traces; offline oracle permits bypass and arbitrary eviction after each request",
        "scenarios": results,
        "claimBoundary": (
            "Finite traces do not prove production superiority. Landlord theory applies only after "
            "a refinement proof for expiry, dynamic costs, cancellation and numeric representation."
        ),
    }
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    print(f"Encoded handoff policy analysis: scenarios={len(results)}")
    for result in results:
        policies = result["policies"]
        assert isinstance(policies, dict)
        summary = ", ".join(
            f"{name}:maxRegret={values['maximumRegret']},maxRatio={values['maximumCompetitiveRatioObserved']:.3f}"
            for name, values in policies.items()
        )
        print(f"  {result['name']}: traces={result['traceCount']} {summary}")
        print(f"    finiteDominance={result['finiteTraceDominance']}")
    print(f"Artifact: {ARTIFACT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
