from __future__ import annotations

import datetime as dt
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable


@dataclass(frozen=True)
class StructuralAuditContext:
    root: Path
    sources: Path
    project_modules: set[str]
    allowed_project_imports: dict[str, set[str]]
    forbidden_patterns: dict[str, Any]
    concurrency_escape_patterns: dict[str, Any]
    concurrency_audit_roots: tuple[Path, ...]
    file_name_pattern: Any
    maximum_file_lines: int
    maximum_function_lines: int
    maximum_complexity: int
    maximum_module_file_count: int
    maximum_module_source_share: float
    project_imports: Callable[[str], set[str]]
    swift_function_metrics: Callable[[str, str], list[dict[str, object]]]
    file_set_digest: Callable[[list[Path]], str]
    has_cycle: Callable[[dict[str, set[str]]], list[str] | None]
    workspace_tree: Callable[[], tuple[str, bool]]
    command_output: Callable[..., str]


def load_json_registry(
    root: Path, path: Path, identity_key: str, identity: str
) -> dict[str, object]:
    if not path.is_file():
        return {"error": f"missing registry: {path.relative_to(root)}"}
    try:
        document = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        return {"error": f"invalid registry {path.relative_to(root)}: {error}"}
    if document.get("schemaVersion") != 1 or document.get(identity_key) != identity:
        return {"error": f"invalid registry identity: {path.relative_to(root)}"}
    return document


def index_registry_entries(
    document: dict[str, object], collection: str, key_fields: tuple[str, ...]
) -> dict[object, dict[str, object]]:
    indexed: dict[object, dict[str, object]] = {}
    for candidate in document.get(collection, []):
        if not isinstance(candidate, dict):
            continue
        values = tuple(candidate.get(field) for field in key_fields)
        if not all(isinstance(value, str) and value for value in values):
            continue
        key: object = values[0] if len(values) == 1 else values
        indexed[key] = candidate
    return indexed


def _required_tokens(
    entry: dict[str, object], relative: str, violations: list[dict[str, object]]
) -> list[str]:
    tokens = entry.get("requiredTokens", [])
    if isinstance(tokens, list) and all(
        isinstance(token, str) and token for token in tokens
    ):
        return tokens
    violations.append({"kind": "invalid-audit-tokens", "file": relative})
    return []


def _validate_evidence_paths(
    root: Path,
    entry: dict[str, object],
    relative: str,
    violations: list[dict[str, object]],
) -> None:
    evidence = entry.get("evidence")
    if not isinstance(evidence, list) or not evidence:
        violations.append({"kind": "audit-evidence-missing", "file": relative})
        return
    for evidence_path in evidence:
        if isinstance(evidence_path, str) and (root / evidence_path).exists():
            continue
        violations.append(
            {
                "kind": "audit-evidence-path-missing",
                "file": relative,
                "evidence": evidence_path,
            }
        )


def validate_registry_entry(
    root: Path,
    entry: dict[str, object],
    *,
    relative: str,
    violations: list[dict[str, object]],
) -> None:
    reason = entry.get("reason")
    if not isinstance(reason, str) or len(reason) < 80:
        violations.append({"kind": "incomplete-audit-reason", "file": relative})
    tokens = _required_tokens(entry, relative, violations)
    path = root / relative
    if not path.is_file():
        violations.append({"kind": "audited-path-missing", "file": relative})
        return
    text = path.read_text()
    for token in tokens:
        if token not in text:
            violations.append(
                {"kind": "audit-token-missing", "file": relative, "token": token}
            )
    _validate_evidence_paths(root, entry, relative, violations)


