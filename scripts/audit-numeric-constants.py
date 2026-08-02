#!/usr/bin/env python3
"""盘点生产源码数值常数，并区分发现覆盖、完成审查和发布缺口。"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

from component_paths import is_component_reference, resolve_reference

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "docs/research/optimization-parameter-registry.json"
RESOURCE_ENVELOPE = ROOT / "docs/specifications/resource-envelope.json"
ARTIFACT = ROOT / ".artifacts/mathematics/numeric-constant-inventory.json"
PATTERN = re.compile(
    r"\b(?P<prefix>(?:public|package|private|internal)?\s*(?:static\s+)?)"
    r"let\s+(?P<symbol>\w+)[^=]*=\s*"
    r"(?P<expression>0[xX][0-9a-fA-F_]+|[0-9][0-9_]*(?:\s*\*\s*[0-9][0-9_]*)*)"
)
FORMAT_DISCRIMINATORS = {
    ("component://ImageCraft/Sources/ImageCraftImageIO/EncodedImageSecurityInspector.swift", symbol)
    for symbol in ("pngIEND", "pngICCP", "pngEXIF", "pngITXT", "pngTEXT", "pngZTXT", "pngSRGB")
}


def candidate_sources() -> list[tuple[str, Path]]:
    sources: dict[str, Path] = {}
    for path in (ROOT / "Sources").rglob("*.swift"):
        relative = path.relative_to(ROOT).as_posix()
        if "/FoveaTesting/" not in relative:
            sources[relative] = path
    registry = json.loads(REGISTRY.read_text())
    envelope = json.loads(RESOURCE_ENVELOPE.read_text())
    references = [entry.get("codePath") for entry in registry.get("entries", [])]
    references.extend(
        binding.get("codePath")
        for bound in envelope.get("bounds", [])
        for binding in bound.get("bindings", [])
    )
    for reference in references:
        if isinstance(reference, str) and is_component_reference(reference):
            sources[reference] = resolve_reference(reference)
    return sorted(sources.items())


def candidates() -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for reference, path in candidate_sources():
        if not path.is_file():
            raise FileNotFoundError(f"numeric audit source missing: {reference}")
        for line_number, line in enumerate(path.read_text().splitlines(), 1):
            match = PATTERN.search(line)
            if not match:
                continue
            result.append(
                {
                    "codePath": reference,
                    "line": line_number,
                    "symbol": match.group("symbol"),
                    "expression": match.group("expression"),
                    "source": line.strip(),
                }
            )
    return result


def bindings() -> list[tuple[str, str, str, str]]:
    document = json.loads(REGISTRY.read_text())
    result: list[tuple[str, str, str, str]] = []
    for entry in document.get("entries", []):
        result.append((entry["id"], entry["status"], entry["codePath"], entry["codeFragment"]))
    envelope = json.loads(RESOURCE_ENVELOPE.read_text())
    for bound in envelope.get("bounds", []):
        for binding in bound.get("bindings", []):
            result.append((bound["id"], bound["status"], binding["codePath"], binding["codeFragment"]))
    return result


def classify(candidate: dict[str, object], registered: list[tuple[str, str, str, str]]) -> dict[str, object]:
    path = str(candidate["codePath"])
    source = str(candidate["source"])
    symbol = str(candidate["symbol"])
    matches = [
        {"parameterID": identifier, "status": status}
        for identifier, status, code_path, fragment in registered
        if code_path == path and fragment in source
    ]
    if matches:
        statuses = {item["status"] for item in matches}
        return {
            **candidate,
            "reviewClass": "registered-parameter",
            "reviewStatus": "approved" if statuses == {"approved"} else "provisional",
            "parameterBindings": matches,
            "rationale": "由优化参数注册表提供量纲、推导、反例与敏感性证据。",
        }
    if (
        "SchemaVersion" in symbol
        or symbol == "schemaVersion"
        or symbol == "currentContractVersion"
    ):
        return {
            **candidate,
            "reviewClass": "schema-discriminator",
            "reviewStatus": "approved",
            "parameterBindings": [],
            "rationale": "该整数是持久化、诊断或公开契约的版本判别符，不是可调性能参数；变化必须伴随迁移和兼容性证明。",
        }
    if (path, symbol) in FORMAT_DISCRIMINATORS:
        return {
            **candidate,
            "reviewClass": "format-discriminator",
            "reviewStatus": "approved",
            "parameterBindings": [],
            "rationale": "该十六进制值由 PNG 规范定义为固定 chunk type 四字节码，不是经验阈值或可调策略。",
        }
    if "tableSize = 3 * (1 <<" in source:
        return {
            **candidate,
            "reviewClass": "format-derived",
            "reviewStatus": "approved",
            "parameterBindings": [],
            "rationale": "该表达式直接来自 GIF 调色板三通道与格式位字段定义，不是经验阈值。",
        }
    return {
        **candidate,
        "reviewClass": "unreviewed-numeric-policy",
        "reviewStatus": "unreviewed",
        "parameterBindings": [],
        "rationale": "尚未在参数注册表中给出推导、适用域、敏感性和推翻条件。",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--strict", action="store_true", help="拒绝 provisional 与 unreviewed 数值")
    args = parser.parse_args()

    raw = candidates()
    registered = bindings()
    inventory = [classify(item, registered) for item in raw]
    counts = {
        status: sum(item["reviewStatus"] == status for item in inventory)
        for status in ("approved", "provisional", "unreviewed")
    }
    discovered = len(inventory)
    completed = counts["approved"]
    addressed = counts["approved"] + counts["provisional"]
    document = {
        "schemaVersion": 1,
        "candidateCount": discovered,
        "inventoryCoverage": 1.0,
        "addressedReviewRate": addressed / discovered if discovered else 1.0,
        "completedReviewRate": completed / discovered if discovered else 1.0,
        "counts": counts,
        "entries": inventory,
    }
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n")

    errors: list[str] = []
    if args.strict and (counts["provisional"] or counts["unreviewed"]):
        errors.append(
            "严格模式要求全部数值完成审查："
            f"provisional={counts['provisional']} unreviewed={counts['unreviewed']}"
        )
    print(
        "Numeric constant audit: "
        f"candidates={discovered} inventoryCoverage=1.000 "
        f"addressedReviewRate={document['addressedReviewRate']:.3f} "
        f"completedReviewRate={document['completedReviewRate']:.3f} "
        f"approved={counts['approved']} provisional={counts['provisional']} "
        f"unreviewed={counts['unreviewed']} errors={len(errors)}"
    )
    print(f"Artifact: {ARTIFACT.relative_to(ROOT)}")
    for error in errors:
        print(f"error: {error}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
