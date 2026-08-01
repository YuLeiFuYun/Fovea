#!/usr/bin/env python3
"""对成组运行数据执行依赖感知的延迟分布诊断。

这不是普通 KS 等分布检验，也不把经验 ECDF 的目测关系冒充总体随机占优。
重采样单位始终是 run/session block；输出仅支持有限作用域的 L3 分布证据。
"""

from __future__ import annotations

import argparse
import json
import math
import random
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / ".artifacts/mathematics/latency-distributions.json"


@dataclass(frozen=True)
class Block:
    identifier: str
    fovea: tuple[float, ...]
    comparator: tuple[float, ...]


def fail(message: str) -> None:
    raise ValueError(message)


def quantile(values: list[float], probability: float) -> float:
    if not values:
        fail("quantile requires nonempty values")
    ordered = sorted(values)
    position = (len(ordered) - 1) * probability
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] * (1 - fraction) + ordered[upper] * fraction


def empirical_cdf(values: list[float], point: float) -> float:
    return sum(value <= point for value in values) / len(values)


def fsd_violation(fovea_loss: list[float], comparator_loss: list[float]) -> float:
    """返回 max_x(F_comparator(x)-F_fovea(x)); 0 表示样本中无 FSD 违约。"""
    support = sorted(set(fovea_loss + comparator_loss))
    return max(
        (empirical_cdf(comparator_loss, point) - empirical_cdf(fovea_loss, point) for point in support),
        default=0.0,
    )


def wasserstein_1d(left: list[float], right: list[float], grid: int = 1024) -> float:
    """用经验分位函数积分计算一维 W1，支持不同样本数。"""
    if not left or not right:
        fail("W1 requires nonempty samples")
    points = max(64, grid)
    total = 0.0
    for index in range(points):
        probability = (index + 0.5) / points
        total += abs(quantile(left, probability) - quantile(right, probability))
    return total / points


def to_loss(values: Iterable[float], direction: str) -> list[float]:
    data = [float(value) for value in values]
    if any(not math.isfinite(value) for value in data):
        fail("distribution samples must be finite")
    if direction == "lower":
        return data
    if direction == "higher":
        return [-value for value in data]
    fail("direction must be lower or higher")
    return []


def percentile_interval(values: list[float], alpha: float = 0.05) -> list[float]:
    return [quantile(values, alpha / 2), quantile(values, 1 - alpha / 2)]


def flatten(blocks: list[Block], field: str, direction: str) -> list[float]:
    return to_loss((value for block in blocks for value in getattr(block, field)), direction)


def analyze(
    blocks: list[Block],
    *,
    direction: str,
    wasserstein_margin: float,
    dominance_margin: float,
    iterations: int,
    seed: int,
) -> dict[str, Any]:
    if len(blocks) < 2:
        fail("at least two run/session blocks are required")
    if wasserstein_margin <= 0 or not 0 <= dominance_margin < 1:
        fail("invalid preregistered distribution margins")
    fovea = flatten(blocks, "fovea", direction)
    comparator = flatten(blocks, "comparator", direction)
    observed_w1 = wasserstein_1d(fovea, comparator)
    observed_violation = fsd_violation(fovea, comparator)
    observed_quantiles = {
        str(probability): quantile(fovea, probability) - quantile(comparator, probability)
        for probability in (0.5, 0.95, 0.99)
    }

    rng = random.Random(seed)
    bootstrap_w1: list[float] = []
    bootstrap_violation: list[float] = []
    bootstrap_quantiles: dict[str, list[float]] = {key: [] for key in observed_quantiles}
    for _ in range(iterations):
        sampled = [blocks[rng.randrange(len(blocks))] for _ in blocks]
        sample_fovea = flatten(sampled, "fovea", direction)
        sample_comparator = flatten(sampled, "comparator", direction)
        bootstrap_w1.append(wasserstein_1d(sample_fovea, sample_comparator, grid=256))
        bootstrap_violation.append(fsd_violation(sample_fovea, sample_comparator))
        for key in bootstrap_quantiles:
            probability = float(key)
            bootstrap_quantiles[key].append(
                quantile(sample_fovea, probability) - quantile(sample_comparator, probability)
            )

    w1_ci = percentile_interval(bootstrap_w1)
    violation_ci = percentile_interval(bootstrap_violation)
    if violation_ci[1] <= dominance_margin:
        dominance_classification = "dependence-aware-almost-dominance-within-margin"
    else:
        dominance_classification = "dominance-inconclusive-or-crossing"
    w1_classification = (
        "distribution-distance-equivalent-within-margin"
        if w1_ci[1] <= wasserstein_margin
        else "distribution-distance-not-equivalent"
    )
    return {
        "blockCount": len(blocks),
        "foveaObservationCount": len(fovea),
        "comparatorObservationCount": len(comparator),
        "canonicalLoss": "lower-is-better",
        "empiricalFSDViolation": observed_violation,
        "empiricalFSDViolationCI95": violation_ci,
        "dominanceMargin": dominance_margin,
        "dominanceClassification": dominance_classification,
        "wasserstein1": observed_w1,
        "wasserstein1CI95": w1_ci,
        "wassersteinMargin": wasserstein_margin,
        "wassersteinClassification": w1_classification,
        "lossQuantileDifferences": {
            key: {
                "estimate": value,
                "confidenceInterval95": percentile_interval(bootstrap_quantiles[key]),
                "negativeFavorsFovea": True,
            }
            for key, value in observed_quantiles.items()
        },
        "truthBoundary": (
            "The ECDF violation is a finite-sample diagnostic. Population stochastic dominance requires "
            "a directional dominance test under the actual dependence structure; an ordinary equality KS "
            "test or a visual ECDF comparison is insufficient. W1 is a unit-preserving distribution distance "
            "and does not identify which user-visible tail endpoint changed."
        ),
    }


