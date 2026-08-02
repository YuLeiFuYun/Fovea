#!/usr/bin/env python3
"""有限穷举 transient handoff 的准备、原子发布、驱逐和单调失效。"""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass

KEYS = (0, 1)
VERSIONS = (1, 2)
COST = 2
BUDGET = 2
MAX_DEPTH = 9


@dataclass(frozen=True)
class Prepared:
    operation: int
    key: int
    version: int
    cost: int = COST


@dataclass(frozen=True)
class State:
    invalidated: bool = False
    prepared: tuple[Prepared, ...] = ()
    # index/body pairs are sorted tuples: key, version, cost
    index: tuple[tuple[int, int, int], ...] = ()
    bodies: tuple[tuple[int, int], ...] = ()
    next_operation: int = 0
    invalidation_cutoff: int | None = None


@dataclass(frozen=True)
class Rules:
    skip_prepare_invalidation_check: bool = False
    skip_commit_invalidation_check: bool = False
    index_before_body: bool = False
    skip_evicted_body_delete: bool = False
    skip_invalidated_body_cleanup: bool = False
    torn_same_key_metadata: bool = False


def index_dict(state: State) -> dict[int, tuple[int, int]]:
    return {key: (version, cost) for key, version, cost in state.index}


def body_dict(state: State) -> dict[int, int]:
    return dict(state.bodies)


def canonical_index(values: dict[int, tuple[int, int]]) -> tuple[tuple[int, int, int], ...]:
    return tuple(sorted((key, version, cost) for key, (version, cost) in values.items()))


def canonical_bodies(values: dict[int, int]) -> tuple[tuple[int, int], ...]:
    return tuple(sorted(values.items()))


def prepare(state: State, key: int, version: int, rules: Rules) -> State:
    if state.invalidated and not rules.skip_prepare_invalidation_check:
        return state
    item = Prepared(state.next_operation, key, version)
    return State(
        invalidated=state.invalidated,
        prepared=state.prepared + (item,),
        index=state.index,
        bodies=state.bodies,
        next_operation=state.next_operation + 1,
        invalidation_cutoff=state.invalidation_cutoff,
    )


def commit(state: State, operation: int, rules: Rules) -> State:
    selected = next((item for item in state.prepared if item.operation == operation), None)
    if selected is None:
        return state
    remaining = tuple(item for item in state.prepared if item.operation != operation)
    if state.invalidated and not rules.skip_commit_invalidation_check:
        return State(
            state.invalidated, remaining, state.index, state.bodies,
            state.next_operation, state.invalidation_cutoff
        )

    index = index_dict(state)
    bodies = body_dict(state)
    old = index.get(selected.key)
    if old is not None:
        index.pop(selected.key, None)
        bodies.pop(selected.key, None)

    # Budget is one entry in the finite model. Victim choice is deterministic smallest key.
    while sum(cost for _, cost in index.values()) + selected.cost > BUDGET and index:
        victim = min(index)
        index.pop(victim, None)
        if not rules.skip_evicted_body_delete:
            bodies.pop(victim, None)

    metadata_version = selected.version
    if rules.torn_same_key_metadata and old is not None:
        metadata_version = old[0]

    if rules.index_before_body:
        index[selected.key] = (metadata_version, selected.cost)
        # The intermediate torn state is intentionally made observable as the returned state.
        return State(
            state.invalidated,
            remaining,
            canonical_index(index),
            canonical_bodies(bodies),
            state.next_operation,
            state.invalidation_cutoff,
        )

    bodies[selected.key] = selected.version
    index[selected.key] = (metadata_version, selected.cost)
    return State(
        state.invalidated,
        remaining,
        canonical_index(index),
        canonical_bodies(bodies),
        state.next_operation,
        state.invalidation_cutoff,
    )


def invalidate(state: State, rules: Rules) -> State:
    return State(
        invalidated=True,
        prepared=state.prepared,
        index=(),
        bodies=state.bodies if rules.skip_invalidated_body_cleanup else (),
        next_operation=state.next_operation,
        invalidation_cutoff=(
            state.invalidation_cutoff
            if state.invalidation_cutoff is not None
            else state.next_operation
        ),
    )