def load_audit_configuration(
    context: StructuralAuditContext, violations: list[dict[str, object]]
) -> tuple[
    dict[str, dict[str, object]],
    dict[tuple[str, str], dict[str, object]],
    dict[str, dict[str, object]],
    dict[str, dict[str, object]],
]:
    root = context.root
    unchecked_document = load_json_registry(
        root,
        root / "docs/research/unchecked-sendable-allowlist.json",
        "allowlistID",
        "FOVEA-UNCHECKED-SENDABLE-ALLOWLIST-V1",
    )
    concurrency_document = load_json_registry(
        root,
        root / "docs/research/concurrency-escape-allowlist.json",
        "allowlistID",
        "FOVEA-CONCURRENCY-ESCAPE-ALLOWLIST-V1",
    )
    cohesion_document = load_json_registry(
        root,
        root / "docs/research/production-cohesion-reviews.json",
        "reviewID",
        "FOVEA-PRODUCTION-COHESION-REVIEWS-V1",
    )
    for document in (unchecked_document, concurrency_document, cohesion_document):
        if "error" in document:
            violations.append(
                {"kind": "invalid-audit-registry", "detail": document["error"]}
            )
    unchecked_entries = index_registry_entries(
        unchecked_document, "entries", ("path",)
    )
    concurrency_entries = index_registry_entries(
        concurrency_document, "entries", ("path", "kind")
    )
    cohesion_entries = index_registry_entries(
        cohesion_document, "entries", ("path",)
    )
    module_reviews = index_registry_entries(
        cohesion_document, "modules", ("module",)
    )
    for relative, entry in unchecked_entries.items():
        validate_registry_entry(root, entry, relative=str(relative), violations=violations)
    for key, entry in concurrency_entries.items():
        validate_registry_entry(root, entry, relative=str(key[0]), violations=violations)
    return unchecked_entries, concurrency_entries, cohesion_entries, module_reviews


def _record_function_limits(
    context: StructuralAuditContext,
    metrics: list[dict[str, object]],
    violations: list[dict[str, object]],
) -> None:
    for metric in metrics:
        if int(metric["lineCount"]) > context.maximum_function_lines:
            violations.append(
                {
                    "kind": "oversized-production-function",
                    **metric,
                    "maximum": context.maximum_function_lines,
                }
            )
        if int(metric["cyclomaticComplexity"]) > context.maximum_complexity:
            violations.append(
                {
                    "kind": "complex-production-function",
                    **metric,
                    "maximum": context.maximum_complexity,
                }
            )


def _record_file_size_review(
    context: StructuralAuditContext,
    path: Path,
    relative: str,
    line_count: int,
    cohesion_entries: dict[str, dict[str, object]],
    violations: list[dict[str, object]],
) -> None:
    if line_count <= context.maximum_file_lines:
        return
    review = cohesion_entries.get(relative)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    valid = (
        review is not None
        and review.get("sha256") == digest
        and review.get("reviewedLineCount") == line_count
    )
    if not valid:
        violations.append(
            {
                "kind": "oversized-production-file",
                "file": relative,
                "actual": line_count,
                "maximum": context.maximum_file_lines,
            }
        )


def _record_forbidden_patterns(
    context: StructuralAuditContext,
    text: str,
    relative: str,
    unchecked_entries: dict[str, dict[str, object]],
    concurrency_entries: dict[tuple[str, str], dict[str, object]],
    observed: set[tuple[str, str]],
    violations: list[dict[str, object]],
) -> None:
    for name, pattern in context.forbidden_patterns.items():
        matches = list(pattern.finditer(text))
        if not matches:
            continue
        audit = unchecked_entries.get(relative) if name == "unchecked-sendable" else None
        audit = audit or concurrency_entries.get((relative, name))
        expected = len(matches) if audit is None else int(audit.get("expectedCount", len(matches)))
        if audit is not None and expected == len(matches):
            observed.add((relative, name))
            continue
        for match in matches:
            violations.append(
                {
                    "kind": name,
                    "file": relative,
                    "line": text.count("\n", 0, match.start()) + 1,
                }
            )


def _analyze_source_file(
    context: StructuralAuditContext,
    path: Path,
    module: str,
    unchecked_entries: dict[str, dict[str, object]],
    concurrency_entries: dict[tuple[str, str], dict[str, object]],
    cohesion_entries: dict[str, dict[str, object]],
    observed: set[tuple[str, str]],
    violations: list[dict[str, object]],
) -> tuple[int, set[str], list[dict[str, object]]]:
    text = path.read_text()
    relative = path.relative_to(context.root).as_posix()
    line_count = len(text.splitlines())
    metrics = context.swift_function_metrics(text, relative)
    if module != "FoveaTesting":
        _record_function_limits(context, metrics, violations)
        _record_file_size_review(
            context, path, relative, line_count, cohesion_entries, violations
        )
    if not context.file_name_pattern.fullmatch(path.name):
        violations.append({"kind": "noncanonical-swift-filename", "file": relative})
    _record_forbidden_patterns(
        context,
        text,
        relative,
        unchecked_entries,
        concurrency_entries,
        observed,
        violations,
    )
    return line_count, context.project_imports(text), metrics


