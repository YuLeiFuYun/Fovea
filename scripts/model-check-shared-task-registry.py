#!/usr/bin/env python3
"""对 single-flight 活跃、orphan handoff 与 cancellation tombstone 做有限模型检查。"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, replace
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / ".artifacts/mathematics/shared-task-registry-model.json"
SUBSCRIBERS = ("a", "b")
MAX_TASK_ID = 3
MAX_LEASE_ID = 6


@dataclass(frozen=True)
class State:
    task_id: int = 0
    subscribers: frozenset[str] = frozenset()
    orphan_lease_id: int = 0
    cancellation_lease_id: int = 0
    next_task_id: int = 1
    next_lease_id: int = 1
    cancelled: frozenset[int] = frozenset()
    completed: frozenset[int] = frozenset()
    stale_event_affected_current: bool = False
    cancelled_with_subscribers: bool = False
    duplicate_restart_during_cancellation_window: bool = False
    cancellation_completion_removed_tombstone: bool = False

    @property
    def has_entry(self) -> bool:
        return self.task_id != 0

    @property
    def is_cancellation_tombstone(self) -> bool:
        return self.cancellation_lease_id != 0


@dataclass(frozen=True)
class Mutation:
    name: str
    completion_checks_task_id: bool = True
    orphan_expiry_checks_lease_id: bool = True
    orphan_expiry_checks_subscribers: bool = True
    join_clears_orphan_lease: bool = True
    subscribe_respects_cancellation_tombstone: bool = True
    completion_preserves_cancellation_tombstone: bool = True
    cancellation_expiry_checks_lease_id: bool = True


CANONICAL = Mutation("canonical")
MUTATIONS = (
    Mutation("completion-ignores-task-id", completion_checks_task_id=False),
    Mutation(
        "orphan-expiry-ignores-lease-id",
        orphan_expiry_checks_lease_id=False,
    ),
    Mutation("join-does-not-clear-orphan-lease", join_clears_orphan_lease=False),
    Mutation(
        "subscribe-restarts-during-cancellation-tombstone",
        subscribe_respects_cancellation_tombstone=False,
    ),
    Mutation(
        "completion-removes-cancellation-tombstone",
        completion_preserves_cancellation_tombstone=False,
    ),
    Mutation(
        "cancellation-expiry-ignores-lease-id",
        cancellation_expiry_checks_lease_id=False,
    ),
)
REDUNDANT_GUARD_PROBE = Mutation(
    "orphan-expiry-ignores-subscribers",
    orphan_expiry_checks_subscribers=False,
)


def subscribe(state: State, subscriber: str, mutation: Mutation) -> State | None:
    if subscriber in state.subscribers:
        return None
    if not state.has_entry:
        if state.next_task_id > MAX_TASK_ID:
            return None
        return replace(
            state,
            task_id=state.next_task_id,
            subscribers=frozenset((subscriber,)),
            orphan_lease_id=0,
            cancellation_lease_id=0,
            next_task_id=state.next_task_id + 1,
        )
    if state.is_cancellation_tombstone:
        if mutation.subscribe_respects_cancellation_tombstone:
            # 真实实现返回同一已取消 Task 的终态，但不把迟到者注册成活跃订阅者。
            return state
        if state.next_task_id > MAX_TASK_ID:
            return None
        return replace(
            state,
            task_id=state.next_task_id,
            subscribers=frozenset((subscriber,)),
            orphan_lease_id=0,
            cancellation_lease_id=0,
            next_task_id=state.next_task_id + 1,
            duplicate_restart_during_cancellation_window=True,
        )
    return replace(
        state,
        subscribers=state.subscribers | frozenset((subscriber,)),
        orphan_lease_id=(
            0 if mutation.join_clears_orphan_lease else state.orphan_lease_id
        ),
    )


def release(
    state: State,
    subscriber: str,
    mode: str,
) -> State | None:
    if subscriber not in state.subscribers or not state.has_entry:
        return None
    remaining = state.subscribers - frozenset((subscriber,))
    if remaining:
        return replace(state, subscribers=remaining)
    if state.next_lease_id > MAX_LEASE_ID:
        return None
    lease_id = state.next_lease_id
    if mode == "detach":
        return replace(
            state,
            subscribers=frozenset(),
            orphan_lease_id=lease_id,
            cancellation_lease_id=0,
            next_lease_id=lease_id + 1,
        )
    if mode == "cancel-tombstone":
        return replace(
            state,
            subscribers=frozenset(),
            orphan_lease_id=0,
            cancellation_lease_id=lease_id,
            next_lease_id=lease_id + 1,
            cancelled=state.cancelled | frozenset((state.task_id,)),
        )
    if mode == "cancel-immediate":
        return replace(
            state,
            task_id=0,
            subscribers=frozenset(),
            orphan_lease_id=0,
            cancellation_lease_id=0,
            cancelled=state.cancelled | frozenset((state.task_id,)),
        )
    raise AssertionError(f"unknown release mode: {mode}")


def complete(state: State, event_task_id: int, mutation: Mutation) -> State | None:
    if event_task_id <= 0 or event_task_id >= state.next_task_id:
        return None
    if not state.has_entry:
        return state
    matches = event_task_id == state.task_id
    if mutation.completion_checks_task_id and not matches:
        return state
    completed = state.completed | frozenset((event_task_id,))
    if matches and state.is_cancellation_tombstone:
        if mutation.completion_preserves_cancellation_tombstone:
            return replace(state, completed=completed)
        return replace(
            state,
            task_id=0,
            subscribers=frozenset(),
            orphan_lease_id=0,
            cancellation_lease_id=0,
            completed=completed,
            cancellation_completion_removed_tombstone=True,
        )
    return replace(
        state,
        task_id=0,
        subscribers=frozenset(),
        orphan_lease_id=0,
        cancellation_lease_id=0,
        completed=completed,
        stale_event_affected_current=state.stale_event_affected_current or not matches,
    )


def expire_orphan_lease(
    state: State,
    event_lease_id: int,
    mutation: Mutation,
) -> State | None:
    if event_lease_id <= 0 or event_lease_id >= state.next_lease_id:
        return None
    if not state.has_entry:
        return state
    lease_matches = event_lease_id == state.orphan_lease_id
    subscribers_empty = not state.subscribers
    if mutation.orphan_expiry_checks_lease_id and not lease_matches:
        return state
    if mutation.orphan_expiry_checks_subscribers and not subscribers_empty:
        return state
    return replace(
        state,
        task_id=0,
        subscribers=frozenset(),
        orphan_lease_id=0,
        cancellation_lease_id=0,
        cancelled=state.cancelled | frozenset((state.task_id,)),
        stale_event_affected_current=state.stale_event_affected_current or not lease_matches,
        cancelled_with_subscribers=(
            state.cancelled_with_subscribers or not subscribers_empty
        ),
    )


def expire_cancellation_lease(
    state: State,
    event_lease_id: int,
    mutation: Mutation,
) -> State | None:
    if event_lease_id <= 0 or event_lease_id >= state.next_lease_id:
        return None
    if not state.has_entry:
        return state
    lease_matches = event_lease_id == state.cancellation_lease_id
    if mutation.cancellation_expiry_checks_lease_id and not lease_matches:
        return state
    if not state.is_cancellation_tombstone:
        return replace(
            state,
            stale_event_affected_current=(
                state.stale_event_affected_current or not lease_matches
            ),
        )
    return replace(
        state,
        task_id=0,
        subscribers=frozenset(),
        orphan_lease_id=0,
        cancellation_lease_id=0,
        stale_event_affected_current=state.stale_event_affected_current or not lease_matches,
    )


def transitions(state: State, mutation: Mutation) -> list[tuple[str, State]]:
    result: list[tuple[str, State]] = []
    for subscriber in SUBSCRIBERS:
        candidate = subscribe(state, subscriber, mutation)
        if candidate is not None:
            result.append((f"subscribe({subscriber})", candidate))
        for mode in ("cancel-immediate", "cancel-tombstone", "detach"):
            candidate = release(state, subscriber, mode)
            if candidate is not None:
                result.append((f"{mode}({subscriber})", candidate))
    for task_id in range(1, state.next_task_id):
        candidate = complete(state, task_id, mutation)
        if candidate is not None:
            result.append((f"complete(task={task_id})", candidate))
    for lease_id in range(1, state.next_lease_id):
        candidate = expire_orphan_lease(state, lease_id, mutation)
        if candidate is not None:
            result.append((f"expire-orphan(lease={lease_id})", candidate))
        candidate = expire_cancellation_lease(state, lease_id, mutation)
        if candidate is not None:
            result.append((f"expire-cancel(lease={lease_id})", candidate))
    return result


def invariant_errors(state: State) -> list[str]:
    errors: list[str] = []
    if not state.has_entry and (
        state.subscribers
        or state.orphan_lease_id != 0
        or state.cancellation_lease_id != 0
    ):
        errors.append("absent-entry-retains-subscriber-or-lease")
    if state.orphan_lease_id and state.cancellation_lease_id:
        errors.append("entry-retains-two-lease-kinds")
    if state.subscribers and (
        state.orphan_lease_id != 0 or state.cancellation_lease_id != 0
    ):
        errors.append("active-subscriber-retains-quiescence-lease")
    if state.has_entry and state.task_id in state.cancelled:
        if not state.is_cancellation_tombstone:
            errors.append("cancelled-task-remains-active-without-tombstone")
        if state.subscribers:
            errors.append("cancelled-tombstone-retains-active-subscribers")
    if state.is_cancellation_tombstone and state.task_id not in state.cancelled:
        errors.append("cancellation-tombstone-task-not-cancelled")
    if state.stale_event_affected_current:
        errors.append("stale-event-affected-current-task")
    if state.cancelled_with_subscribers:
        errors.append("lease-expiry-cancelled-active-subscribers")
    if state.duplicate_restart_during_cancellation_window:
        errors.append("late-subscribe-restarted-operation-during-cancellation-window")
    if state.cancellation_completion_removed_tombstone:
        errors.append("completion-removed-cancellation-tombstone-before-expiry")
    return errors


def explore(mutation: Mutation) -> dict[str, object]:
    initial = State()
    queue: deque[State] = deque((initial,))
    parent: dict[State, tuple[State, str] | None] = {initial: None}
    transitions_seen = 0
    violation: tuple[State, list[str]] | None = None

    while queue:
        state = queue.popleft()
        errors = invariant_errors(state)
        if errors:
            violation = (state, errors)
            break
        for action, target in transitions(state, mutation):
            transitions_seen += 1
            if target not in parent:
                parent[target] = (state, action)
                queue.append(target)

    counterexample: list[str] = []
    errors: list[str] = []
    if violation is not None:
        state, errors = violation
        while parent[state] is not None:
            prior, action = parent[state]  # type: ignore[misc]
            counterexample.append(action)
            state = prior
        counterexample.reverse()

    orphan_liveness = True
    cancellation_liveness = True
    for state in parent:
        if state.has_entry and not state.subscribers and state.orphan_lease_id:
            target = expire_orphan_lease(state, state.orphan_lease_id, mutation)
            if target is None or target.has_entry:
                orphan_liveness = False
                break
        if state.has_entry and state.is_cancellation_tombstone:
            target = expire_cancellation_lease(
                state,
                state.cancellation_lease_id,
                mutation,
            )
            if target is None or target.has_entry:
                cancellation_liveness = False
                break

    return {
        "mutation": mutation.name,
        "statesExplored": len(parent),
        "transitionsExplored": transitions_seen,
        "invariantsPassed": violation is None,
        "orphanLeaseExpiryConverges": orphan_liveness,
        "cancellationLeaseExpiryConverges": cancellation_liveness,
        "errors": errors,
        "shortestCounterexample": counterexample,
    }


def main() -> int:
    canonical = explore(CANONICAL)
    mutants = [explore(mutation) for mutation in MUTATIONS]
    redundant_guard_probe = explore(REDUNDANT_GUARD_PROBE)
    source = ROOT / "Sources/FoveaCore/SharedTaskRegistry.swift"
    report = {
        "schemaVersion": 2,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "finiteDomain": {
            "keys": 1,
            "subscribers": list(SUBSCRIBERS),
            "maximumTaskIDs": MAX_TASK_ID,
            "maximumLeaseIDs": MAX_LEASE_ID,
            "states": ["absent", "active", "orphan-handoff", "cancellation-tombstone"],
            "events": [
                "subscribe",
                "cancel-immediate",
                "cancel-with-tombstone",
                "detach",
                "complete-current-or-stale",
                "expire-current-or-stale-orphan-lease",
                "expire-current-or-stale-cancellation-lease",
            ],
        },
        "canonical": canonical,
        "mutants": mutants,
        "redundantGuardProbe": {
            **redundant_guard_probe,
            "interpretation": (
                "在 join 原子清除 orphan lease 的不变量下，仅删除 subscriber-empty "
                "检查不会生成可达反例；该检查属于防御性冗余，而非最小正确性条件。"
            ),
        },
        "minimalSafetyCutSet": [
            "completion checks taskID",
            "orphan lease expiry checks leaseID",
            "join clears orphan lease",
            "subscribe does not restart through cancellation tombstone",
            "completion preserves cancellation tombstone until lease expiry",
            "cancellation tombstone expiry checks leaseID",
        ],
        "claimBoundary": (
            "该模型完整枚举声明的单键、双订阅者、有限 task/lease ID 空间；"
            "它证明 active、orphan handoff 与 cancellation tombstone 的版本戳和"
            "不可复活不变量能杀死声明的最小 mutant，但不证明 Swift actor 调度器、"
            "Task 运行时、墙钟租约精度或无限键空间的完整线性化与活性。"
        ),
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    killed = sum(not mutant["invariantsPassed"] for mutant in mutants)
    passed = (
        canonical["invariantsPassed"]
        and canonical["orphanLeaseExpiryConverges"]
        and canonical["cancellationLeaseExpiryConverges"]
        and killed == len(mutants)
        and redundant_guard_probe["invariantsPassed"]
    )
    print(
        "Shared task model: "
        f"states={canonical['statesExplored']} transitions={canonical['transitionsExplored']} "
        f"mutantsKilled={killed}/{len(mutants)}"
    )
    for mutant in mutants:
        print(
            f"  {mutant['mutation']}: "
            f"counterexample={mutant['shortestCounterexample']}"
        )
    print(f"Artifact: {OUTPUT.relative_to(ROOT)}")
    if not passed:
        print("error: shared-task 有限模型未满足预期", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
