#!/usr/bin/env python3
"""验证逐 target 数学证明义务与最优性声明类型。"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

from component_paths import ComponentPathError, resolve_reference

ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / 'docs/research/mathematical-proof-obligations.json'
ALLOWED_STATUS = {
    'model-checked', 'exhaustive-and-tested', 'tested-refinement-gap',
    'specified-gap', 'empirical-gated', 'research', 'rejected',
}
REQUIRED = {
    'id', 'target', 'subject', 'claimClass', 'objective', 'domain', 'constraints',
    'assumptions', 'invariants', 'liveness', 'optimalityStatement', 'refinementMap',
    'codePaths', 'evidencePaths', 'falsifiers', 'status', 'claimBoundary', 'residualRisk',
}
OPTIMAL = {
    'exact-finite-optimum', 'competitive-bound', 'regret-bound',
    'local-optimum', 'pareto-optimum',
}
ARRAY_FIELDS = (
    'constraints', 'assumptions', 'invariants', 'liveness',
    'codePaths', 'evidencePaths', 'falsifiers',
)
TEXT_FIELDS = (
    'objective', 'domain', 'optimalityStatement',
    'refinementMap', 'claimBoundary', 'residualRisk',
)


def strings(value: object) -> bool:
    return (
        isinstance(value, list)
        and bool(value)
        and all(isinstance(item, str) and item.strip() for item in value)
    )


def validate_document_header(document: dict[str, Any], errors: list[str]) -> None:
    if document.get('schemaVersion') != 1:
        errors.append('schemaVersion 必须为 1')


def validate_required_fields(
    obligation: dict[str, Any],
    label: str,
    errors: list[str],
) -> bool:
    missing = REQUIRED - set(obligation)
    if missing:
        errors.append(f'{label}: 缺少字段 {sorted(missing)}')
        return False
    return True


def validate_field_shapes(
    obligation: dict[str, Any],
    label: str,
    errors: list[str],
) -> None:
    for field in ARRAY_FIELDS:
        if not strings(obligation[field]):
            errors.append(f'{label}: {field} 必须为非空字符串数组')
    for field in TEXT_FIELDS:
        value = obligation[field]
        if not isinstance(value, str) or len(value.strip()) < 16:
            errors.append(f'{label}: {field} 过短')


def validate_claim_semantics(
    obligation: dict[str, Any],
    label: str,
    classes: set[str],
    errors: list[str],
) -> None:
    claim_class = obligation['claimClass']
    if claim_class not in classes:
        errors.append(f'{label}: claimClass 非法')
    if obligation['status'] not in ALLOWED_STATUS:
        errors.append(f'{label}: status 非法 {obligation["status"]}')
    if claim_class in OPTIMAL:
        statement = obligation['optimalityStatement']
        if '全局绝对最优' not in statement and len(statement) < 32:
            errors.append(f'{label}: 最优性声明必须明确边界')
    if claim_class == 'liveness-under-fairness':
        assumptions = obligation['assumptions'] + obligation['liveness']
        if not any('公平' in item or '完成' in item for item in assumptions):
            errors.append(f'{label}: 活性声明缺少公平/最终完成假设')


def validate_paths(
    obligation: dict[str, Any],
    label: str,
    errors: list[str],
) -> None:
    if obligation['status'] in {'research', 'rejected'}:
        return
    for relative in obligation['codePaths'] + obligation['evidencePaths']:
        try:
            path = resolve_reference(relative)
        except ComponentPathError as error:
            errors.append(f'{label}: 路径解析失败 {relative}: {error}')
            continue
        if not path.exists():
            errors.append(f'{label}: 路径不存在 {relative}')


def validate_obligation(
    value: object,
    index: int,
    classes: set[str],
    targets: set[str],
    seen: set[str],
    covered: set[str],
    errors: list[str],
) -> None:
    fallback = f'index-{index}'
    if not isinstance(value, dict):
        errors.append(f'{fallback}: obligation 不是对象')
        return
    label = value.get('id', fallback)
    if not validate_required_fields(value, label, errors):
        return
    if label in seen:
        errors.append(f'{label}: ID 重复')
    seen.add(label)
    target = value['target']
    covered.add(target)
    if target != 'PROJECT' and target not in targets:
        errors.append(f'{label}: 未登记 target {target}')
    validate_field_shapes(value, label, errors)
    validate_claim_semantics(value, label, classes, errors)
    validate_paths(value, label, errors)


def validate_coverage(
    obligations: list[object],
    targets: set[str],
    covered: set[str],
    errors: list[str],
) -> None:
    missing_targets = targets - covered
    if missing_targets:
        errors.append(f'生产 target 未覆盖: {sorted(missing_targets)}')
    dictionaries = [item for item in obligations if isinstance(item, dict)]
    if not any(item.get('claimClass') == 'empirical-dominance' for item in dictionaries):
        errors.append('缺少端到端经验占优证明义务')
    if not any(item.get('claimClass') == 'pareto-optimum' for item in dictionaries):
        errors.append('缺少多目标架构 Pareto 证明义务')


def run_codec_model(errors: list[str]) -> None:
    model = subprocess.run(
        [sys.executable, str(ROOT / 'scripts/model-check-image-codec-contract.py')],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if model.stdout.strip():
        print(model.stdout.strip())
    if model.returncode != 0:
        errors.append('图像 codec 契约模型检查失败')


def main() -> int:
    document = json.loads(PATH.read_text())
    errors: list[str] = []
    validate_document_header(document, errors)
    classes = set(document.get('claimClasses', []))
    targets = set(document.get('productionTargets', []))
    obligations = document.get('obligations', [])
    values = obligations if isinstance(obligations, list) else []
    seen: set[str] = set()
    covered: set[str] = set()
    for index, obligation in enumerate(values):
        validate_obligation(obligation, index, classes, targets, seen, covered, errors)
    validate_coverage(values, targets, covered, errors)
    run_codec_model(errors)
    print(
        f'Mathematical proof obligations: targets={len(targets)} '
        f'obligations={len(values)} covered={len(targets & covered)} errors={len(errors)}'
    )
    for error in errors:
        print(f'error: {error}')
    return 1 if errors else 0


if __name__ == '__main__':
    raise SystemExit(main())