def _analyze_module(
    context: StructuralAuditContext,
    module: str,
    unchecked_entries: dict[str, dict[str, object]],
    concurrency_entries: dict[tuple[str, str], dict[str, object]],
    cohesion_entries: dict[str, dict[str, object]],
    observed: set[tuple[str, str]],
    violations: list[dict[str, object]],
) -> tuple[dict[str, object], set[str], list[dict[str, object]]]:
    files = sorted((context.sources / module).rglob("*.swift"))
    imports: set[str] = set()
    line_count = 0
    maximum_file_lines = 0
    functions: list[dict[str, object]] = []
    for path in files:
        lines, file_imports, file_functions = _analyze_source_file(
            context,
            path,
            module,
            unchecked_entries,
            concurrency_entries,
            cohesion_entries,
            observed,
            violations,
        )
        line_count += lines
        maximum_file_lines = max(maximum_file_lines, lines)
        imports.update(file_imports)
        functions.extend(file_functions)
    summary = {
        "fileCount": len(files),
        "lineCount": line_count,
        "maximumFileLines": maximum_file_lines,
        "functionCount": len(functions),
        "maximumFunctionLines": max(
            (int(item["lineCount"]) for item in functions), default=0
        ),
        "maximumCyclomaticComplexity": max(
            (int(item["cyclomaticComplexity"]) for item in functions), default=0
        ),
        "projectImports": sorted(imports),
    }
    return summary, imports, functions


def audit_modules(
    context: StructuralAuditContext,
    unchecked_entries: dict[str, dict[str, object]],
    concurrency_entries: dict[tuple[str, str], dict[str, object]],
    cohesion_entries: dict[str, dict[str, object]],
    violations: list[dict[str, object]],
) -> tuple[
    dict[str, dict[str, object]],
    dict[str, set[str]],
    list[dict[str, object]],
    set[tuple[str, str]],
]:
    modules: dict[str, dict[str, object]] = {}
    graph: dict[str, set[str]] = {}
    functions: list[dict[str, object]] = []
    observed: set[tuple[str, str]] = set()
    for module in sorted(context.project_modules):
        summary, imports, module_functions = _analyze_module(
            context,
            module,
            unchecked_entries,
            concurrency_entries,
            cohesion_entries,
            observed,
            violations,
        )
        graph[module] = imports
        allowed = context.allowed_project_imports.get(module)
        if allowed is None:
            violations.append({"kind": "module-missing-from-policy", "module": module})
            allowed = set()
        for dependency in sorted(imports - allowed):
            violations.append(
                {
                    "kind": "forbidden-project-import",
                    "module": module,
                    "dependency": dependency,
                }
            )
        modules[module] = summary
        if module != "FoveaTesting":
            functions.extend(module_functions)
    return modules, graph, functions, observed


def _module_review_is_valid(
    context: StructuralAuditContext,
    module: str,
    source_share: float,
    review: dict[str, object] | None,
) -> bool:
    module_files = sorted((context.sources / module).rglob("*.swift"))
    return bool(
        review is not None
        and review.get("reviewedFileCount") == len(module_files)
        and review.get("fileSetSha256") == context.file_set_digest(module_files)
        and source_share <= float(review.get("maximumReviewedSourceShare", 0.0))
    )


def _record_module_limit_violations(
    context: StructuralAuditContext,
    module: str,
    summary: dict[str, object],
    source_share: float,
    violations: list[dict[str, object]],
) -> None:
    if int(summary["fileCount"]) > context.maximum_module_file_count:
        violations.append(
            {
                "kind": "oversized-production-module-file-count",
                "module": module,
                "actual": summary["fileCount"],
                "maximum": context.maximum_module_file_count,
            }
        )
    if source_share > context.maximum_module_source_share:
        violations.append(
            {
                "kind": "oversized-production-module-source-share",
                "module": module,
                "actual": source_share,
                "maximum": context.maximum_module_source_share,
            }
        )


def audit_module_sizes(
    context: StructuralAuditContext,
    modules: dict[str, dict[str, object]],
    module_reviews: dict[str, dict[str, object]],
    violations: list[dict[str, object]],
) -> None:
    total_lines = sum(int(item["lineCount"]) for item in modules.values())
    for module, summary in modules.items():
        source_share = 0.0 if total_lines == 0 else int(summary["lineCount"]) / total_lines
        summary["sourceShare"] = source_share
        oversized = module != "FoveaTesting" and (
            int(summary["fileCount"]) > context.maximum_module_file_count
            or source_share > context.maximum_module_source_share
        )
        if not oversized:
            continue
        if _module_review_is_valid(
            context, module, source_share, module_reviews.get(module)
        ):
            continue
        _record_module_limit_violations(
            context, module, summary, source_share, violations
        )


