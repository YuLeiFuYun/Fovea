#!/usr/bin/env python3
"""有限穷举已验证编码 handoff 的预算、身份、过期与撤销不变量。"""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from typing import Callable, NamedTuple

CAPACITY = 3
MAX_DEPTH = 5
NAMESPACES = (0, 1)
GENERATIONS = (0, 1)
EXECUTIONS = (0, 1)
SIZES = (1, 2, 4)


class Key(NamedTuple):
    namespace: int
    generation: int
    execution: int


@dataclass(frozen=True)
class Entry:
    key: Key
    size: int
    expires_at: int


@dataclass(frozen=True)
class State:
    entries: tuple[Entry, ...] = ()
    now: int = 0


@dataclass(frozen=True)
class Candidate:
    key: Key
    size: int
    public: bool
    credentialed: bool
    automatic: bool
    no_store: bool
    ttl: int


@dataclass(frozen=True)
class Action:
    name: str
    candidate: Candidate | None = None
    key: Key | None = None
    namespace: int | None = None
    generation: int | None = None


@dataclass(frozen=True)
class Rules:
    ignore_execution_on_lookup: bool = False
    ignore_generation_on_lookup: bool = False
    admit_no_store: bool = False
    skip_capacity_eviction: bool = False
    revoke_does_not_clear: bool = False


def total_cost(state: State) -> int:
    return sum(entry.size for entry in state.entries)


def admissible(candidate: Candidate, rules: Rules) -> bool:
    return (
        candidate.public
        and not candidate.credentialed
        and candidate.automatic
        and (not candidate.no_store or rules.admit_no_store)
        and candidate.ttl > 0
    )


def canonicalize(entries: list[Entry]) -> tuple[Entry, ...]:
    return tuple(sorted(entries, key=lambda item: (item.key, item.expires_at, item.size)))


def insert(state: State, candidate: Candidate, rules: Rules) -> State:
    if not admissible(candidate, rules) or candidate.size > CAPACITY:
        return state
    entries = [entry for entry in state.entries if entry.key != candidate.key]
    if not rules.skip_capacity_eviction:
        # 抽象为成本有界缓存：按规范键顺序淘汰，具体 SIEVE victim 由独立差分测试覆盖。
        entries.sort(key=lambda item: (item.expires_at, item.key))
        while sum(item.size for item in entries) + candidate.size > CAPACITY and entries:
            entries.pop(0)
    entries.append(
        Entry(
            key=candidate.key,
            size=candidate.size,
            expires_at=state.now + candidate.ttl,
        )
    )
    return State(canonicalize(entries), state.now)


def lookup(state: State, key: Key, rules: Rules) -> Entry | None:
    for entry in state.entries:
        if entry.expires_at <= state.now:
            continue
        if entry.key.namespace != key.namespace:
            continue
        if not rules.ignore_generation_on_lookup and entry.key.generation != key.generation:
            continue
        if not rules.ignore_execution_on_lookup and entry.key.execution != key.execution:
            continue
        return entry
    return None


def step(state: State, action: Action, rules: Rules) -> State:
    if action.name == "insert":
        assert action.candidate is not None
        return insert(state, action.candidate, rules)
    if action.name == "tick":
        return State(state.entries, state.now + 1)
    if action.name == "purge":
        return State((), state.now)
    if action.name == "revoke":
        assert action.namespace is not None and action.generation is not None
        if rules.revoke_does_not_clear:
            return state
        entries = tuple(
            entry
            for entry in state.entries
            if not (
                entry.key.namespace == action.namespace
                and entry.key.generation <= action.generation
            )
        )
        return State(entries, state.now)
    if action.name == "lookup":
        return state
    raise AssertionError(action.name)


def actions() -> tuple[Action, ...]:
    values: list[Action] = [Action("tick"), Action("purge")]
    for namespace in NAMESPACES:
        for generation in GENERATIONS:
            values.append(Action("revoke", namespace=namespace, generation=generation))
            for execution in EXECUTIONS:
                key = Key(namespace, generation, execution)
                values.append(Action("lookup", key=key))
                for size in SIZES:
                    values.extend(
                        [
                            Action(
                                "insert",
                                candidate=Candidate(
                                    key=key,
                                    size=size,
                                    public=True,
                                    credentialed=False,
                                    automatic=True,
                                    no_store=False,
                                    ttl=2,
                                ),
                            ),
                            Action(
                                "insert",
                                candidate=Candidate(
                                    key=key,
                                    size=size,
                                    public=False,
                                    credentialed=False,
                                    automatic=True,
                                    no_store=False,
                                    ttl=2,
                                ),
                            ),
                            Action(
                                "insert",
                                candidate=Candidate(
                                    key=key,
                                    size=size,
                                    public=True,
                                    credentialed=True,
                                    automatic=True,
                                    no_store=False,
                                    ttl=2,
                                ),
                            ),
                            Action(
                                "insert",
                                candidate=Candidate(
                                    key=key,
                                    size=size,
                                    public=True,
                                    credentialed=False,
                                    automatic=True,
                                    no_store=True,
                                    ttl=2,
                                ),
                            ),
                        ]
                    )
    return tuple(values)


