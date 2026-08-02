#!/usr/bin/env python3
"""穷举有限缓存事务模型，并验证安全不变量与检查器灵敏度。"""

from __future__ import annotations

from collections import deque
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import argparse
import json
from pathlib import Path
from typing import Callable, Iterable

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / ".artifacts/mathematics/cache-state-model.json"
CONTENTS = ("a", "b")
MAX_GENERATION = 2
MAX_DEPTH = 10
Record = tuple[str, int]


@dataclass(frozen=True)
class State:
    generation: int
    records: frozenset[Record]
    blobs: frozenset[str]
    rendered: frozenset[Record]
    transaction_phase: str = "idle"
    snapshot: Record | None = None
    candidate: Record | None = None


@dataclass(frozen=True)
class Edge:
    action: str
    state: State


@dataclass(frozen=True)
class Counterexample:
    reason: str
    trace: tuple[str, ...]
    state: State


TransitionSystem = Callable[[State], Iterable[Edge]]


def visible_records(state: State) -> frozenset[Record]:
    return frozenset(record for record in state.records if record[1] == state.generation)


def referenced_contents(state: State) -> frozenset[str]:
    references = set(state.records | state.rendered)
    if state.snapshot is not None:
        references.add(state.snapshot)
    if state.candidate is not None and state.transaction_phase == "published":
        references.add(state.candidate)
    return frozenset(content for content, _ in references)


def replace_record_for_generation(
    records: frozenset[Record],
    record: Record,
) -> frozenset[Record]:
    return frozenset(item for item in records if item[1] != record[1]) | {record}


def canonical_transitions(state: State) -> Iterable[Edge]:
    if state.transaction_phase == "idle":
        for content in CONTENTS:
            record = (content, state.generation)
            records = replace_record_for_generation(state.records, record)
            yield Edge(
                f"network-200:{content}",
                State(
                    state.generation,
                    records,
                    state.blobs | {content},
                    state.rendered,
                ),
            )
            yield Edge(f"network-no-store:{content}", state)

        current = sorted(visible_records(state))
        if len(current) == 1:
            snapshot = current[0]
            for content in CONTENTS:
                if content != snapshot[0]:
                    yield Edge(
                        f"begin-replacement:{content}",
                        State(
                            state.generation,
                            state.records,
                            state.blobs,
                            state.rendered,
                            "begun",
                            snapshot,
                            (content, state.generation),
                        ),
                    )
            yield Edge(
                "publish-rendered",
                State(
                    state.generation,
                    state.records,
                    state.blobs,
                    state.rendered | {snapshot},
                ),
            )
    elif state.transaction_phase == "begun":
        assert state.candidate is not None
        yield Edge(
            "publish-candidate",
            State(
                state.generation,
                replace_record_for_generation(state.records, state.candidate),
                state.blobs | {state.candidate[0]},
                state.rendered,
                "published",
                state.snapshot,
                state.candidate,
            ),
        )
        yield Edge(
            "cancel-before-publication",
            State(state.generation, state.records, state.blobs, state.rendered),
        )
    elif state.transaction_phase == "published":
        assert state.candidate is not None
        assert state.snapshot is not None
        if state.candidate[1] == state.generation:
            yield Edge(
                "commit-replacement",
                State(state.generation, state.records, state.blobs, state.rendered),
            )
        if state.snapshot[1] == state.generation:
            restored = replace_record_for_generation(state.records, state.snapshot)
            candidate_content = state.candidate[0]
            remaining_blobs = state.blobs
            if candidate_content not in referenced_contents(
                State(state.generation, restored, state.blobs, state.rendered)
            ):
                remaining_blobs = frozenset(
                    content for content in state.blobs if content != candidate_content
                )
            yield Edge(
                "cancel-published-active-generation",
                State(state.generation, restored, remaining_blobs, state.rendered),
            )
        else:
            records = frozenset(record for record in state.records if record != state.candidate)
            remaining_blobs = state.blobs
            candidate_content = state.candidate[0]
            if candidate_content not in referenced_contents(
                State(state.generation, records, state.blobs, state.rendered)
            ):
                remaining_blobs = frozenset(
                    content for content in state.blobs if content != candidate_content
                )
            yield Edge(
                "cancel-published-revoked-generation",
                State(state.generation, records, remaining_blobs, state.rendered),
            )

    if state.generation < MAX_GENERATION:
        next_generation = state.generation + 1
        yield Edge(
            "revoke-cleanup-succeeds",
            State(
                next_generation,
                frozenset(record for record in state.records if record[1] == next_generation),
                state.blobs,
                frozenset(),
                state.transaction_phase,
                state.snapshot,
                state.candidate,
            ),
        )
        yield Edge(
            "revoke-cleanup-degrades",
            State(
                next_generation,
                state.records,
                state.blobs,
                frozenset(),
                state.transaction_phase,
                state.snapshot,
                state.candidate,
            ),
        )

    if state.rendered:
        yield Edge(
            "purge-rendered",
            State(
                state.generation,
                state.records,
                state.blobs,
                frozenset(),
                state.transaction_phase,
                state.snapshot,
                state.candidate,
            ),
        )

    unreferenced = state.blobs - referenced_contents(state)
    for content in sorted(unreferenced):
        yield Edge(
            f"garbage-collect:{content}",
            State(
                state.generation,
                state.records,
                frozenset(item for item in state.blobs if item != content),
                state.rendered,
                state.transaction_phase,
                state.snapshot,
                state.candidate,
            ),
        )


