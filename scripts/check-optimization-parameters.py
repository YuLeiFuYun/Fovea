#!/usr/bin/env python3
"""验证优化参数来源、量纲、反例和 benchmark 独立性。"""
from __future__ import annotations
import argparse
import json
import re
from pathlib import Path

from component_paths import ComponentPathError, resolve_reference

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "docs/research/optimization-parameter-registry.json"
ALLOWED_CATEGORY = {"semantic", "resource-derived", "theorem-derived", "heuristic"}
ALLOWED_STATUS = {"approved", "provisional", "rejected"}
REQUIRED = {
    "id", "symbol", "category", "status", "unit", "codePath", "codeFragment",
    "defaultExpression", "derivation", "validRange", "sensitivityEvidence",
    "falsifiers", "benchmarkIndependent", "independenceRationale",
}
BANNED_IN_DERIVATION = (
    r"W\d+(?:-|\b)",
    r"fixture",
    r"comparator",
    r"dataset\s+index",
    r"asset\s+index",
)


def nonempty_strings(value: object) -> bool:
    return (
        isinstance(value, list)
        and bool(value)
        and all(isinstance(item, str) and item.strip() for item in value)
    )


def numeric_candidates() -> list[tuple[str, int, str]]:
    pattern = re.compile(
        r"\b(?:static\s+let|let)\s+\w+[^=]*=\s*[0-9][0-9_]*(?:\s*\*\s*[0-9][0-9_]*)*"
    )
    rows: list[tuple[str, int, str]] = []
    for path in (ROOT / "Sources").rglob("*.swift"):
        if "/FoveaTesting/" in str(path):
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if pattern.search(line):
                rows.append((path.relative_to(ROOT).as_posix(), number, line.strip()))
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--strict",
        action="store_true",
        help="拒绝仍处于 provisional 的生产参数",
    )
    args = parser.parse_args()

    document = json.loads(REGISTRY.read_text())
    errors: list[str] = []
    if document.get("schemaVersion") != 1:
        errors.append("schemaVersion 必须为 1")
    entries = document.get("entries", [])
    if not isinstance(entries, list):
        errors.append("entries 必须为数组")
        entries = []

    seen: set[str] = set()
    provisional = 0
    for index, entry in enumerate(entries):
        label = entry.get("id", f"index-{index}") if isinstance(entry, dict) else f"index-{index}"
        if not isinstance(entry, dict):
            errors.append(f"{label}: entry 非对象")
            continue
        missing = REQUIRED - entry.keys()
        if missing:
            errors.append(f"{label}: 缺少字段 {sorted(missing)}")
            continue
        if label in seen:
            errors.append(f"{label}: ID 重复")
        seen.add(label)
        if entry["category"] not in ALLOWED_CATEGORY:
            errors.append(f"{label}: category 非法")
        if entry["status"] not in ALLOWED_STATUS:
            errors.append(f"{label}: status 非法")
        if entry["status"] == "provisional":
            provisional += 1
        if entry["benchmarkIndependent"] is not True:
            errors.append(f"{label}: benchmarkIndependent 必须显式为 true")
        for field in ("sensitivityEvidence", "falsifiers"):
            if not nonempty_strings(entry[field]):
                errors.append(f"{label}: {field} 必须非空")
        try:
            path = resolve_reference(entry["codePath"])
        except ComponentPathError as error:
            errors.append(f"{label}: codePath 解析失败 {entry['codePath']}: {error}")
            path = Path("/__invalid_component_path__")
        if not path.is_file():
            errors.append(f"{label}: codePath 不存在 {entry['codePath']}")
        elif entry["codeFragment"] not in path.read_text():
            errors.append(f"{label}: codeFragment 未匹配源码")
        for relative in entry["sensitivityEvidence"]:
            try:
                evidence = resolve_reference(relative)
            except ComponentPathError as error:
                errors.append(f"{label}: evidence 解析失败 {relative}: {error}")
                continue
            if not evidence.exists():
                errors.append(f"{label}: evidence 不存在 {relative}")
        derivation_material = " ".join(
            str(entry[field]) for field in ("derivation", "defaultExpression", "validRange")
        )
        if any(re.search(pattern, derivation_material, re.I) for pattern in BANNED_IN_DERIVATION):
            errors.append(f"{label}: 参数推导本身包含 benchmark 特化标识")
        if len(entry["derivation"].strip()) < 32:
            errors.append(f"{label}: derivation 过短")
        if len(entry["independenceRationale"].strip()) < 24:
            errors.append(f"{label}: independenceRationale 过短")
        if (
            entry["category"] == "heuristic"
            and entry["status"] == "approved"
            and len(entry["sensitivityEvidence"]) < 2
        ):
            errors.append(f"{label}: 已批准 heuristic 缺少跨证据敏感性")
        if entry["status"] == "rejected" and path.is_file() and entry["codeFragment"] in path.read_text():
            errors.append(f"{label}: rejected 参数仍在生产源码中活动")

    candidates = numeric_candidates()
    coverage = len(entries) / len(candidates) if candidates else 1.0
    if args.strict and provisional:
        errors.append(f"严格模式禁止 provisional 参数，count={provisional}")
    print(
        "Optimization parameter registry: "
        f"registered={len(entries)} numericCandidates={len(candidates)} "
        f"reviewCoverage={coverage:.3f} provisional={provisional} errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
