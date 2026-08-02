#!/usr/bin/env python3
"""对统一尺寸的小型 delayed-hit cache trace 求精确累计延迟最优值。

模型：每个 miss 在固定 Z 个离散时隙后完成；同对象在途期间的请求共享同一 fetch，
其延迟为剩余完成时间。完成时离线 oracle 可选择旁路或缓存并淘汰任意对象。
该有限 DP 用于反例与回归，不冒充变长对象、随机时延或无限 trace 的通用求解器。
"""

from __future__ import annotations

import argparse
import itertools
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / ".artifacts/mathematics/delayed-hit-cache.json"


@dataclass(frozen=True)
class State:
    cache: frozenset[str]
    inflight: tuple[tuple[str, int], ...]

    def inflight_map(self) -> dict[str, int]:
        return dict(self.inflight)


@dataclass(frozen=True)
class SimulationResult:
    aggregate_delay: int
    misses: int
    delayed_hits: int
    hits: int


def canonical_inflight(value: dict[str, int]) -> tuple[tuple[str, int], ...]:
    return tuple(sorted(value.items()))


def feasible_completion_caches(cache: frozenset[str], completed: frozenset[str], capacity: int) -> tuple[frozenset[str], ...]:
    available = sorted(cache | completed)
    result: list[frozenset[str]] = []
    for count in range(min(capacity, len(available)) + 1):
        result.extend(frozenset(items) for items in itertools.combinations(available, count))
    return tuple(result)


def exact_optimal_delay(trace: tuple[str, ...], capacity: int, delay: int) -> int:
    if capacity < 0 or delay < 1:
        raise ValueError("invalid delayed-hit cache configuration")

    @lru_cache(maxsize=None)
    def solve(time: int, state: State) -> int:
        if time >= len(trace):
            return 0
        inflight = state.inflight_map()
        completed = frozenset(key for key, completion in inflight.items() if completion == time)
        for key in completed:
            inflight.pop(key)
        best: int | None = None
        for cache in feasible_completion_caches(state.cache, completed, capacity):
            key = trace[time]
            next_inflight = dict(inflight)
            if key in cache:
                immediate = 0
            elif key in next_inflight:
                immediate = next_inflight[key] - time
            else:
                immediate = delay
                next_inflight[key] = time + delay
            value = immediate + solve(
                time + 1,
                State(cache, canonical_inflight(next_inflight)),
            )
            best = value if best is None else min(best, value)
        return best if best is not None else 0

    return solve(0, State(frozenset(), ()))


def next_request(trace: tuple[str, ...], key: str, after: int) -> int:
    for index in range(after + 1, len(trace)):
        if trace[index] == key:
            return index
    return len(trace) + 1


def simulate(trace: tuple[str, ...], capacity: int, delay: int, policy: str) -> SimulationResult:
    cache: set[str] = set()
    inflight: dict[str, int] = {}
    last_request: dict[str, int] = {}
    aggregate_delay = misses = delayed_hits = hits = 0
    for time, requested in enumerate(trace):
        completed = sorted(key for key, completion in inflight.items() if completion == time)
        for key in completed:
            inflight.pop(key)
            if capacity == 0:
                continue
            candidates = set(cache)
            candidates.add(key)
            if len(candidates) <= capacity:
                cache = candidates
            elif policy == "lru":
                victim = min(candidates, key=lambda item: (last_request.get(item, -1), item))
                candidates.remove(victim)
                cache = candidates
            elif policy == "belady-hit-rate":
                victim = max(candidates, key=lambda item: (next_request(trace, item, time), item))
                candidates.remove(victim)
                cache = candidates
            else:
                raise ValueError(f"unknown policy: {policy}")
        if requested in cache:
            hits += 1
        elif requested in inflight:
            delayed_hits += 1
            aggregate_delay += inflight[requested] - time
        else:
            misses += 1
            aggregate_delay += delay
            inflight[requested] = time + delay
        last_request[requested] = time
    return SimulationResult(aggregate_delay, misses, delayed_hits, hits)