def state_invariant_errors(state: State) -> list[str]:
    errors: list[str] = []
    if not 0 <= state.generation <= MAX_GENERATION:
        errors.append("当前代际超出有限模型范围")
    if len(visible_records(state)) > 1:
        errors.append("同一变体在当前代际出现多个可见记录")
    for content, _ in state.records:
        if content not in state.blobs:
            errors.append("表征记录引用不存在的编码数据块")
    for content, generation in state.rendered:
        if content not in state.blobs:
            errors.append("渲染内存引用不存在的编码数据块")
        if generation != state.generation:
            errors.append("渲染内存公开了已撤销代际")
    if state.transaction_phase == "idle":
        if state.snapshot is not None or state.candidate is not None:
            errors.append("空闲事务仍保留快照或候选记录")
    else:
        if state.snapshot is None or state.candidate is None:
            errors.append("活动事务缺少快照或候选记录")
    return errors


def edge_obligation_errors(before: State, edge: Edge) -> list[str]:
    after = edge.state
    errors: list[str] = []
    if edge.action.startswith("network-no-store"):
        if (
            before.records != after.records
            or before.blobs != after.blobs
            or before.rendered != after.rendered
        ):
            errors.append("no-store 响应产生了跨请求可复用状态")
    if edge.action.startswith("revoke-"):
        if after.generation != before.generation + 1:
            errors.append("撤销未单调推进命名空间代际")
        if after.rendered:
            errors.append("撤销后仍保留可见渲染内存")
    if edge.action == "cancel-published-active-generation":
        if before.snapshot not in after.records:
            errors.append("活动代际取消覆盖时未恢复旧记录")
        if before.candidate in after.records:
            errors.append("活动代际取消覆盖后候选记录仍可见")
    if edge.action == "cancel-published-revoked-generation":
        if before.snapshot in after.records:
            errors.append("撤销后取消覆盖错误复活旧代际记录")
        if before.candidate in after.records:
            errors.append("撤销后取消覆盖未移除候选记录")
    return errors


def explore(system: TransitionSystem) -> tuple[int, int, Counterexample | None]:
    initial = State(0, frozenset({("a", 0)}), frozenset({"a"}), frozenset())
    queue = deque([(initial, tuple(), 0)])
    visited = {initial}
    edges = 0
    while queue:
        state, trace, depth = queue.popleft()
        errors = state_invariant_errors(state)
        if errors:
            return len(visited), edges, Counterexample(errors[0], trace, state)
        if depth >= MAX_DEPTH:
            continue
        for edge in system(state):
            edges += 1
            edge_errors = edge_obligation_errors(state, edge)
            next_trace = trace + (edge.action,)
            if edge_errors:
                return len(visited), edges, Counterexample(
                    edge_errors[0], next_trace, edge.state
                )
            if edge.state not in visited:
                visited.add(edge.state)
                queue.append((edge.state, next_trace, depth + 1))
    return len(visited), edges, None


def mutate(
    name: str,
    transform: Callable[[State, Edge], Edge],
) -> TransitionSystem:
    def transitions(state: State) -> Iterable[Edge]:
        for edge in canonical_transitions(state):
            yield transform(state, edge)

    transitions.__name__ = name
    return transitions


