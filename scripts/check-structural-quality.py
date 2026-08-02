#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

from structural_quality_support import (
    StructuralAuditContext,
    audit_module_sizes,
    audit_modules,
    audit_nonproduction_concurrency,
    load_audit_configuration,
    write_structural_report,
)

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
CONCURRENCY_AUDIT_ROOTS = (
    ROOT / "Tests",
    ROOT / "Tools",
    ROOT / "Examples",
)
ARTIFACT = ROOT / ".artifacts/structure/structural-quality.json"
MAX_PRODUCTION_FILE_LINES = 500
MAX_PRODUCTION_FUNCTION_LINES = 120
MAX_PRODUCTION_CYCLOMATIC_COMPLEXITY = 20
MAX_MODULE_FILE_COUNT = 40
MAX_MODULE_SOURCE_SHARE = 0.45
PROJECT_MODULES = {
    path.name for path in SOURCES.iterdir() if path.is_dir()
}
EXTERNAL_COMPONENT_MODULES = {
    "AkashicCore", "AkashicDisk", "AkashicMemory",
    "ImageCraftCore", "ImageCraftImageIO",
}
ALLOWED_PROJECT_IMPORTS = {
    "FoveaAppKit": {"FoveaCore", "ImageCraftCore"},
    "FoveaStorage": {"AkashicCore"},
    "FoveaCore": {"AkashicCore", "AkashicMemory", "FoveaHTTP", "FoveaStorage", "ImageCraftCore"},
    "FoveaHTTP": {"AkashicCore", "FoveaStorage"},
    "FoveaObservability": {"FoveaCore"},
    "FoveaPersistence": {"AkashicCore", "AkashicDisk", "FoveaHTTP", "FoveaStorage"},
    "FoveaSwiftUI": {"FoveaCore", "ImageCraftCore"},
    "FoveaSystem": {
        "FoveaCore", "FoveaHTTP", "FoveaPersistence", "ImageCraftCore",
        "ImageCraftImageIO",
    },
    "FoveaTesting": {
        "AkashicCore",
        "AkashicDisk",
        "FoveaCore",
        "FoveaHTTP",
        "FoveaPersistence",
        "FoveaStorage",
        "ImageCraftCore",
        "ImageCraftImageIO",
    },
    "FoveaUIKit": {"FoveaCore", "ImageCraftCore"},
}
FORBIDDEN_PATTERNS = {
    "forced-try": re.compile(r"\btry!\b"),
    "forced-cast": re.compile(r"\bas!\b"),
    "unsafe-nonisolated": re.compile(r"nonisolated\(unsafe\)"),
    "unchecked-sendable": re.compile(r"@unchecked\s+Sendable"),
    "detached-task": re.compile(r"\bTask\.detached\b"),
    "dispatch-semaphore": re.compile(r"\bDispatchSemaphore\b"),
    "shared-url-session": re.compile(r"\bURLSession\.shared\b"),
    "standard-user-defaults": re.compile(r"\bUserDefaults\.standard\b"),
    "fatal-error": re.compile(r"\bfatalError\s*\("),
    "precondition-failure": re.compile(r"\bpreconditionFailure\s*\("),
    "maintenance-marker": re.compile(r"\b(?:TODO|FIXME|HACK)\b"),
}
CONCURRENCY_ESCAPE_PATTERNS = {
    name: FORBIDDEN_PATTERNS[name]
    for name in (
        "unsafe-nonisolated",
        "unchecked-sendable",
        "detached-task",
        "dispatch-semaphore",
    )
}
FILE_NAME = re.compile(r"^[A-Z][A-Za-z0-9+]*\.swift$")
FUNCTION_DECLARATION = re.compile(
    r"^(?:\s*(?:@[\w().,: ]+\s+)*)?"
    r"(?:(?:public|package|internal|private|fileprivate|open|static|class|final|"
    r"nonisolated|isolated|mutating|nonmutating|override|required|convenience|"
    r"distributed|borrowing|consuming)\s+)*"
    r"(?:func|init|deinit|subscript)\b"
)
FUNCTION_DECISION = re.compile(
    r"\b(?:if|guard|for|while|case|catch)\b|&&|\|\||\?\?"
)



def file_set_digest(paths: list[Path]) -> str:
    names = "\n".join(sorted(path.relative_to(ROOT).as_posix() for path in paths))
    return hashlib.sha256(names.encode()).hexdigest()


def command_output(command: list[str], *, env: dict[str, str] | None = None) -> str:
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()