def remove(state: State, key: int, rules: Rules) -> State:
    index = index_dict(state)
    bodies = body_dict(state)
    index.pop(key, None)
    if not rules.skip_evicted_body_delete:
        bodies.pop(key, None)
    return State(
        state.invalidated,
        state.prepared,
        canonical_index(index),
        canonical_bodies(bodies),
        state.next_operation,
        state.invalidation_cutoff,
    )


def invariant(state: State) -> str | None:
    index = index_dict(state)
    bodies = body_dict(state)
    if state.invalidated and (index or bodies):
        return "invalidated store retains published state"
    if set(index) != set(bodies):
        return f"index/body key mismatch index={sorted(index)} body={sorted(bodies)}"
    for key, (version, cost) in index.items():
        if bodies[key] != version:
            return f"torn body/metadata for key={key}: body={bodies[key]} metadata={version}"
        if cost <= 0:
            return "nonpositive cost"
    if sum(cost for _, cost in index.values()) > BUDGET:
        return "budget exceeded"
    if state.invalidation_cutoff is not None:
        for item in state.prepared:
            if item.operation >= state.invalidation_cutoff:
                return "new preparation started after invalidation"
    operations = [item.operation for item in state.prepared]
    if len(operations) != len(set(operations)):
        return "duplicate prepared operation"
    return None


def successors(state: State, rules: Rules) -> list[tuple[str, State]]:
    result: list[tuple[str, State]] = [("invalidate", invalidate(state, rules))]
    for key in KEYS:
        result.append((f"remove({key})", remove(state, key, rules)))
        for version in VERSIONS:
            result.append((f"prepare({key},v{version})", prepare(state, key, version, rules)))
    for item in state.prepared:
        result.append((f"commit(op{item.operation})", commit(state, item.operation, rules)))
    return result


def find_counterexample(rules: Rules) -> tuple[list[str], str] | None:
    initial = State()
    queue = deque([(initial, [])])
    seen = {(initial, 0)}
    while queue:
        state, trace = queue.popleft()
        if len(trace) >= MAX_DEPTH:
            continue
        for label, after in successors(state, rules):
            reason = invariant(after)
            if reason:
                return trace + [label], reason
            item = (after, len(trace) + 1)
            if item not in seen:
                seen.add(item)
                queue.append((after, trace + [label]))
    return None


def reachable_count() -> tuple[int, int]:
    initial = State()
    queue = deque([(initial, 0)])
    seen = {(initial, 0)}
    transitions = 0
    while queue:
        state, depth = queue.popleft()
        if depth >= MAX_DEPTH:
            continue
        for _, after in successors(state, Rules()):
            transitions += 1
            if invariant(after):
                continue
            item = (after, depth + 1)
            if item not in seen:
                seen.add(item)
                queue.append(item)
    return len(seen), transitions


def main() -> int:
    canonical_failure = find_counterexample(Rules())
    if canonical_failure:
        trace, reason = canonical_failure
        print(f"canonical failed: {reason}: {' -> '.join(trace)}")
        return 1

    mutants = {
        "prepare-after-invalidation": Rules(skip_prepare_invalidation_check=True),
        "commit-after-invalidation": Rules(skip_commit_invalidation_check=True),
        "index-before-body": Rules(index_before_body=True),
        "eviction-leaks-body": Rules(skip_evicted_body_delete=True),
        "invalidation-leaks-body": Rules(skip_invalidated_body_cleanup=True),
        "same-key-torn-metadata": Rules(torn_same_key_metadata=True),
    }
    survivors: list[str] = []
    for name, rules in mutants.items():
        result = find_counterexample(rules)
        if result is None:
            survivors.append(name)
            print(f"mutant survived: {name}")
        else:
            trace, reason = result
            print(f"mutant killed: {name}: {reason}: {' -> '.join(trace)}")

    states, transitions = reachable_count()
    print(
        "Transient handoff store model: "
        f"states={states} transitions={transitions} depth={MAX_DEPTH} "
        f"mutantsKilled={len(mutants) - len(survivors)}/{len(mutants)}"
    )
    return 1 if survivors else 0


if __name__ == "__main__":
    raise SystemExit(main())
