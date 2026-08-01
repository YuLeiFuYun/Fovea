#!/usr/bin/env python3
"""用有向图不变量和结构指标审查 SwiftPM 模块架构。"""

from __future__ import annotations

import argparse
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Iterable

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
DEFAULT_OUTPUT = ROOT / ".artifacts/mathematics/architecture.json"
MAX_DIRECT_FAN_OUT = 8
MAX_PRODUCTION_FAN_OUT = 5
TEST_SUPPORT_TARGETS = {"FoveaTesting"}


@dataclass(frozen=True)
class ModuleMetrics:
    name: str
    direct_dependencies: tuple[str, ...]
    direct_dependents: tuple[str, ...]
    transitive_dependencies: tuple[str, ...]
    layer: int
    instability: float
    betweenness: float
    source_files: int
    source_lines: int


def run_dump_package() -> dict:
    completed = subprocess.run(
        ["swift", "package", "dump-package"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(completed.stdout)


def dependency_name(raw: dict) -> str | None:
    for key in ("target", "byName", "product"):
        value = raw.get(key)
        if isinstance(value, list) and value and isinstance(value[0], str):
            return value[0]
    return None


def production_graph(package: dict) -> dict[str, set[str]]:
    modules = {path.name for path in SOURCES.iterdir() if path.is_dir()}
    graph: dict[str, set[str]] = {name: set() for name in modules}
    for target in package.get("targets", []):
        name = target.get("name")
        if name not in modules:
            continue
        for raw_dependency in target.get("dependencies", []):
            dependency = dependency_name(raw_dependency)
            if dependency in modules:
                graph[name].add(dependency)
    return graph


def observed_imports(modules: Iterable[str]) -> dict[str, set[str]]:
    module_set = set(modules)
    imports: dict[str, set[str]] = {name: set() for name in module_set}
    pattern = re.compile(r"^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)\s*$", re.MULTILINE)
    for name in sorted(module_set):
        for path in sorted((SOURCES / name).rglob("*.swift")):
            for imported in pattern.findall(path.read_text()):
                if imported in module_set and imported != name:
                    imports[name].add(imported)
    return imports


def strongly_connected_components(graph: dict[str, set[str]]) -> list[list[str]]:
    index = 0
    indices: dict[str, int] = {}
    lowlinks: dict[str, int] = {}
    stack: list[str] = []
    on_stack: set[str] = set()
    components: list[list[str]] = []

    def visit(node: str) -> None:
        nonlocal index
        indices[node] = index
        lowlinks[node] = index
        index += 1
        stack.append(node)
        on_stack.add(node)

        for neighbor in sorted(graph[node]):
            if neighbor not in indices:
                visit(neighbor)
                lowlinks[node] = min(lowlinks[node], lowlinks[neighbor])
            elif neighbor in on_stack:
                lowlinks[node] = min(lowlinks[node], indices[neighbor])

        if lowlinks[node] == indices[node]:
            component: list[str] = []
            while True:
                member = stack.pop()
                on_stack.remove(member)
                component.append(member)
                if member == node:
                    break
            components.append(sorted(component))

    for node in sorted(graph):
        if node not in indices:
            visit(node)
    return sorted(components)


def topological_order(graph: dict[str, set[str]]) -> list[str]:
    dependents = reverse_graph(graph)
    remaining_dependencies = {node: len(dependencies) for node, dependencies in graph.items()}
    ready = deque(sorted(node for node, count in remaining_dependencies.items() if count == 0))
    order: list[str] = []
    while ready:
        node = ready.popleft()
        order.append(node)
        for dependent in sorted(dependents[node]):
            remaining_dependencies[dependent] -= 1
            if remaining_dependencies[dependent] == 0:
                ready.append(dependent)
    return order


def reverse_graph(graph: dict[str, set[str]]) -> dict[str, set[str]]:
    reverse = {node: set() for node in graph}
    for source, dependencies in graph.items():
        for target in dependencies:
            reverse[target].add(source)
    return reverse


def transitive_dependencies(graph: dict[str, set[str]], start: str) -> set[str]:
    result: set[str] = set()
    stack = list(graph[start])
    while stack:
        node = stack.pop()
        if node in result:
            continue
        result.add(node)
        stack.extend(graph[node] - result)
    return result


def layers(graph: dict[str, set[str]], order: list[str]) -> dict[str, int]:
    result: dict[str, int] = {}
    for node in order:
        dependencies = graph[node]
        result[node] = 0 if not dependencies else 1 + max(result[item] for item in dependencies)
    return result


def brandes_betweenness(graph: dict[str, set[str]]) -> dict[str, float]:
    """计算有向无权图的 Brandes 节点介数中心性。"""
    nodes = sorted(graph)
    scores = {node: 0.0 for node in nodes}
    for source in nodes:
        stack: list[str] = []
        predecessors = {node: [] for node in nodes}
        paths = {node: 0.0 for node in nodes}
        distance = {node: -1 for node in nodes}
        paths[source] = 1.0
        distance[source] = 0
        queue = deque([source])
        while queue:
            vertex = queue.popleft()
            stack.append(vertex)
            for neighbor in graph[vertex]:
                if distance[neighbor] < 0:
                    queue.append(neighbor)
                    distance[neighbor] = distance[vertex] + 1
                if distance[neighbor] == distance[vertex] + 1:
                    paths[neighbor] += paths[vertex]
                    predecessors[neighbor].append(vertex)
        dependency = {node: 0.0 for node in nodes}
        while stack:
            target = stack.pop()
            for predecessor in predecessors[target]:
                if paths[target] > 0:
                    dependency[predecessor] += (
                        paths[predecessor] / paths[target]
                    ) * (1.0 + dependency[target])
            if target != source:
                scores[target] += dependency[target]
    denominator = max(1, (len(nodes) - 1) * (len(nodes) - 2))
    return {node: scores[node] / denominator for node in nodes}


def source_size(module: str) -> tuple[int, int]:
    files = sorted((SOURCES / module).rglob("*.swift"))
    lines = sum(len(path.read_text().splitlines()) for path in files)
    return len(files), lines


def tree_digest(paths: Iterable[Path]) -> str:
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(str(path.relative_to(ROOT)).encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    package = run_dump_package()
    graph = production_graph(package)
    observed = observed_imports(graph)
    reverse = reverse_graph(graph)
    components = strongly_connected_components(graph)
    cycles = [component for component in components if len(component) > 1]
    self_cycles = sorted(node for node, dependencies in graph.items() if node in dependencies)
    order = topological_order(graph) if not cycles and not self_cycles else []

    errors: list[str] = []
    if cycles or self_cycles:
        errors.append(f"模块依赖图存在环：components={cycles}, self={self_cycles}")

    undeclared_imports: dict[str, list[str]] = {}
    unused_declarations: dict[str, list[str]] = {}
    for module in sorted(graph):
        missing = sorted(observed[module] - graph[module])
        unused = sorted(graph[module] - observed[module])
        if missing:
            undeclared_imports[module] = missing
        if unused:
            unused_declarations[module] = unused
    if undeclared_imports:
        errors.append(f"源码存在未声明模块依赖：{undeclared_imports}")

    fanout_violations: dict[str, int] = {}
    for module, dependencies in sorted(graph.items()):
        bound = MAX_DIRECT_FAN_OUT if module in TEST_SUPPORT_TARGETS else MAX_PRODUCTION_FAN_OUT
        if len(dependencies) > bound:
            fanout_violations[module] = len(dependencies)
    if fanout_violations:
        errors.append(f"模块直接扇出超过审查上限：{fanout_violations}")

    module_layers = layers(graph, order) if order else {module: -1 for module in graph}
    centrality = brandes_betweenness(graph)
    instability = {
        module: (
            len(graph[module]) / (len(graph[module]) + len(reverse[module]))
            if graph[module] or reverse[module]
            else 0.0
        )
        for module in graph
    }

    stable_dependency_violations: list[dict[str, object]] = []
    for source, dependencies in sorted(graph.items()):
        for target in sorted(dependencies):
            if instability[source] + 1e-12 < instability[target]:
                stable_dependency_violations.append(
                    {
                        "source": source,
                        "target": target,
                        "sourceInstability": round(instability[source], 6),
                        "targetInstability": round(instability[target], 6),
                    }
                )

    metrics: list[ModuleMetrics] = []
    for module in sorted(graph):
        file_count, line_count = source_size(module)
        metrics.append(
            ModuleMetrics(
                name=module,
                direct_dependencies=tuple(sorted(graph[module])),
                direct_dependents=tuple(sorted(reverse[module])),
                transitive_dependencies=tuple(sorted(transitive_dependencies(graph, module))),
                layer=module_layers[module],
                instability=instability[module],
                betweenness=centrality[module],
                source_files=file_count,
                source_lines=line_count,
            )
        )

    total_edges = sum(len(items) for items in graph.values())
    incoming_total = max(1, total_edges)
    dependency_hhi = sum((len(reverse[node]) / incoming_total) ** 2 for node in graph)
    articulation_candidates = sorted(
        metric.name
        for metric in metrics
        if metric.betweenness > 0.0 and len(metric.direct_dependents) >= 2
    )

    report = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "sourceTreeSHA256": tree_digest(
            [ROOT / "Package.swift", *SOURCES.rglob("*.swift")]
        ),
        "invariants": {
            "acyclic": not cycles and not self_cycles,
            "declaredDependenciesCoverImports": not undeclared_imports,
            "directFanOutBounded": not fanout_violations,
        },
        "graph": {
            "moduleCount": len(graph),
            "edgeCount": total_edges,
            "longestLayer": max(module_layers.values(), default=0),
            "dependencyConcentrationHHI": round(dependency_hhi, 6),
            "topologicalOrder": order,
            "stronglyConnectedComponents": components,
            "articulationCandidates": articulation_candidates,
        },
        "reviewObligations": {
            "stableDependencyDirection": stable_dependency_violations,
            "declaredButCurrentlyUnimported": unused_declarations,
        },
        "modules": [
            {
                "name": item.name,
                "directDependencies": list(item.direct_dependencies),
                "directDependents": list(item.direct_dependents),
                "transitiveDependencies": list(item.transitive_dependencies),
                "layer": item.layer,
                "instability": round(item.instability, 6),
                "betweennessCentrality": round(item.betweenness, 6),
                "sourceFiles": item.source_files,
                "sourceLines": item.source_lines,
            }
            for item in metrics
        ],
        "errors": errors,
    }

    output = args.output if args.output.is_absolute() else ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    print(
        "Mathematical architecture analysis: "
        f"modules={len(graph)} edges={total_edges} cycles={len(cycles) + len(self_cycles)} "
        f"hiddenDependencies={sum(len(v) for v in undeclared_imports.values())} "
        f"fanoutViolations={len(fanout_violations)}"
    )
    print(f"Artifact: {output.relative_to(ROOT)}")
    if stable_dependency_violations:
        print(
            "Review obligations: stable-dependency-direction="
            f"{len(stable_dependency_violations)}"
        )
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
