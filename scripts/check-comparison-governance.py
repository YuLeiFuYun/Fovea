#!/usr/bin/env python3
"""验证比较本体、声明族、语义可比性和有限作用域声明策略。"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
ONTOLOGY = ROOT / "docs/research/comparison-ontology.json"
REGISTRY = ROOT / "docs/research/comparator-registry.json"
CLAIM_POLICY = ROOT / "Benchmarks/claim-policy.json"
CLAIM_FAMILIES = ROOT / "Benchmarks/statistical-claim-families.json"
NEGATIVE_RESULTS = ROOT / "docs/research/negative-results.json"
COMP_PLAN = ROOT / "Benchmarks/ComparativeLab/experiment-plan.json"
CACHE_PLAN = ROOT / "Benchmarks/CacheLab/cache-plan.json"
CHALLENGES = ROOT / "Benchmarks/ComparativeLab/challenge-suite.json"
ARTIFACT = ROOT / ".artifacts/comparators/comparison-governance.json"


def load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise TypeError(f"{path} must contain an object")
    return value


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def endpoints_from_comparative(plan: dict[str, Any]) -> tuple[set[str], dict[str, set[str]]]:
    by_workload: dict[str, set[str]] = {}
    for identifier, workload in plan.get("workloads", {}).items():
        by_workload[identifier] = set(workload.get("primaryMetrics", []))
    return set().union(*by_workload.values()) if by_workload else set(), by_workload


def endpoints_from_cache(plan: dict[str, Any]) -> tuple[set[str], dict[str, set[str]]]:
    by_workload: dict[str, set[str]] = {}
    for section in ("memoryWorkloads", "diskWorkloads"):
        for identifier, workload in plan.get(section, {}).items():
            by_workload[identifier] = set(workload.get("primaryMetrics", []))
    return set().union(*by_workload.values()) if by_workload else set(), by_workload


def main() -> int:
    ontology = load(ONTOLOGY)
    registry = load(REGISTRY)
    policy = load(CLAIM_POLICY)
    families = load(CLAIM_FAMILIES)
    negative = load(NEGATIVE_RESULTS)
    comp_plan = load(COMP_PLAN)
    cache_plan = load(CACHE_PLAN)
    challenges = load(CHALLENGES)
    errors: list[str] = []

    if ontology.get("schemaVersion") != 1 or ontology.get("ontologyID") != "FOVEA-COMPARISON-ONTOLOGY-V1":
        errors.append("unexpected comparison ontology identity")
    if registry.get("schemaVersion") != 1 or registry.get("registryID") != "FOVEA-COMPARATOR-REGISTRY-V1":
        errors.append("unexpected comparator registry identity")
    if policy.get("schemaVersion") != 2 or policy.get("claimPolicyID") != "FOVEA-STATISTICAL-CLAIM-POLICY-V2":
        errors.append("unexpected statistical claim policy identity")
    if families.get("schemaVersion") != 1 or families.get("registryID") != "FOVEA-STATISTICAL-CLAIM-FAMILIES-V1":
        errors.append("unexpected statistical claim-family identity")
    if negative.get("registryID") != "FOVEA-NEGATIVE-RESULTS-V1":
        errors.append("claim policy must bind the negative-results registry")

    class_ids = {item.get("id") for item in ontology.get("systemClasses", [])}
    expected_classes = {
        "platform-baseline", "client-pipeline", "portable-mechanism",
        "cache-system", "codec-engine", "algorithm-simulator", "adjacent-system",
    }
    if class_ids != expected_classes:
        errors.append(f"system class coverage differs: {sorted(class_ids)}")
    capability_ids = {item.get("id") for item in ontology.get("capabilities", [])}
    dimension_ids = {item.get("id") for item in ontology.get("semanticDimensions", [])}
    if len(capability_ids) < 15 or len(dimension_ids) < 10:
        errors.append("comparison ontology coverage is too small")
    for item in ontology.get("capabilities", []):
        unknown = set(item.get("hardDimensions", [])) - dimension_ids
        if unknown:
            errors.append(f"capability {item.get('id')} has unknown dimensions {sorted(unknown)}")

    comparators = registry.get("comparators", [])
    if not isinstance(comparators, list) or len(comparators) < 20:
        errors.append("comparator registry must cover at least twenty systems or baselines")
        comparators = []
    ids: set[str] = set()
    names: set[str] = set()
    allowed_eligibility = {
        "eligible-after-evidence", "not-eligible-until-adapted",
        "not-eligible-until-locked-and-adapted", "challenge-only",
        "component-only", "reference-only",
    }
    for item in comparators:
        identifier = item.get("id")
        name = item.get("name")
        if not isinstance(identifier, str) or not identifier.startswith("CMP-") or identifier in ids:
            errors.append(f"invalid or duplicate comparator id: {identifier}")
        ids.add(identifier)
        if not isinstance(name, str) or not name or name in names:
            errors.append(f"invalid or duplicate comparator name: {name}")
        names.add(name)
        if item.get("systemClass") not in class_ids:
            errors.append(f"{name}: unknown systemClass")
        if item.get("claimEligibility") not in allowed_eligibility:
            errors.append(f"{name}: unknown claimEligibility")
        unknown = set(item.get("capabilities", [])) - capability_ids
        if unknown:
            errors.append(f"{name}: unknown capabilities {sorted(unknown)}")
        source = item.get("sourceIdentity", {})
        if source.get("type") == "unlocked-research" and item.get("claimEligibility") not in {
            "reference-only", "not-eligible-until-locked-and-adapted"
        }:
            errors.append(f"{name}: unlocked research cannot support a claim")

    required_names = {
        "Fovea", "Apple URLSession + URLCache + ImageIO", "Apple AsyncImage", "Nuke", "Kingfisher",
        "SDWebImage", "AlamofireImage", "PINRemoteImage", "Glide", "Coil", "Fresco",
        "Picasso", "YYWebImage", "LRUCache", "PINCache", "Caffeine", "Moka",
        "Ristretto", "CacheLib", "libvips", "image-rs", "libCacheSim",
    }
    if not required_names <= names:
        errors.append(f"missing required comparison archetypes: {sorted(required_names - names)}")

    comparator_lock = load(ROOT / "docs/research/comparator-lock.json")
    matrix = comparator_lock.get("matrixPolicy", {})
    expected_a_tier = [
        "Apple URLSession + URLCache + ImageIO", "Apple AsyncImage", "Nuke", "Kingfisher",
        "SDWebImage", "PINRemoteImage", "Fovea",
    ]
    if matrix.get("aTierUnifiedApp") != expected_a_tier:
        errors.append("A-tier Apple-platform comparator matrix drifted")
    if matrix.get("bTierRetained") != ["AlamofireImage"]:
        errors.append("AlamofireImage must remain the sole B-tier retained comparator")
    registry_by_name = {item.get("name"): item for item in comparators}
    expected_roles = {
        "Apple URLSession + URLCache + ImageIO": ("A", "required-platform-baseline", "harness-app"),
        "Apple AsyncImage": ("A", "required-platform-baseline", "independent-swiftui-surface"),
        "Nuke": ("A", "required-direct", "harness-app"),
        "Kingfisher": ("A", "required-direct", "harness-app"),
        "SDWebImage": ("A", "required-direct", "harness-app"),
        "PINRemoteImage": ("A", "required-direct", "harness-app"),
        "AlamofireImage": ("B", "secondary-direct", "harness-app"),
    }
    for name, (tier, role, mode) in expected_roles.items():
        item = registry_by_name.get(name, {})
        if item.get("researchTier") != tier or item.get("role") != role or item.get("executionMode") != mode:
            errors.append(f"{name}: A/B tier, role, or execution mode drifted")
        if item.get("claimEligibility") != "eligible-after-evidence":
            errors.append(f"{name}: implemented comparator must be evidence-eligible")
    for relative in (
        "Benchmarks/ComparativeLab/Adapters/AppleNativeAdapterPackage",
        "Benchmarks/ComparativeLab/Adapters/PINRemoteImageAdapterPackage",
        "Benchmarks/AsyncImageLab/experiment-plan.json",
        "Benchmarks/AsyncImageLab/applicability.json",
    ):
        if not (ROOT / relative).exists():
            errors.append(f"missing mandatory A-tier integration asset: {relative}")
    project_text = (ROOT / "Benchmarks/ComparativeLab/Apps/project.yml").read_text()
    for target in ("AppleNativeComparatorBench:", "AsyncImageComparatorBench:", "PINRemoteImageComparatorBench:"):
        if target not in project_text:
            errors.append(f"unified comparison app project is missing {target}")

    image_lock = {item["name"]: item for item in comparator_lock.get("comparators", [])}
    cache_lock = {item["name"]: item for item in load(ROOT / "docs/research/cache-comparator-lock.json").get("comparators", [])}
    research_lock = {item["name"]: item for item in load(ROOT / "docs/research/network-image-loader-test-sources.json").get("sources", [])}
    for item in comparators:
        name = item.get("name")
        source_type = item.get("sourceIdentity", {}).get("type")
        if source_type == "comparator-lock" and name not in image_lock:
            errors.append(f"{name}: missing from comparator lock")
        if source_type == "cache-comparator-lock" and name not in cache_lock:
            errors.append(f"{name}: missing from cache comparator lock")
        if source_type == "research-source-lock" and name not in research_lock:
            errors.append(f"{name}: missing from research source lock")

    challenge_projects = {
        source.get("project")
        for challenge in challenges.get("challenges", [])
        for source in challenge.get("sources", [])
        if isinstance(source.get("project"), str)
    }
    if challenge_projects - names:
        errors.append(f"challenge projects absent from registry: {sorted(challenge_projects - names)}")

    expected_bindings = {
        "ontology": "docs/research/comparison-ontology.json",
        "comparatorRegistry": "docs/research/comparator-registry.json",
        "claimFamilies": "Benchmarks/statistical-claim-families.json",
        "negativeResultsRegistry": "docs/research/negative-results.json",
    }
    for key, value in expected_bindings.items():
        if policy.get(key) != value:
            errors.append(f"claim policy does not bind {key}")
    if set(policy.get("semanticProfileDimensions", [])) != dimension_ids:
        errors.append("claim policy semantic dimensions differ from ontology")
    if [item.get("id") for item in policy.get("durabilityLevels", [])] != ["D0", "D1", "D2", "D3", "D4", "D5"]:
        errors.append("durability hierarchy must remain D0 through D5")
    orientation = policy.get("metricOrientation", {})
    if "lower is better" not in orientation.get("canonicalLoss", "") or "positive values favor Fovea" not in orientation.get("orientedAdvantage", ""):
        errors.append("metric orientation and canonical loss are not explicit")
    levels = {item.get("id"): item for item in policy.get("certificateLevels", [])}
    if set(levels) != {"L1-hard", "L2-primary-portfolio", "L3-secondary-frontier", "L4-research"}:
        errors.append("certificate hierarchy must contain L1 through L4")
    scope = policy.get("scopeCertificate", {})
    if scope.get("globalWorldBestMarketingClaim") != "forbidden":
        errors.append("unbounded world-best marketing claims must be forbidden")
    if "best-within-scope" not in scope.get("allowedOutputs", []):
        errors.append("best-within-scope output is missing")
    if set(ontology.get("claimStates", [])) - set(scope.get("allowedOutputs", [])):
        errors.append("scope policy drops existing ontology claim states")
    statistical = policy.get("statisticalDecision", {})
    if "TOST" not in statistical.get("equivalence", ""):
        errors.append("equivalence must require TOST")
    if "hierarchical gatekeeping" not in statistical.get("multipleComparisons", ""):
        errors.append("hierarchical gatekeeping is missing")
    if statistical.get("prohibitedTieRule") != "p-value-above-0.05-is-not-equivalence":
        errors.append("non-significance must not be treated as a tie")
    if policy.get("distributionDiagnostics", {}).get("extremeValueTheory", "").startswith("Research") is False:
        errors.append("EVT must remain a research sensitivity analysis")

    comp_metrics, comp_by_workload = endpoints_from_comparative(comp_plan)
    cache_metrics, cache_by_workload = endpoints_from_cache(cache_plan)
    plan_by_path = {
        "Benchmarks/ComparativeLab/experiment-plan.json": (comp_metrics, comp_by_workload),
        "Benchmarks/CacheLab/cache-plan.json": (cache_metrics, cache_by_workload),
    }
    family_entries = families.get("families", [])
    if not isinstance(family_entries, list) or len(family_entries) < 6:
        errors.append("claim-family registry must contain the six current families")
        family_entries = []
    family_ids: set[str] = set()
    covered: dict[str, set[str]] = {path: set() for path in plan_by_path}
    for family in family_entries:
        identifier = family.get("id")
        if not isinstance(identifier, str) or not identifier.startswith("CLAIM-") or identifier in family_ids:
            errors.append(f"invalid or duplicate claim family: {identifier}")
        family_ids.add(identifier)
        level = family.get("certificateLevel")
        if level not in levels:
            errors.append(f"{identifier}: unknown certificate level {level}")
        source = family.get("sourcePlan")
        if source not in plan_by_path:
            errors.append(f"{identifier}: unknown source plan {source}")
            continue
        plan_metrics, workload_map = plan_by_path[source]
        workloads = family.get("workloadIDs", [])
        if not workloads or any(item not in workload_map for item in workloads):
            errors.append(f"{identifier}: unknown or empty workloadIDs")
        primary = set(family.get("primaryEndpoints", []))
        expected = set().union(*(workload_map.get(item, set()) for item in workloads))
        if primary != expected:
            errors.append(f"{identifier}: primary endpoints differ from source workload: expected={sorted(expected)} actual={sorted(primary)}")
        if not primary <= plan_metrics:
            errors.append(f"{identifier}: endpoint absent from source plan")
        if level == "L1-hard" and primary:
            errors.append(f"{identifier}: L1 hard family cannot contain quantitative primary endpoints")
        if level == "L2-primary-portfolio" and not primary:
            errors.append(f"{identifier}: L2 family must contain primary endpoints")
        if family.get("activation") != "active" and "family-digest" not in str(family.get("activation")):
            errors.append(f"{identifier}: future evidence activation rule is missing")
        covered[source].update(primary)
    if covered["Benchmarks/ComparativeLab/experiment-plan.json"] != comp_metrics:
        errors.append("comparative primary metrics are not covered exactly once by claim families")
    if covered["Benchmarks/CacheLab/cache-plan.json"] != cache_metrics:
        errors.append("cache primary metrics are not covered by claim families")

    for plan, name in ((comp_plan, "comparative"), (cache_plan, "cache")):
        if plan.get("statisticalClaimFamilies") != "Benchmarks/statistical-claim-families.json":
            errors.append(f"{name} plan does not bind statistical claim families")

    documents = {
        "ontologySHA256": hashlib.sha256(canonical(ontology)).hexdigest(),
        "comparatorRegistrySHA256": hashlib.sha256(canonical(registry)).hexdigest(),
        "claimPolicySHA256": hashlib.sha256(canonical(policy)).hexdigest(),
        "claimFamiliesSHA256": hashlib.sha256(canonical(families)).hexdigest(),
        "negativeResultsSHA256": hashlib.sha256(canonical(negative)).hexdigest(),
        "comparativePlanSHA256": hashlib.sha256(canonical(comp_plan)).hexdigest(),
        "cachePlanSHA256": hashlib.sha256(canonical(cache_plan)).hexdigest(),
    }
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps({
        "schemaVersion": 2,
        "status": "failed" if errors else "passed",
        "comparatorCount": len(comparators),
        "claimFamilyCount": len(family_entries),
        "capabilityCount": len(capability_ids),
        "semanticDimensionCount": len(dimension_ids),
        "digests": documents,
        "errors": errors,
    }, indent=2, sort_keys=True) + "\n")
    print(
        "Comparison governance: "
        f"comparators={len(comparators)} families={len(family_entries)} "
        f"capabilities={len(capability_ids)} dimensions={len(dimension_ids)} errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