def parse_blocks(document: dict[str, Any]) -> list[Block]:
    blocks: list[Block] = []
    for item in document.get("blocks", []):
        identifier = item.get("blockID")
        fovea = item.get("fovea")
        comparator = item.get("comparator")
        if not isinstance(identifier, str) or not isinstance(fovea, list) or not isinstance(comparator, list):
            fail("invalid distribution block")
        if not fovea or not comparator:
            fail(f"{identifier}: samples must be nonempty")
        blocks.append(Block(identifier, tuple(map(float, fovea)), tuple(map(float, comparator))))
    return blocks


def synthetic_document(kind: str) -> dict[str, Any]:
    if kind == "dominant":
        pairs = [([1, 2, 2, 3], [2, 3, 4, 5]), ([1, 1, 2, 3], [2, 3, 3, 6]), ([1, 2, 3, 3], [2, 4, 4, 7])]
    elif kind == "equal":
        pairs = [([1, 2, 3], [1, 2, 3]), ([2, 3, 4], [2, 3, 4]), ([1, 4, 5], [1, 4, 5])]
    elif kind == "crossing":
        pairs = [([1, 1, 8, 9], [2, 3, 4, 5]), ([1, 2, 9, 10], [2, 3, 5, 6]), ([1, 2, 8, 11], [2, 4, 5, 7])]
    else:
        fail("unknown synthetic case")
    return {
        "schemaVersion": 1,
        "metricID": f"synthetic-{kind}",
        "direction": "lower",
        "unit": "milliseconds",
        "wassersteinMargin": 0.01 if kind != "equal" else 0.001,
        "dominanceMargin": 0.0,
        "blocks": [
            {"blockID": f"block-{index}", "fovea": left, "comparator": right}
            for index, (left, right) in enumerate(pairs)
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--iterations", type=int, default=10_000)
    parser.add_argument("--seed", type=int, default=20260725)
    parser.add_argument("--synthetic", choices=["dominant", "equal", "crossing"])
    args = parser.parse_args()
    if args.iterations < 1_000:
        fail("at least 1000 block-bootstrap iterations are required")
    if args.synthetic:
        document = synthetic_document(args.synthetic)
    elif args.input:
        source = args.input if args.input.is_absolute() else ROOT / args.input
        document = json.loads(source.read_text())
    else:
        fail("provide --input or --synthetic")
    if document.get("schemaVersion") != 1:
        fail("unexpected distribution input schema")
    result = analyze(
        parse_blocks(document),
        direction=document["direction"],
        wasserstein_margin=float(document["wassersteinMargin"]),
        dominance_margin=float(document["dominanceMargin"]),
        iterations=args.iterations,
        seed=args.seed,
    )
    report = {
        "schemaVersion": 1,
        "metricID": document["metricID"],
        "unit": document["unit"],
        "resamplingUnit": "run-session-block",
        "bootstrapIterations": args.iterations,
        **result,
    }
    output = args.output if args.output.is_absolute() else ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "Latency distribution analysis: "
        f"metric={report['metricID']} blocks={report['blockCount']} "
        f"dominance={report['dominanceClassification']} W1={report['wassersteinClassification']}"
    )
    try:
        display = output.relative_to(ROOT)
    except ValueError:
        display = output
    print(f"Artifact: {display}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
