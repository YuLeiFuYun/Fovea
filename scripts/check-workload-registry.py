#!/usr/bin/env python3
"""Validate the accepted W1-W15 catalog and prevent phase-subset amnesia."""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "Benchmarks/workload-registry.json"
ONTOLOGY = ROOT / "docs/research/comparison-ontology.json"
COMPARATORS = ROOT / "docs/research/comparator-registry.json"
CHALLENGES = ROOT / "Benchmarks/ComparativeLab/challenge-suite.json"
COMP_PLAN = ROOT / "Benchmarks/ComparativeLab/experiment-plan.json"
ACCEPTED_MATRIX = ROOT / "docs/project-memory/accepted-workload-matrix.md"
BENCHMARK_SPEC = ROOT / "docs/specifications/benchmark-workloads.md"
ARTIFACT = ROOT / ".artifacts/comparators/workload-registry-verification.json"

ACCEPTED = {
    "W1": ("Feed Scroll", "取消、去重、卡顿、扫描污染", "W1-SCROLL-V1"),
    "W2": ("Detail Hero", "下采样、峰值内存、色彩和方向", "W2-HERO-V1"),
    "W3": ("Auth Gallery", "no-store、Vary、跨用户隔离、redirect", "W3-AUTH-V1"),
    "W4": ("Progressive JPEG", "首个可接受结果、扫描质量、取消", "W4-PROGRESSIVE-JPEG-V1"),
    "W5": ("Animated Media", "帧调度、帧缓存、掉帧、内存", "W5-ANIMATED-MEDIA-V1"),
    "W6": ("Weak Network and Interruption Recovery", "retry、resume、Range、流量浪费", "W6-INTERRUPTION-RECOVERY-V1"),
    "W7": ("1,000 Concurrent Requests", "去重、线程数、锁竞争、公平性", "W7-THOUSAND-CONCURRENT-V1"),
    "W8": ("Cache Restart and Corruption", "durability、恢复、外部删除", "W8-CACHE-RESTART-CORRUPTION-V1"),
    "W9": ("Hostile Image Corpus", "crash、OOM、超限、fuzz", "W9-HOSTILE-IMAGE-CORPUS-V1"),
    "W10": ("SwiftUI Identity Churn", "view 生命周期、旧图闪现、取消", "W10-SWIFTUI-IDENTITY-CHURN-V1"),
    "W11": ("Multi-Target Same Source", "编码下载共享、变体缓存", "W11-MULTI-TARGET-SAME-SOURCE-V1"),
    "W12": ("Memory Warning and Background Transition", "回收速度、状态一致性", "W12-MEMORY-BACKGROUND-TRANSITION-V1"),
    "W13": ("Phase-Changing Cache Trace", "淘汰策略自适应", "W13-PHASE-CHANGING-CACHE-V1"),
    "W14": ("Offline and Revalidation", "stale、304、过期行为", "W14-OFFLINE-REVALIDATION-V1"),
    "W15": ("Low-Data and Expensive Network", "策略切换、优先级和预取抑制", "W15-EXPENSIVE-NETWORK-POLICY-V1"),
}


def load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise TypeError(f"{path} must contain a JSON object")
    return value


def digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def main() -> int:
    registry = load(REGISTRY)
    ontology = load(ONTOLOGY)
    comparator_registry = load(COMPARATORS)
    challenges = load(CHALLENGES)
    comp_plan = load(COMP_PLAN)
    matrix_text = ACCEPTED_MATRIX.read_text()
    benchmark_text = BENCHMARK_SPEC.read_text()
    errors: list[str] = []

    if registry.get("schemaVersion") != 2:
        errors.append("workload registry schemaVersion must be 2")
    if registry.get("registryID") != "FOVEA-CANONICAL-WORKLOAD-CATALOG-V3":
        errors.append("unexpected workload registry identity")
    source = registry.get("sourceAuthority", {})
    if source.get("discussionSourceID") != "SRC-DISCUSSION-COMPARISON-ROADMAP-01":
        errors.append("workload matrix source identity drifted")
    if source.get("discussionSourceSHA256") != "361438a15ca974aee4245a393052ee7a9a09fabc1954c1cee76afecf617000bf":
        errors.append("workload matrix source digest drifted")

    rules = registry.get("globalRules", {})
    if rules.get("currentPhase0bExecutableSubset") != ["W1", "W2", "W3"]:
        errors.append("Phase 0b executable subset must remain explicitly W1-W3")
    if rules.get("fullAcceptedWorkloadRange") != "W1-W15":
        errors.append("full accepted workload range must remain W1-W15")
    if rules.get("silentDeletionOrRenumberingForbidden") is not True:
        errors.append("silent workload deletion or renumbering must remain forbidden")
    if rules.get("supersessionRequired") is not True:
        errors.append("workload supersession must remain explicit")
    if "does not imply" not in rules.get("noGlobalCompletionShortcut", ""):
        errors.append("registry must reject the W1-W3 completion shortcut")

    phases = registry.get("phases", [])
    phase_ids = [item.get("id") for item in phases if isinstance(item, dict)]
    if phase_ids != list("ABCDEFGH"):
        errors.append(f"phase IDs must be gap-free A-H, got {phase_ids}")

    capability_ids = {item.get("id") for item in ontology.get("capabilities", [])}
    comparator_ids = {item.get("id") for item in comparator_registry.get("comparators", [])}
    challenge_ids = {item.get("id") for item in challenges.get("challenges", [])}
    workloads = registry.get("workloads", [])
    expected_ids = [f"W{index}" for index in range(1, 16)]
    ids = [item.get("id") for item in workloads if isinstance(item, dict)]
    if ids != expected_ids:
        errors.append(f"workload IDs must be ordered and gap-free W1-W15, got {ids}")

    covered_capabilities: set[str] = set()
    covered_challenges: set[str] = set()
    canonical_ids: set[str] = set()
    statuses: dict[str, str] = {}
    required_fields = {
        "id", "canonicalID", "name", "acceptedPurpose", "provenance", "status",
        "phases", "lab", "capabilities", "semanticProfileStatus",
        "candidatePrimaryEndpoints", "secondaryEndpoints", "hardInvariants",
        "directComparators", "specialistComparators", "challengeIDs", "oracle",
        "evidencePaths", "blockers", "claimActivation",
    }
    for item in workloads:
        if not isinstance(item, dict):
            errors.append("each workload entry must be an object")
            continue
        identifier = str(item.get("id"))
        missing = required_fields - item.keys()
        if missing:
            errors.append(f"{identifier}: missing fields {sorted(missing)}")
            continue
        expected_name, expected_purpose, expected_canonical = ACCEPTED.get(identifier, (None, None, None))
        if item["name"] != expected_name:
            errors.append(f"{identifier}: accepted name drifted: {item['name']!r}")
        if item["acceptedPurpose"] != expected_purpose:
            errors.append(f"{identifier}: accepted purpose drifted: {item['acceptedPurpose']!r}")
        if item["canonicalID"] != expected_canonical:
            errors.append(f"{identifier}: canonicalID drifted: {item['canonicalID']!r}")
        if item["canonicalID"] in canonical_ids:
            errors.append(f"{identifier}: duplicate canonicalID")
        canonical_ids.add(item["canonicalID"])
        statuses[identifier] = item["status"]
        if item["provenance"] != "restored-from-accepted-discussion-matrix":
            errors.append(f"{identifier}: restored source provenance must remain explicit")
        if set(item["phases"]) - set(phase_ids):
            errors.append(f"{identifier}: unknown phases {sorted(set(item['phases']) - set(phase_ids))}")
        unknown_caps = set(item["capabilities"]) - capability_ids
        if unknown_caps:
            errors.append(f"{identifier}: unknown capabilities {sorted(unknown_caps)}")
        covered_capabilities.update(item["capabilities"])
        unknown_comparators = set(item["directComparators"] + item["specialistComparators"]) - comparator_ids
        if unknown_comparators:
            errors.append(f"{identifier}: unknown comparators {sorted(unknown_comparators)}")
        unknown_challenges = set(item["challengeIDs"]) - challenge_ids
        if unknown_challenges:
            errors.append(f"{identifier}: unknown challenges {sorted(unknown_challenges)}")
        covered_challenges.update(item["challengeIDs"])
        if not item["hardInvariants"]:
            errors.append(f"{identifier}: hard invariants cannot be empty")
        if not item["blockers"]:
            errors.append(f"{identifier}: blockers cannot be empty")
        if len(item["oracle"]) < 20:
            errors.append(f"{identifier}: oracle/analysis boundary is missing")
        for relative in item["evidencePaths"]:
            if not isinstance(relative, str) or not (ROOT / relative).exists():
                errors.append(f"{identifier}: missing evidence path {relative}")

    if covered_capabilities != capability_ids:
        errors.append(
            "workload capability coverage differs: "
            f"missing={sorted(capability_ids - covered_capabilities)} "
            f"unexpected={sorted(covered_capabilities - capability_ids)}"
        )
    required_challenges = {
        item["id"]
        for item in challenges.get("challenges", [])
        if item.get("status") in {"implemented-and-required", "capability-gap"}
    }
    if not required_challenges <= covered_challenges:
        errors.append(f"unmapped challenges: {sorted(required_challenges - covered_challenges)}")

    expected_current = {"W1-SCROLL-V1", "W2-HERO-V1", "W3-AUTH-V1"}
    if set(comp_plan.get("workloads", {})) != expected_current:
        errors.append("current Comparative experiment plan must remain the explicit W1-W3 subset")
    for identifier in ("W1", "W2", "W3"):
        if not statuses.get(identifier, "").startswith("implemented-simulator-calibration"):
            errors.append(f"{identifier}: current executable status drifted")
    for identifier in ("W4", "W5"):
        if not statuses.get(identifier, "").startswith("capability-gap"):
            errors.append(f"{identifier}: current capability gap must remain explicit")
    if "resume-capability-gap" not in statuses.get("W6", ""):
        errors.append("W6 resumable-transfer capability gap must remain explicit")

    adjunct = registry.get("adjunctWorkloads", [])
    if len(adjunct) != 1 or adjunct[0].get("canonicalID") != "X1-ADAPTIVE-REPRESENTATION-V1":
        errors.append("Adaptive Representation must be preserved as adjunct X1, not W4")
    for relative in adjunct[0].get("evidencePaths", []) if adjunct else []:
        if not (ROOT / relative).exists():
            errors.append(f"X1: missing evidence path {relative}")

    expected_matrix_rows = {
        "W1": ("快速滚动图片流", "取消、去重、卡顿、扫描污染"),
        "W2": ("12/24/48 MP hero 图", "下采样、峰值内存、色彩和方向"),
        "W3": ("鉴权图库", "`no-store`、`Vary`、跨用户隔离、redirect"),
        "W4": ("渐进 JPEG", "首个可接受结果、扫描质量、取消"),
        "W5": ("GIF/APNG/WebP 动图", "帧调度、帧缓存、掉帧、内存"),
        "W6": ("弱网和中断恢复", "retry、resume、Range、流量浪费"),
        "W7": ("1,000 并发请求", "去重、线程数、锁竞争、公平性"),
        "W8": ("缓存重启与损坏", "durability、恢复、外部删除"),
        "W9": ("敌意图片 corpus", "crash、OOM、超限、fuzz"),
        "W10": ("SwiftUI identity churn", "view 生命周期、旧图闪现、取消"),
        "W11": ("多尺寸同源图片", "编码下载共享、变体缓存"),
        "W12": ("内存警告/后台切换", "回收速度、状态一致性"),
        "W13": ("phase-changing cache trace", "淘汰策略自适应"),
        "W14": ("离线/重验证", "stale、304、过期行为"),
        "W15": ("低数据/昂贵网络", "策略切换、优先级和预取抑制"),
    }
    for identifier, (name, purpose) in expected_matrix_rows.items():
        if f"| {identifier} | {name} | {purpose} |" not in matrix_text:
            errors.append(f"accepted matrix markdown drifted at {identifier}")

    required_headings = {
        "W4": "## W4：渐进 JPEG",
        "W5": "## W5：GIF/APNG/WebP 动图",
        "W6": "## W6：弱网和中断恢复",
        "W7": "## W7：1,000 并发请求",
        "W8": "## W8：缓存重启与损坏",
        "W9": "## W9：敌意图片 corpus",
        "W10": "## W10：SwiftUI identity churn",
        "W11": "## W11：多尺寸同源图片",
        "W12": "## W12：内存警告/后台切换",
        "W13": "## W13：phase-changing cache trace",
        "W14": "## W14：离线/重验证",
        "W15": "## W15：低数据/昂贵网络",
    }
    for identifier, heading in required_headings.items():
        if heading not in benchmark_text:
            errors.append(f"benchmark specification missing {identifier}")
    if "## W4：Adaptive Representation" in benchmark_text:
        errors.append("obsolete Adaptive Representation W4 heading reappeared")
    if "## X1：Adaptive Representation" not in benchmark_text:
        errors.append("Adaptive Representation adjunct X1 is missing")

    ordered = [identifier for group in registry.get("implementationOrder", []) for identifier in group.get("workloads", [])]
    if not set(expected_ids) <= set(ordered):
        errors.append(f"implementation order omits workloads {sorted(set(expected_ids) - set(ordered))}")
    if set(ordered) - set(expected_ids):
        errors.append(f"implementation order contains unknown workloads {sorted(set(ordered) - set(expected_ids))}")

    result = {
        "schemaVersion": 2,
        "registryID": registry.get("registryID"),
        "workloadCount": len(workloads),
        "adjunctWorkloadCount": len(adjunct),
        "phaseCount": len(phases),
        "capabilityCount": len(covered_capabilities),
        "challengeCount": len(covered_challenges),
        "currentExecutableSubset": rules.get("currentPhase0bExecutableSubset"),
        "fullAcceptedWorkloadRange": rules.get("fullAcceptedWorkloadRange"),
        "registrySHA256": digest(registry),
        "status": "failed" if errors else "passed",
        "errors": errors,
    }
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "Workload registry: "
        f"workloads={len(workloads)} adjunct={len(adjunct)} phases={len(phases)} "
        f"capabilities={len(covered_capabilities)} challenges={len(covered_challenges)} "
        f"errors={len(errors)} sha256:{result['registrySHA256']}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