def find_belady_counterexample(
    alphabet: tuple[str, ...] = ("a", "b", "c"),
    *,
    capacity: int = 1,
    delay: int = 3,
    maximum_length: int = 9,
) -> dict[str, object]:
    checked = 0
    for length in range(3, maximum_length + 1):
        for sequence in itertools.product(alphabet, repeat=length):
            if len(set(sequence)) < 2:
                continue
            checked += 1
            optimum = exact_optimal_delay(sequence, capacity, delay)
            belady = simulate(sequence, capacity, delay, "belady-hit-rate")
            if belady.aggregate_delay > optimum:
                lru = simulate(sequence, capacity, delay, "lru")
                return {
                    "trace": list(sequence),
                    "capacity": capacity,
                    "delaySlots": delay,
                    "checkedBeforeDiscovery": checked,
                    "exactLatencyOptimalAggregateDelay": optimum,
                    "beladyHitRatePolicy": belady.__dict__,
                    "lru": lru.__dict__,
                    "beladyRegret": belady.aggregate_delay - optimum,
                }
    raise RuntimeError("no delayed-hit Belady counterexample found in finite search domain")


def known_self_tests() -> list[dict[str, object]]:
    cases = [
        (("a", "a"), 1, 3, 5),
        (("a", "b", "a"), 1, 1, 2),
        (("a", "a", "a", "a"), 1, 2, 3),
    ]
    output: list[dict[str, object]] = []
    for trace, capacity, delay, expected in cases:
        observed = exact_optimal_delay(trace, capacity, delay)
        if observed != expected:
            raise RuntimeError(f"oracle self-test failed: {trace} expected={expected} observed={observed}")
        output.append({"trace": list(trace), "capacity": capacity, "delay": delay, "optimalDelay": observed})
    return output


def compare_traces() -> list[dict[str, object]]:
    traces: tuple[tuple[str, ...], ...] = (
        tuple("aaabacaa"),
        tuple("abcabcabc"),
        tuple("aabbccaabb"),
        tuple("abacabadabac"),
    )
    records: list[dict[str, object]] = []
    for trace in traces:
        optimum = exact_optimal_delay(trace, 2, 3)
        lru = simulate(trace, 2, 3, "lru")
        belady = simulate(trace, 2, 3, "belady-hit-rate")
        records.append({
            "trace": list(trace),
            "capacity": 2,
            "delaySlots": 3,
            "exactLatencyOptimalAggregateDelay": optimum,
            "lru": lru.__dict__,
            "beladyHitRatePolicy": belady.__dict__,
            "lruRegret": lru.aggregate_delay - optimum,
            "beladyRegret": belady.aggregate_delay - optimum,
        })
    return records


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--maximum-counterexample-length", type=int, default=9)
    args = parser.parse_args()
    if not 3 <= args.maximum_counterexample_length <= 12:
        raise SystemExit("counterexample length must be between 3 and 12")
    report = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "model": {
            "objectSize": "uniform-one-slot",
            "fetchDelay": "fixed-discrete-Z",
            "singleFlight": True,
            "completionDecision": "offline may bypass or admit and evict any cached object",
            "objective": "minimum aggregate request waiting time",
        },
        "selfTests": known_self_tests(),
        "beladyCounterexample": find_belady_counterexample(maximum_length=args.maximum_counterexample_length),
        "comparisons": compare_traces(),
        "truthBoundary": (
            "The exact DP covers only the declared finite uniform-size fixed-delay model. It proves that "
            "hit-rate-oriented future-distance eviction need not minimize aggregate waiting under delayed hits; "
            "it does not implement belatedly's general min-cost-flow formulation or prove a production policy optimal."
        ),
    }
    output = args.output if args.output.is_absolute() else ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    counterexample = report["beladyCounterexample"]
    print(
        "Delayed-hit cache oracle: "
        f"trace={''.join(counterexample['trace'])} optimum={counterexample['exactLatencyOptimalAggregateDelay']} "
        f"belady={counterexample['beladyHitRatePolicy']['aggregate_delay']}"
    )
    try:
        display = output.relative_to(ROOT)
    except ValueError:
        display = output
    print(f"Artifact: {display}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
