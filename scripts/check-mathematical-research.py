#!/usr/bin/env python3
"""验证数学理论注册表的来源、假设、反例与实现证据。"""

from __future__ import annotations

from datetime import date
import json
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "docs/research/mathematical-theory-registry.json"
ALLOWED_STATUS = {"implemented", "research", "proposed", "rejected"}
REQUIRED_FIELDS = {
    "id", "area", "theory", "status", "sources", "assumptions", "mechanism",
    "decision", "codePaths", "evidencePaths", "falsifiers", "claimBoundary",
}


def nonempty_strings(value: object) -> bool:
    return isinstance(value, list) and bool(value) and all(isinstance(item, str) and item.strip() for item in value)


def main() -> int:
    document = json.loads(REGISTRY.read_text())
    errors: list[str] = []
    if document.get("schemaVersion") != 1:
        errors.append("registry schemaVersion 必须为 1")
    entries = document.get("entries")
    if not isinstance(entries, list) or not entries:
        errors.append("registry entries 必须为非空数组")
        entries = []

    identifiers: set[str] = set()
    statuses: set[str] = set()
    areas: set[str] = set()
    current_year = date.today().year
    for index, entry in enumerate(entries):
        label = entry.get("id", f"index-{index}") if isinstance(entry, dict) else f"index-{index}"
        if not isinstance(entry, dict):
            errors.append(f"{label}: entry 不是对象")
            continue
        missing = REQUIRED_FIELDS - entry.keys()
        if missing:
            errors.append(f"{label}: 缺少字段 {sorted(missing)}")
            continue
        identifier = entry["id"]
        if not isinstance(identifier, str) or not identifier.startswith("FOVEA-MATH-"):
            errors.append(f"{label}: ID 格式非法")
        if identifier in identifiers:
            errors.append(f"{label}: ID 重复")
        identifiers.add(identifier)
        status = entry["status"]
        statuses.add(status)
        areas.add(entry["area"])
        if status not in ALLOWED_STATUS:
            errors.append(f"{label}: status 非法 {status}")
        for field in ("assumptions", "codePaths", "evidencePaths", "falsifiers"):
            if not nonempty_strings(entry[field]):
                errors.append(f"{label}: {field} 必须为非空字符串数组")
        for field in ("theory", "mechanism", "decision", "claimBoundary"):
            if not isinstance(entry[field], str) or len(entry[field].strip()) < 12:
                errors.append(f"{label}: {field} 过短或为空")

        sources = entry["sources"]
        if not isinstance(sources, list) or not sources:
            errors.append(f"{label}: sources 为空")
            sources = []
        newest = 0
        for source in sources:
            if not isinstance(source, dict) or not {"title", "year", "url", "kind"} <= source.keys():
                errors.append(f"{label}: source 字段不完整")
                continue
            year = source["year"]
            if not isinstance(year, int) or not 1800 <= year <= current_year:
                errors.append(f"{label}: source year 非法 {year}")
            else:
                newest = max(newest, year)
            parsed = urlparse(str(source["url"]))
            if parsed.scheme != "https" or not parsed.netloc:
                errors.append(f"{label}: source 必须使用可解析 HTTPS URL")
        if status in {"research", "proposed", "rejected"} and newest < current_year - 2:
            errors.append(f"{label}: 前沿/候选/拒绝项缺少近三年来源")

        if status == "implemented":
            for relative in [*entry["codePaths"], *entry["evidencePaths"]]:
                if not (ROOT / relative).exists():
                    errors.append(f"{label}: implemented 路径不存在 {relative}")
        if status == "rejected" and "不" not in entry["decision"] and "拒绝" not in entry["decision"]:
            errors.append(f"{label}: rejected 项必须明确拒绝理由")

    if statuses != ALLOWED_STATUS:
        errors.append(f"注册表必须覆盖全部状态，observed={sorted(statuses)}")
    if len(areas) < 7:
        errors.append(f"数学研究覆盖领域不足：{sorted(areas)}")
    if len(entries) < 12:
        errors.append("数学研究条目少于 12")

    print(
        "Mathematical research registry: "
        f"entries={len(entries)} areas={len(areas)} statuses={len(statuses)} errors={len(errors)}"
    )
    if errors:
        for error in errors:
            print(f"error: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