def mutation_systems() -> dict[str, TransitionSystem]:
    def record_without_blob(_: State, edge: Edge) -> Edge:
        if edge.action == "publish-candidate" and edge.state.candidate is not None:
            content = edge.state.candidate[0]
            return Edge(
                edge.action,
                State(
                    edge.state.generation,
                    edge.state.records,
                    frozenset(item for item in edge.state.blobs if item != content),
                    edge.state.rendered,
                    edge.state.transaction_phase,
                    edge.state.snapshot,
                    edge.state.candidate,
                ),
            )
        return edge

    def no_store_persists(before: State, edge: Edge) -> Edge:
        if edge.action.startswith("network-no-store"):
            content = edge.action.rsplit(":", 1)[1]
            record = (content, before.generation)
            return Edge(
                edge.action,
                State(
                    before.generation,
                    replace_record_for_generation(before.records, record),
                    before.blobs | {content},
                    before.rendered,
                ),
            )
        return edge

    def revoke_without_generation(before: State, edge: Edge) -> Edge:
        if edge.action.startswith("revoke-"):
            return Edge(
                edge.action,
                State(
                    before.generation,
                    edge.state.records,
                    edge.state.blobs,
                    edge.state.rendered,
                    edge.state.transaction_phase,
                    edge.state.snapshot,
                    edge.state.candidate,
                ),
            )
        return edge

    def restore_after_revoke(before: State, edge: Edge) -> Edge:
        if edge.action == "cancel-published-revoked-generation" and before.snapshot is not None:
            return Edge(
                edge.action,
                State(
                    edge.state.generation,
                    edge.state.records | {before.snapshot},
                    edge.state.blobs | {before.snapshot[0]},
                    edge.state.rendered,
                ),
            )
        return edge

    def retain_old_rendered(before: State, edge: Edge) -> Edge:
        if edge.action.startswith("revoke-"):
            return Edge(
                edge.action,
                State(
                    edge.state.generation,
                    edge.state.records,
                    edge.state.blobs,
                    before.rendered,
                    edge.state.transaction_phase,
                    edge.state.snapshot,
                    edge.state.candidate,
                ),
            )
        return edge

    return {
        "record-without-blob": mutate("record-without-blob", record_without_blob),
        "no-store-persists": mutate("no-store-persists", no_store_persists),
        "revoke-without-generation": mutate(
            "revoke-without-generation", revoke_without_generation
        ),
        "restore-after-revoke": mutate("restore-after-revoke", restore_after_revoke),
        "retain-old-rendered": mutate("retain-old-rendered", retain_old_rendered),
    }


def encode_state(state: State) -> dict[str, object]:
    return {
        "generation": state.generation,
        "records": [list(item) for item in sorted(state.records)],
        "blobs": sorted(state.blobs),
        "rendered": [list(item) for item in sorted(state.rendered)],
        "transactionPhase": state.transaction_phase,
        "snapshot": list(state.snapshot) if state.snapshot else None,
        "candidate": list(state.candidate) if state.candidate else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    states, edges, counterexample = explore(canonical_transitions)
    errors: list[str] = []
    if counterexample is not None:
        errors.append(f"规范模型违反不变量：{counterexample.reason}")

    mutations: dict[str, object] = {}
    for name, system in mutation_systems().items():
        mutant_states, mutant_edges, failure = explore(system)
        killed = failure is not None
        if not killed:
            errors.append(f"模型检查器未杀死故障注入：{name}")
        mutations[name] = {
            "killed": killed,
            "visitedStates": mutant_states,
            "exploredEdges": mutant_edges,
            "counterexample": (
                {
                    "reason": failure.reason,
                    "trace": list(failure.trace),
                    "state": encode_state(failure.state),
                }
                if failure
                else None
            ),
        }

    report = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "model": {
            "maximumDepth": MAX_DEPTH,
            "maximumGeneration": MAX_GENERATION,
            "contentDomain": list(CONTENTS),
            "visitedStates": states,
            "exploredEdges": edges,
        },
        "verifiedInvariants": [
            "当前代际每个变体最多一个可见记录",
            "每个表征记录都引用存在的编码数据块",
            "渲染内存不得公开已撤销代际",
            "no-store 不产生跨请求可复用状态",
            "撤销严格推进代际并清除渲染内存",
            "活动代际覆盖取消恢复旧记录",
            "撤销后的覆盖取消不得复活旧代际",
        ],
        "truthBoundary": (
            "这是对有限抽象状态机的穷举验证，不等同于自动证明 Swift 实现与模型双向等价。"
        ),
        "canonicalModelPassed": counterexample is None,
        "mutations": mutations,
        "errors": errors,
    }
    output = args.output if args.output.is_absolute() else ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    killed = sum(bool(item["killed"]) for item in mutations.values())
    print(
        "Cache transaction model: "
        f"states={states} edges={edges} canonicalPassed={counterexample is None} "
        f"mutantsKilled={killed}/{len(mutations)}"
    )
    print(f"Artifact: {output.relative_to(ROOT)}")
    if errors:
        for error in errors:
            print(f"error: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
