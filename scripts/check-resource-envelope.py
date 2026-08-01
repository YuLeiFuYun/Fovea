#!/usr/bin/env python3
"""验证跨模块资源包络绑定和值关系。"""
from __future__ import annotations
import ast
import json
import operator
import re
from pathlib import Path

from component_paths import ComponentPathError, resolve_reference

ROOT = Path(__file__).resolve().parents[1]
SPEC = ROOT / "docs/specifications/resource-envelope.json"
OPS = {
    ast.Add: operator.add,
    ast.Sub: operator.sub,
    ast.Mult: operator.mul,
    ast.FloorDiv: operator.floordiv,
    ast.LShift: operator.lshift,
}


def evaluate(expression: str) -> int:
    node = ast.parse(expression.replace("_", ""), mode="eval").body
    def visit(value: ast.AST) -> int:
        if isinstance(value, ast.Constant) and isinstance(value.value, int):
            return value.value
        if isinstance(value, ast.BinOp) and type(value.op) in OPS:
            return OPS[type(value.op)](visit(value.left), visit(value.right))
        raise ValueError(f"unsupported expression: {expression}")
    result = visit(node)
    if result < 0:
        raise ValueError(f"negative expression: {expression}")
    return result


def main() -> int:
    document = json.loads(SPEC.read_text())
    errors: list[str] = []
    values: dict[str, int] = {}
    seen: set[str] = set()
    for bound in document.get("bounds", []):
        identifier = bound.get("id", "<missing>")
        if identifier in seen:
            errors.append(f"duplicate bound {identifier}")
        seen.add(identifier)
        try:
            expected = evaluate(bound["valueExpression"])
            values[identifier] = expected
        except Exception as error:
            errors.append(f"{identifier}: invalid valueExpression: {error}")
            continue
        if bound.get("status") != "approved":
            errors.append(f"{identifier}: resource envelope 只允许 approved bound")
        if len(bound.get("rationale", "").strip()) < 32:
            errors.append(f"{identifier}: rationale 过短")
        bindings = bound.get("bindings", [])
        if not bindings:
            errors.append(f"{identifier}: bindings 为空")
        for binding in bindings:
            try:
                path = resolve_reference(binding["codePath"])
            except ComponentPathError as error:
                errors.append(f"{identifier}: path 解析失败 {binding['codePath']}: {error}")
                continue
            fragment = binding["codeFragment"]
            if not path.is_file():
                errors.append(f"{identifier}: path 不存在 {binding['codePath']}")
                continue
            text = path.read_text()
            if fragment not in text:
                errors.append(f"{identifier}: fragment 未匹配 {binding['codePath']}: {fragment}")
                continue
            match = re.search(r"=\s*([0-9_]+(?:\s*\*\s*[0-9_]+)*)", fragment)
            if not match:
                errors.append(f"{identifier}: fragment 无可解析数值表达式")
                continue
            actual = evaluate(match.group(1))
            if actual != expected:
                errors.append(f"{identifier}: {binding['codePath']} actual={actual} expected={expected}")
        if not bound.get("falsifiers"):
            errors.append(f"{identifier}: falsifiers 为空")

    for relation in document.get("relations", []):
        left = values.get(relation["left"])
        right = (
            values.get(relation["right"])
            if "right" in relation
            else evaluate(relation["rightExpression"])
        )
        if left is None or right is None:
            errors.append(f"relation unresolved: {relation}")
            continue
        op = relation["operator"]
        valid = {"<=": left <= right, "<": left < right, "==": left == right}.get(op)
        if valid is None:
            errors.append(f"unsupported relation operator {op}")
        elif not valid:
            errors.append(f"relation failed: {relation['left']} {op} {relation.get('right', relation.get('rightExpression'))}")

    print(f"Resource envelope: bounds={len(values)} relations={len(document.get('relations', []))} errors={len(errors)}")
    for error in errors:
        print(f"error: {error}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
