#!/usr/bin/env python3
"""证明 namespace generation JSON 清单的线性字节预算覆盖最坏规范编码。"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources/FoveaPersistence/NamespaceGenerationStore.swift"
TEXT = SOURCE.read_text()


def integer(name: str) -> int:
    match = re.search(rf"{re.escape(name)}\s*=\s*([0-9_]+(?:\s*\*\s*[0-9_]+)*)", TEXT)
    if not match:
        raise RuntimeError(f"missing numeric constant: {name}")
    values = [int(part.replace("_", "")) for part in match.group(1).split("*")]
    result = 1
    for value in values:
        result *= value
    return result


def main() -> int:
    fixed_budget = integer("fixedMetadataBudget")
    per_namespace_budget = integer("perNamespaceMetadataBudget")

    fingerprint_bytes = 64  # lowercase SHA-256 hex, validated before insertion
    uint64_decimal_bytes = len(str(2**64 - 1))
    # "<64hex>":<20digits>, ；最后一个条目没有逗号，因此该式仍是上界。
    entry_upper_bound = 2 + fingerprint_bytes + 1 + uint64_decimal_bytes + 1
    # {"schemaVersion":1,"generations":{}}；字段顺序不改变字节数。
    fixed_upper_bound = len('{"schemaVersion":1,"generations":{}}'.encode())

    errors: list[str] = []
    if per_namespace_budget < entry_upper_bound:
        errors.append(
            f"perNamespaceMetadataBudget={per_namespace_budget} < entryUpper={entry_upper_bound}"
        )
    if fixed_budget < fixed_upper_bound:
        errors.append(f"fixedMetadataBudget={fixed_budget} < fixedUpper={fixed_upper_bound}")

    # 检查边界 count 的整数算术；Python 大整数作为独立 oracle。
    maximum_namespaces = 1_000_000
    total_budget = fixed_budget + maximum_namespaces * per_namespace_budget
    exact_upper = fixed_upper_bound + maximum_namespaces * entry_upper_bound
    if total_budget < exact_upper:
        errors.append(f"totalBudget={total_budget} < exactUpper={exact_upper}")

    print(
        "Namespace manifest bound: "
        f"fixedBudget={fixed_budget} fixedUpper={fixed_upper_bound} "
        f"perEntryBudget={per_namespace_budget} perEntryUpper={entry_upper_bound} "
        f"maxCount={maximum_namespaces} totalSlack={total_budget-exact_upper} "
        f"errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