def _audit_concurrency_file(
    context: StructuralAuditContext,
    path: Path,
    concurrency_entries: dict[tuple[str, str], dict[str, object]],
    observed: set[tuple[str, str]],
    exceptions: list[dict[str, object]],
    violations: list[dict[str, object]],
) -> None:
    text = path.read_text()
    relative = path.relative_to(context.root).as_posix()
    for name, pattern in context.concurrency_escape_patterns.items():
        matches = list(pattern.finditer(text))
        if not matches:
            continue
        key = (relative, name)
        entry = concurrency_entries.get(key)
        expected = None if entry is None else entry.get("expectedCount")
        if expected == len(matches):
            observed.add(key)
            exceptions.append({"kind": name, "file": relative, "count": len(matches)})
            continue
        for match in matches:
            violations.append(
                {
                    "kind": f"non-production-{name}",
                    "file": relative,
                    "line": text.count("\n", 0, match.start()) + 1,
                }
            )


def audit_nonproduction_concurrency(
    context: StructuralAuditContext,
    concurrency_entries: dict[tuple[str, str], dict[str, object]],
    unchecked_entries: dict[str, dict[str, object]],
    observed: set[tuple[str, str]],
    violations: list[dict[str, object]],
) -> tuple[int, list[dict[str, object]]]:
    file_count = 0
    exceptions: list[dict[str, object]] = []
    for audit_root in context.concurrency_audit_roots:
        for path in sorted(audit_root.rglob("*.swift")):
            file_count += 1
            _audit_concurrency_file(
                context,
                path,
                concurrency_entries,
                observed,
                exceptions,
                violations,
            )
    audited_keys = set(concurrency_entries)
    unchecked_keys = {(relative, "unchecked-sendable") for relative in unchecked_entries}
    for relative, name in sorted((audited_keys | unchecked_keys) - observed):
        violations.append(
            {
                "kind": "stale-concurrency-exception",
                "file": relative,
                "pattern": name,
            }
        )
    return file_count, exceptions


def write_structural_report(
    *,
    context: StructuralAuditContext,
    artifact: Path,
    all_functions: list[dict[str, object]],
    audited_concurrency_files: int,
    audited_concurrency_exceptions: list[dict[str, object]],
    modules: dict[str, dict[str, object]],
    violations: list[dict[str, object]],
) -> int:
    tree, dirty = context.workspace_tree()
    report = {
        "schemaVersion": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "verifiedCommit": context.command_output(["git", "rev-parse", "HEAD"]),
        "verifiedTree": tree,
        "includesWorkingTreeChanges": dirty,
        "maximumProductionFileLines": context.maximum_file_lines,
        "maximumProductionFunctionLines": context.maximum_function_lines,
        "maximumProductionCyclomaticComplexity": context.maximum_complexity,
        "maximumModuleFileCount": context.maximum_module_file_count,
        "maximumModuleSourceShare": context.maximum_module_source_share,
        "largestFunctionsByLines": sorted(
            all_functions,
            key=lambda item: (
                int(item["lineCount"]),
                int(item["cyclomaticComplexity"]),
            ),
            reverse=True,
        )[:20],
        "mostComplexFunctions": sorted(
            all_functions,
            key=lambda item: (
                int(item["cyclomaticComplexity"]),
                int(item["lineCount"]),
            ),
            reverse=True,
        )[:20],
        "auditedConcurrencyFiles": audited_concurrency_files,
        "auditedConcurrencyExceptions": audited_concurrency_exceptions,
        "modules": modules,
        "status": "passed" if not violations else "failed",
        "violations": violations,
    }
    artifact.parent.mkdir(parents=True, exist_ok=True)
    artifact.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    if violations:
        print("Structural quality check failed:")
        for violation in violations:
            print(json.dumps(violation, sort_keys=True))
        return 1
    source_files = sum(int(item["fileCount"]) for item in modules.values())
    print(f"Structural quality passed: {len(modules)} modules, {source_files} source files")
    print(f"Artifact: {artifact.relative_to(context.root)}")
    return 0
