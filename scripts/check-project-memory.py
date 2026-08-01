#!/usr/bin/env python3
"""Validate repository-backed continuity memory and accepted discussion decisions."""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
MEMORY_DIR = ROOT / "docs/project-memory"
SOURCE_MANIFEST = MEMORY_DIR / "source-manifest.json"
LEDGER = MEMORY_DIR / "discussion-ledger.json"
MEMORY = MEMORY_DIR / "project-memory.json"
ROADMAP = MEMORY_DIR / "long-horizon-roadmap.json"
WORKLOADS = ROOT / "Benchmarks/workload-registry.json"
ACCEPTED_MATRIX = MEMORY_DIR / "accepted-workload-matrix.md"
ARTIFACT = ROOT / ".artifacts/project-memory/verification.json"
SHA64 = re.compile(r"^[0-9a-f]{64}$")


def load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise TypeError(f"{path} must contain an object")
    return value


def digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def main() -> int:
    source_manifest = load(SOURCE_MANIFEST)
    ledger = load(LEDGER)
    memory = load(MEMORY)
    roadmap = load(ROADMAP)
    workloads = load(WORKLOADS)
    matrix_text = ACCEPTED_MATRIX.read_text()
    errors: list[str] = []

    if source_manifest.get("manifestID") != "FOVEA-DISCUSSION-SOURCE-MANIFEST-V1":
        errors.append("unexpected discussion source manifest identity")
    sources = source_manifest.get("sources", [])
    source_ids: set[str] = set()
    source_hashes: set[str] = set()
    for source in sources:
        if not isinstance(source, dict):
            errors.append("source entries must be objects")
            continue
        identifier = source.get("id")
        sha = source.get("sha256")
        if not isinstance(identifier, str) or identifier in source_ids:
            errors.append(f"invalid or duplicate source ID: {identifier}")
        else:
            source_ids.add(identifier)
        if not isinstance(sha, str) or SHA64.fullmatch(sha) is None:
            errors.append(f"{identifier}: invalid sha256")
        elif sha in source_hashes:
            errors.append(f"{identifier}: duplicate source digest")
        else:
            source_hashes.add(sha)
        if not isinstance(source.get("byteCount"), int) or source["byteCount"] <= 0:
            errors.append(f"{identifier}: byteCount must be positive")

    if ledger.get("ledgerID") != "FOVEA-DISCUSSION-LEDGER-V1":
        errors.append("unexpected discussion ledger identity")
    rules = ledger.get("rules", {})
    for key in (
        "acceptedDiscussionMustBeRecorded",
        "activeDecisionMustHaveRepositoryTargets",
        "supersessionMustBeExplicit",
        "unresolvedItemsMustRemainVisible",
        "repositoryMemoryIsAuthoritative",
    ):
        if rules.get(key) is not True:
            errors.append(f"discussion ledger rule {key} must remain true")
    if rules.get("conversationSummaryIsNotAuthoritative") is not True:
        errors.append("conversation summaries must not be authoritative")

    ledger_ids: set[str] = set()
    for entry in ledger.get("entries", []):
        if not isinstance(entry, dict):
            errors.append("discussion ledger entries must be objects")
            continue
        identifier = entry.get("id")
        if not isinstance(identifier, str) or identifier in ledger_ids:
            errors.append(f"invalid or duplicate discussion ID: {identifier}")
            continue
        ledger_ids.add(identifier)
        unknown_sources = set(entry.get("sourceIDs", [])) - source_ids
        if unknown_sources:
            errors.append(f"{identifier}: unknown sources {sorted(unknown_sources)}")
        if entry.get("status", "").startswith("active") and not entry.get("openItems"):
            errors.append(f"{identifier}: active entry must preserve open items")
        for relative in entry.get("repositoryTargets", []):
            if not isinstance(relative, str) or not (ROOT / relative).exists():
                errors.append(f"{identifier}: missing repository target {relative}")
        decisions = entry.get("decisions", entry.get("remediation", []))
        if not isinstance(decisions, list) or not decisions:
            errors.append(f"{identifier}: no persisted decisions/remediation")

    if roadmap.get("roadmapID") != "FOVEA-LONG-HORIZON-ROADMAP-V1":
        errors.append("unexpected long-horizon roadmap identity")
    if roadmap.get("status") != "active":
        errors.append("long-horizon roadmap must remain active")
    roadmap_authority = roadmap.get("authority", {})
    for key in (
        "repositoryManifestIsAuthoritative",
        "phaseRemovalRequiresExplicitSupersession",
        "phaseRenumberingRequiresExplicitSupersession",
        "unfinishedWorkMustRemainVisible",
        "taskMustMapToPhaseAndObligation",
        "implementationMayRefineButNotSilentlyReplaceSkeleton",
    ):
        if roadmap_authority.get(key) is not True:
            errors.append(f"long-horizon roadmap authority {key} must remain true")
    if roadmap_authority.get("conflictPolicy") != "fail-closed-record-and-resolve":
        errors.append("long-horizon roadmap conflict policy must fail closed")
    canonical_plan = roadmap.get("canonicalPlan")
    if not isinstance(canonical_plan, str) or not (ROOT / canonical_plan).exists():
        errors.append(f"long-horizon roadmap canonical plan missing: {canonical_plan}")
    phases = roadmap.get("phases", [])
    phase_ids: list[str] = []
    phase_statuses = {"active", "active-partial", "ready", "blocked", "pending", "continuous", "deferred", "completed-local-contract"}
    for phase in phases:
        identifier = phase.get("id") if isinstance(phase, dict) else None
        if not isinstance(identifier, str) or identifier in phase_ids:
            errors.append(f"invalid or duplicate roadmap phase: {identifier}")
            continue
        phase_ids.append(identifier)
        if phase.get("status") not in phase_statuses:
            errors.append(f"{identifier}: invalid roadmap phase status {phase.get('status')}")
        if not phase.get("objectives") or not phase.get("exitCriteria"):
            errors.append(f"{identifier}: roadmap phase requires objectives and exit criteria")
    expected_phase_ids = [f"P{index}" for index in range(10)]
    if phase_ids != expected_phase_ids:
        errors.append(f"long-horizon roadmap phases drifted: expected={expected_phase_ids} actual={phase_ids}")
    phase_id_set = set(phase_ids)
    for phase in phases:
        identifier = phase.get("id") if isinstance(phase, dict) else None
        unknown_dependencies = set(phase.get("dependencies", [])) - phase_id_set if isinstance(phase, dict) else set()
        if unknown_dependencies:
            errors.append(f"{identifier}: unknown roadmap dependencies {sorted(unknown_dependencies)}")
    active_frontier = roadmap.get("activeFrontier", [])
    if not isinstance(active_frontier, list) or not active_frontier:
        errors.append("long-horizon roadmap active frontier must be non-empty")
    elif set(active_frontier) - phase_id_set:
        errors.append(f"long-horizon roadmap active frontier has unknown phases {sorted(set(active_frontier) - phase_id_set)}")
    queue_ids: set[str] = set()
    for item in roadmap.get("currentExecutionQueue", []):
        identifier = item.get("id") if isinstance(item, dict) else None
        if not isinstance(identifier, str) or identifier in queue_ids:
            errors.append(f"invalid or duplicate roadmap queue item: {identifier}")
            continue
        queue_ids.add(identifier)
        if item.get("phase") not in phase_id_set:
            errors.append(f"{identifier}: unknown roadmap phase {item.get('phase')}")
        if len(item.get("summary", "")) < 20:
            errors.append(f"{identifier}: roadmap queue summary is missing")
    if not queue_ids:
        errors.append("long-horizon roadmap execution queue must not be empty")

    if memory.get("memoryID") != "FOVEA-PROJECT-MEMORY-V1":
        errors.append("unexpected project memory identity")
    authority = memory.get("authority", {})
    if authority.get("repositoryMemoryIsAuthoritative") is not True:
        errors.append("repository memory must remain authoritative")
    if authority.get("silentSupersessionForbidden") is not True:
        errors.append("silent supersession must remain forbidden")
    if authority.get("conflictPolicy") != "fail-closed-and-record-conflict":
        errors.append("memory conflict policy must fail closed")

    requirement_ids: set[str] = set()
    for requirement in memory.get("standingRequirements", []):
        identifier = requirement.get("id") if isinstance(requirement, dict) else None
        if not isinstance(identifier, str) or identifier in requirement_ids:
            errors.append(f"invalid or duplicate standing requirement: {identifier}")
            continue
        requirement_ids.add(identifier)
        if requirement.get("status") != "active":
            errors.append(f"{identifier}: standing requirement must be active or explicitly superseded")
        if len(requirement.get("requirement", "")) < 20:
            errors.append(f"{identifier}: requirement text is missing")
        for relative in requirement.get("targets", []):
            if not isinstance(relative, str) or not (ROOT / relative).exists():
                errors.append(f"{identifier}: missing target {relative}")

    required_requirements = {
        "REQ-WORLD-CLASS-SCOPE",
        "REQ-COMPLETE-WORKLOAD-MATRIX",
        "REQ-NATIVE-UPSTREAM-TESTS",
        "REQ-SEMANTIC-COMPARABILITY",
        "REQ-BOUNDED-CLAIMS",
        "REQ-CONTINUITY",
        "REQ-NO-UNREQUESTED-GIT-PUBLISH",
        "REQ-A-TIER-COMPARATOR-MATRIX",
        "REQ-LONG-HORIZON-ROADMAP",
    }
    if requirement_ids != required_requirements:
        errors.append(
            "standing requirement set drifted: "
            f"missing={sorted(required_requirements - requirement_ids)} "
            f"unexpected={sorted(requirement_ids - required_requirements)}"
        )

    workload_rules = workloads.get("globalRules", {})
    current = memory.get("currentState", {})
    if current.get("currentExecutableWorkloads") != workload_rules.get("currentPhase0bExecutableSubset"):
        errors.append("project memory executable workloads differ from workload registry")
    if current.get("fullAcceptedWorkloadRange") != "W1-W15":
        errors.append("project memory must preserve full W1-W15 scope")
    if current.get("releaseClaimPermitted") is not False:
        errors.append("release claims must remain disabled in current state")

    obligation_ids: set[str] = set()
    active_obligations = 0
    for obligation in memory.get("openObligations", []):
        identifier = obligation.get("id") if isinstance(obligation, dict) else None
        if not isinstance(identifier, str) or identifier in obligation_ids:
            errors.append(f"invalid or duplicate obligation ID: {identifier}")
            continue
        obligation_ids.add(identifier)
        if obligation.get("status") not in {"completed", "superseded"}:
            active_obligations += 1
            if len(obligation.get("summary", "")) < 20:
                errors.append(f"{identifier}: active obligation summary is missing")
    if active_obligations == 0:
        errors.append("project memory must not silently erase all open obligations")

    protocol = memory.get("mandatoryTaskProtocol", {})
    for stage in ("beforeWork", "duringWork", "afterWork"):
        if not isinstance(protocol.get(stage), list) or not protocol[stage]:
            errors.append(f"mandatory task protocol missing {stage}")
    if not any("render-project-context.py" in step for step in protocol.get("beforeWork", [])):
        errors.append("beforeWork must require rendering the continuity context")
    if not any("long-horizon roadmap" in step.lower() for step in protocol.get("beforeWork", [])):
        errors.append("beforeWork must require reading the long-horizon roadmap")
    if not any("roadmap phase" in step.lower() for step in protocol.get("beforeWork", [])):
        errors.append("beforeWork must require mapping work to a roadmap phase")

    accepted = {
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
    for identifier, (name, purpose) in accepted.items():
        row = f"| {identifier} | {name} | {purpose} |"
        if row not in matrix_text:
            errors.append(f"accepted workload matrix drifted at {identifier}")

    result = {
        "schemaVersion": 1,
        "memoryID": memory.get("memoryID"),
        "sourceCount": len(source_ids),
        "discussionCount": len(ledger_ids),
        "standingRequirementCount": len(requirement_ids),
        "activeObligationCount": active_obligations,
        "sourceManifestSHA256": digest(source_manifest),
        "discussionLedgerSHA256": digest(ledger),
        "projectMemorySHA256": digest(memory),
        "longHorizonRoadmapSHA256": digest(roadmap),
        "longHorizonRoadmapPhaseCount": len(phase_ids),
        "workloadRegistrySHA256": digest(workloads),
        "status": "failed" if errors else "passed",
        "errors": errors,
    }
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "Project memory: "
        f"sources={len(source_ids)} discussions={len(ledger_ids)} "
        f"requirements={len(requirement_ids)} phases={len(phase_ids)} "
        f"open={active_obligations} errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