def workspace_tree() -> tuple[str, bool]:
    dirty = bool(command_output(["git", "status", "--porcelain"]))
    with tempfile.TemporaryDirectory(prefix="fovea-structure-index-") as temporary:
        env = os.environ.copy()
        env["GIT_INDEX_FILE"] = str(Path(temporary) / "index")
        command_output(["git", "read-tree", "HEAD"], env=env)
        subprocess.run(
            ["git", "add", "-A", "--", "."],
            cwd=ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        tree = command_output(["git", "write-tree"], env=env)
    return tree, dirty


def project_imports(text: str) -> set[str]:
    imports = set()
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("import "):
            continue
        module = stripped.split()[1].split(".")[0]
        if module in PROJECT_MODULES or module in EXTERNAL_COMPONENT_MODULES:
            imports.add(module)
    return imports


def has_cycle(graph: dict[str, set[str]]) -> list[str] | None:
    visiting: list[str] = []
    visited: set[str] = set()

    def visit(node: str) -> list[str] | None:
        if node in visiting:
            start = visiting.index(node)
            return visiting[start:] + [node]
        if node in visited:
            return None
        visiting.append(node)
        for dependency in sorted(graph.get(node, set())):
            cycle = visit(dependency)
            if cycle:
                return cycle
        visiting.pop()
        visited.add(node)
        return None

    for module in sorted(graph):
        cycle = visit(module)
        if cycle:
            return cycle
    return None


def scrub_swift_source(text: str) -> str:
    output: list[str] = []
    index = 0
    state = "code"
    block_depth = 0
    while index < len(text):
        character = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if state == "code":
            if character == "/" and following == "/":
                output.extend("  ")
                index += 2
                state = "line-comment"
                continue
            if character == "/" and following == "*":
                output.extend("  ")
                index += 2
                state = "block-comment"
                block_depth = 1
                continue
            if text[index : index + 3] == '"""':
                output.extend("   ")
                index += 3
                state = "multiline-string"
                continue
            if character == '"':
                output.append(" ")
                index += 1
                state = "string"
                continue
            output.append(character)
            index += 1
            continue
        if state == "line-comment":
            output.append("\n" if character == "\n" else " ")
            index += 1
            if character == "\n":
                state = "code"
            continue
        if state == "block-comment":
            if character == "/" and following == "*":
                output.extend("  ")
                index += 2
                block_depth += 1
                continue
            if character == "*" and following == "/":
                output.extend("  ")
                index += 2
                block_depth -= 1
                if block_depth == 0:
                    state = "code"
                continue
            output.append("\n" if character == "\n" else " ")
            index += 1
            continue
        if state == "string":
            if character == "\\":
                output.extend("  " if index + 1 < len(text) else " ")
                index += 2
                continue
            output.append("\n" if character == "\n" else " ")
            index += 1
            if character == '"':
                state = "code"
            continue
        if state == "multiline-string":
            if text[index : index + 3] == '"""':
                output.extend("   ")
                index += 3
                state = "code"
                continue
            output.append("\n" if character == "\n" else " ")
            index += 1
    return "".join(output)


def swift_function_metrics(text: str, relative: str) -> list[dict[str, object]]:
    scrubbed = scrub_swift_source(text)
    lines = scrubbed.splitlines()
    metrics: list[dict[str, object]] = []
    pending: dict[str, object] | None = None
    brace_depth = 0
    for line_number, line in enumerate(lines, 1):
        if pending is None and FUNCTION_DECLARATION.search(line):
            pending = {
                "file": relative,
                "startLine": line_number,
                "declaration": line.strip()[:256],
            }
        for character in line:
            if character == "{":
                brace_depth += 1
                if pending is not None and "bodyDepth" not in pending:
                    pending["bodyDepth"] = brace_depth
            elif character == "}":
                if pending is not None and pending.get("bodyDepth") == brace_depth:
                    start_line = int(pending["startLine"])
                    body = "\n".join(lines[start_line - 1 : line_number])
                    decision_count = len(FUNCTION_DECISION.findall(body))
                    metrics.append(
                        {
                            "file": relative,
                            "startLine": start_line,
                            "endLine": line_number,
                            "lineCount": line_number - start_line + 1,
                            "cyclomaticComplexity": decision_count + 1,
                            "declaration": pending["declaration"],
                        }
                    )
                    pending = None
                brace_depth -= 1
    return metrics



def audit_context() -> StructuralAuditContext:
    return StructuralAuditContext(
        root=ROOT,
        sources=SOURCES,
        project_modules=PROJECT_MODULES,
        allowed_project_imports=ALLOWED_PROJECT_IMPORTS,
        forbidden_patterns=FORBIDDEN_PATTERNS,
        concurrency_escape_patterns=CONCURRENCY_ESCAPE_PATTERNS,
        concurrency_audit_roots=CONCURRENCY_AUDIT_ROOTS,
        file_name_pattern=FILE_NAME,
        maximum_file_lines=MAX_PRODUCTION_FILE_LINES,
        maximum_function_lines=MAX_PRODUCTION_FUNCTION_LINES,
        maximum_complexity=MAX_PRODUCTION_CYCLOMATIC_COMPLEXITY,
        maximum_module_file_count=MAX_MODULE_FILE_COUNT,
        maximum_module_source_share=MAX_MODULE_SOURCE_SHARE,
        project_imports=project_imports,
        swift_function_metrics=swift_function_metrics,
        file_set_digest=file_set_digest,
        has_cycle=has_cycle,
        workspace_tree=workspace_tree,
        command_output=command_output,
    )


def main() -> int:
    context = audit_context()
    violations: list[dict[str, object]] = []
    unchecked, concurrency, cohesion, module_reviews = load_audit_configuration(
        context, violations
    )
    modules, graph, functions, observed = audit_modules(
        context, unchecked, concurrency, cohesion, violations
    )
    audit_module_sizes(context, modules, module_reviews, violations)
    cycle = context.has_cycle(graph)
    if cycle:
        violations.append({"kind": "project-import-cycle", "path": cycle})
    audited_files, exceptions = audit_nonproduction_concurrency(
        context, concurrency, unchecked, observed, violations
    )
    return write_structural_report(
        context=context,
        artifact=ARTIFACT,
        all_functions=functions,
        audited_concurrency_files=audited_files,
        audited_concurrency_exceptions=exceptions,
        modules=modules,
        violations=violations,
    )


if __name__ == "__main__":
    raise SystemExit(main())
