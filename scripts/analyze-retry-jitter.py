#!/usr/bin/env python3
"""验证当前 full-jitter 退避相对完全同步重试的碰撞边界。"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import argparse
import hashlib
import json
import math
from pathlib import Path
import random

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / ".artifacts/mathematics/retry-jitter.json"
SOURCE = ROOT / "Sources/FoveaCore/TransportRetryPolicy.swift"


@dataclass(frozen=True)
class Policy:
    name: str
    lower_fraction: float
    upper_fraction: float


POLICIES = (
    Policy("synchronized", 1.0, 1.0),
    Policy("full-jitter", 0.0, 1.0),
)


def choose_delay(policy: Policy, cap: int, rng: random.Random) -> float:
    if policy.lower_fraction == policy.upper_fraction:
        return cap * policy.lower_fraction
    return rng.uniform(cap * policy.lower_fraction, cap * policy.upper_fraction)


def histogram(
    policy: Policy,
    clients: int,
    cap_milliseconds: int,
    timer_quantum_milliseconds: int,
    seed: int,
) -> dict[str, object]:
    rng = random.Random(seed)
    bins: dict[int, int] = {}
    for _ in range(clients):
        delay = choose_delay(policy, cap_milliseconds, rng)
        timer_bin = int(delay // timer_quantum_milliseconds)
        bins[timer_bin] = bins.get(timer_bin, 0) + 1

    colliding_pairs = sum(count * (count - 1) // 2 for count in bins.values())
    occupied = len(bins)
    peak = max(bins.values(), default=0)
    sorted_counts = sorted(bins.values(), reverse=True)
    p99_index = max(0, math.ceil(len(sorted_counts) * 0.01) - 1)
    p99_bin_load = sorted_counts[p99_index] if sorted_counts else 0
    return {
        "policy": policy.name,
        "supportMilliseconds": [
            round(cap_milliseconds * policy.lower_fraction, 6),
            round(cap_milliseconds * policy.upper_fraction, 6),
        ],
        "occupiedTimerBins": occupied,
        "peakClientsInOneBin": peak,
        "p99TimerBinLoad": p99_bin_load,
        "collidingClientPairs": colliding_pairs,
        "pairCollisionRate": (
            colliding_pairs / (clients * (clients - 1) / 2) if clients > 1 else 0
        ),
    }


def exact_uniform_pair_collision_probability(
    policy: Policy,
    cap_milliseconds: int,
    timer_quantum_milliseconds: int,
) -> float:
    lower = cap_milliseconds * policy.lower_fraction
    upper = cap_milliseconds * policy.upper_fraction
    if upper == lower:
        return 1.0
    # 对连续均匀分布量化到定时器桶，精确累加每个桶的概率平方。
    first = math.floor(lower / timer_quantum_milliseconds)
    last = math.floor(math.nextafter(upper, lower) / timer_quantum_milliseconds)
    width = upper - lower
    probability = 0.0
    for bucket in range(first, last + 1):
        left = max(lower, bucket * timer_quantum_milliseconds)
        right = min(upper, (bucket + 1) * timer_quantum_milliseconds)
        mass = max(0.0, right - left) / width
        probability += mass * mass
    return probability


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--clients", type=int, default=10_000)
    parser.add_argument("--cap-ms", type=int, default=2_000)
    parser.add_argument("--timer-quantum-ms", type=int, default=10)
    parser.add_argument("--seed", type=int, default=0xF0_7EA)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    if args.clients < 2 or args.cap_ms <= 0 or args.timer_quantum_ms <= 0:
        raise SystemExit("clients>=2 且时间参数必须为正")

    results: list[dict[str, object]] = []
    for index, policy in enumerate(POLICIES):
        result = histogram(
            policy,
            args.clients,
            args.cap_ms,
            args.timer_quantum_ms,
            args.seed + index,
        )
        result["exactPairCollisionProbability"] = exact_uniform_pair_collision_probability(
            policy,
            args.cap_ms,
            args.timer_quantum_ms,
        )
        results.append(result)

    by_name = {str(item["policy"]): item for item in results}
    full = by_name["full-jitter"]
    synchronized = by_name["synchronized"]
    invariants = {
        "fullJitterUsesPositiveSupportWidth": (
            full["supportMilliseconds"][1] > full["supportMilliseconds"][0]
        ),
        "fullJitterReducesExactPairCollisionProbability": (
            full["exactPairCollisionProbability"]
            < synchronized["exactPairCollisionProbability"]
        ),
        "fullJitterReducesEmpiricalPeak": (
            full["peakClientsInOneBin"]
            < synchronized["peakClientsInOneBin"]
        ),
        "retryAfterLowerBoundPreservedByProductionFormula": (
            "return max(serverMinimum" in SOURCE.read_text()
        ),
    }

    report = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "sourceSHA256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        "parameters": {
            "clients": args.clients,
            "capMilliseconds": args.cap_ms,
            "timerQuantumMilliseconds": args.timer_quantum_ms,
            "seed": args.seed,
        },
        "policies": results,
        "invariants": invariants,
        "claimBoundary": (
            "模型只比较同一轮客户端退避定时器在固定量化精度下的碰撞；"
            "它不模拟真实 RTT、服务器队列、连接复用或多轮反馈。Full jitter 降低同步"
            "不等于任意网络模型下全局稳定；最大次数和总延迟预算仍是必要安全边界。"
        ),
    }
    output = args.output if args.output.is_absolute() else ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    print("Retry jitter collision analysis:")
    for item in results:
        print(
            f"  {item['policy']}: peak={item['peakClientsInOneBin']} "
            f"pairs={item['collidingClientPairs']} "
            f"exact-p={item['exactPairCollisionProbability']:.6f}"
        )
    try:
        displayed_output = output.relative_to(ROOT)
    except ValueError:
        displayed_output = output
    print(f"Artifact: {displayed_output}")
    failed = [name for name, passed in invariants.items() if not passed]
    if failed:
        raise SystemExit(f"重试抖动不变量失败：{failed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