ACTIONS = actions()


def invariant(state: State, rules: Rules) -> str | None:
    if total_cost(state) > CAPACITY:
        return f"resident cost {total_cost(state)} exceeds capacity {CAPACITY}"
    if len({entry.key for entry in state.entries}) != len(state.entries):
        return "duplicate exact identity"
    for entry in state.entries:
        if entry.size <= 0 or entry.size > CAPACITY:
            return "invalid resident size"
    return None


def action_property(before: State, action: Action, after: State, rules: Rules) -> str | None:
    if action.name == "insert":
        assert action.candidate is not None
        candidate = action.candidate
        present = any(entry.key == candidate.key for entry in after.entries)
        # 审计条件必须来自独立 canonical 规范，不能让 mutant 定义自己的正确性。
        should_admit = admissible(candidate, Rules()) and candidate.size <= CAPACITY
        if not should_admit and present and not any(
            entry.key == candidate.key for entry in before.entries
        ):
            return "ineligible candidate became resident"
    elif action.name == "purge" and after.entries:
        return "purge retained entries"
    elif action.name == "revoke":
        assert action.namespace is not None and action.generation is not None
        if any(
            entry.key.namespace == action.namespace
            and entry.key.generation <= action.generation
            for entry in after.entries
        ):
            return "revoked generation remained resident"
    elif action.name == "lookup":
        assert action.key is not None
        result = lookup(before, action.key, rules)
        if result is not None:
            if result.expires_at <= before.now:
                return "expired entry was returned"
            if result.key.namespace != action.key.namespace:
                return "cross-namespace lookup hit"
            if result.key.generation != action.key.generation:
                return "cross-generation lookup hit"
            if result.key.execution != action.key.execution:
                return "cross-execution lookup hit"
    return None


def find_counterexample(rules: Rules) -> tuple[list[str], str] | None:
    initial = State()
    queue = deque([(initial, [])])
    seen = {(initial, 0)}
    while queue:
        state, trace = queue.popleft()
        if len(trace) >= MAX_DEPTH:
            continue
        for action in ACTIONS:
            after = step(state, action, rules)
            reason = invariant(after, rules) or action_property(state, action, after, rules)
            action_text = describe(action)
            if reason:
                return trace + [action_text], reason
            item = (after, len(trace) + 1)
            if item not in seen:
                seen.add(item)
                queue.append((after, trace + [action_text]))
    return None


def describe(action: Action) -> str:
    if action.candidate is not None:
        candidate = action.candidate
        return (
            f"insert(key={candidate.key},size={candidate.size},public={candidate.public},"
            f"credentialed={candidate.credentialed},automatic={candidate.automatic},"
            f"noStore={candidate.no_store},ttl={candidate.ttl})"
        )
    if action.key is not None:
        return f"lookup(key={action.key})"
    if action.namespace is not None:
        return f"revoke(namespace={action.namespace},generation={action.generation})"
    return action.name


def reachable_count(rules: Rules) -> tuple[int, int]:
    initial = State()
    queue = deque([(initial, 0)])
    seen = {(initial, 0)}
    transitions = 0
    while queue:
        state, depth = queue.popleft()
        if depth >= MAX_DEPTH:
            continue
        for action in ACTIONS:
            transitions += 1
            after = step(state, action, rules)
            if invariant(after, rules) or action_property(state, action, after, rules):
                continue
            item = (after, depth + 1)
            if item not in seen:
                seen.add(item)
                queue.append(item)
    return len(seen), transitions


def main() -> int:
    canonical = Rules()
    counterexample = find_counterexample(canonical)
    if counterexample is not None:
        trace, reason = counterexample
        print(f"canonical failed: {reason}: {' -> '.join(trace)}")
        return 1

    mutants: dict[str, Rules] = {
        "lookup-ignores-execution": Rules(ignore_execution_on_lookup=True),
        "lookup-ignores-generation": Rules(ignore_generation_on_lookup=True),
        "admit-no-store": Rules(admit_no_store=True),
        "skip-capacity-eviction": Rules(skip_capacity_eviction=True),
        "revoke-does-not-clear": Rules(revoke_does_not_clear=True),
    }
    failures: list[str] = []
    for name, rules in mutants.items():
        result = find_counterexample(rules)
        if result is None:
            failures.append(name)
            print(f"mutant survived: {name}")
        else:
            trace, reason = result
            print(f"mutant killed: {name}: {reason}: {' -> '.join(trace)}")

    states, transitions = reachable_count(canonical)
    print(
        "Validated encoded handoff model: "
        f"states={states} transitions={transitions} depth={MAX_DEPTH} "
        f"mutantsKilled={len(mutants) - len(failures)}/{len(mutants)}"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
