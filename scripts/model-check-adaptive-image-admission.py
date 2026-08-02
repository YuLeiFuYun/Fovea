#!/usr/bin/env python3
"""有限穷举连续取消识别、经验最大周期稳定门与 fetch handoff 状态机。"""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass

RETENTION = 4
STATE_LIMIT = 2
MAX_DEPTH = 10
KEYS = (0, 1, 2)


@dataclass(frozen=True)
class KeyState:
    previous: int | None = None
    latest: int | None = None
    maximum_period: int | None = None
    touched: int = 0


@dataclass(frozen=True)
class State:
    now: int = 0
    entries: tuple[tuple[int, KeyState], ...] = ()


@dataclass(frozen=True)
class Admission:
    preserves_fetch: bool
    stabilization: int


@dataclass(frozen=True)
class CancellationObservation:
    should_warm: bool
    period: int | None


@dataclass(frozen=True)
class Rules:
    enable_after_one: bool = False
    zero_stabilization: bool = False
    non_strict_stabilization: bool = False
    latest_period_only: bool = False
    remaining_period_wait: bool = False
    cross_key_state: bool = False
    skip_expiration: bool = False
    skip_state_trim: bool = False


def as_dict(state: State) -> dict[int, KeyState]:
    return dict(state.entries)


def canonical(entries: dict[int, KeyState]) -> tuple[tuple[int, KeyState], ...]:
    return tuple(sorted(entries.items()))


def normalized(value: KeyState | None, now: int, rules: Rules) -> KeyState:
    if value is None:
        return KeyState(touched=now)
    if (
        not rules.skip_expiration
        and value.latest is not None
        and now - value.latest > RETENTION
    ):
        return KeyState(touched=now)
    return value


def lookup_state(entries: dict[int, KeyState], key: int, rules: Rules) -> KeyState | None:
    if not rules.cross_key_state:
        return entries.get(key)
    if key in entries:
        return entries[key]
    return next(iter(entries.values()), None)


def latest_period(value: KeyState) -> int | None:
    if value.previous is None or value.latest is None or value.latest < value.previous:
        return None
    period = value.latest - value.previous
    return period if 0 < period <= RETENTION else None


def required_remaining(value: KeyState, now: int, maximum: int) -> int:
    if value.latest is None:
        return 0
    return max(0, value.latest + maximum + 1 - now)


def implementation_admission(value: KeyState, now: int, rules: Rules) -> Admission:
    maximum = latest_period(value) if rules.latest_period_only else value.maximum_period
    if rules.enable_after_one and maximum is None and value.latest is not None:
        maximum = 1
    if maximum is None:
        return Admission(False, 0)
    if rules.zero_stabilization:
        return Admission(True, 0)
    if rules.remaining_period_wait:
        return Admission(True, required_remaining(value, now, maximum))
    if rules.non_strict_stabilization:
        return Admission(True, maximum)
    return Admission(True, maximum + 1)


def canonical_admission(value: KeyState, now: int) -> Admission:
    maximum = value.maximum_period
    return Admission(maximum is not None, maximum + 1 if maximum is not None else 0)


def trim(entries: dict[int, KeyState], rules: Rules) -> None:
    if rules.skip_state_trim or len(entries) <= STATE_LIMIT:
        return
    victim = min(entries, key=lambda key: (entries[key].touched, key))
    del entries[victim]


def begin(state: State, key: int, rules: Rules) -> tuple[State, Admission, Admission]:
    entries = as_dict(state)
    source = normalized(lookup_state(entries, key, rules), state.now, rules)
    canonical_source = normalized(entries.get(key), state.now, Rules())
    actual = implementation_admission(source, state.now, rules)
    expected = canonical_admission(canonical_source, state.now)
    entries[key] = KeyState(
        source.previous, source.latest, source.maximum_period, state.now
    )
    trim(entries, rules)
    return State(state.now, canonical(entries)), actual, expected


def cancel(
    state: State, key: int, rules: Rules
) -> tuple[State, CancellationObservation, CancellationObservation]:
    entries = as_dict(state)
    source = normalized(lookup_state(entries, key, rules), state.now, rules)
    canonical_source = normalized(entries.get(key), state.now, Rules())

    def observe(value: KeyState, applied_rules: Rules) -> tuple[KeyState, CancellationObservation]:
        previous = (
            value.latest
            if value.latest is not None and state.now - value.latest <= RETENTION
            else None
        )
        provisional = KeyState(
            previous=previous,
            latest=state.now,
            maximum_period=value.maximum_period,
            touched=state.now,
        )
        period = latest_period(provisional)
        maximum = value.maximum_period
        if period is not None:
            maximum = max(maximum or 0, period)
        elif previous is None:
            maximum = None
        next_value = KeyState(previous, state.now, maximum, state.now)
        return next_value, CancellationObservation(period is not None, period)

    actual_state, actual_observation = observe(source, rules)
    _, expected_observation = observe(canonical_source, Rules())
    entries[key] = actual_state
    trim(entries, rules)
    return State(state.now, canonical(entries)), actual_observation, expected_observation


def tick(state: State) -> State:
    return State(state.now + 1, state.entries)


def invariant(state: State) -> str | None:
    if len(state.entries) > STATE_LIMIT:
        return f"state count {len(state.entries)} exceeds limit {STATE_LIMIT}"
    for _, value in state.entries:
        if value.previous is not None and value.latest is not None:
            if value.previous > value.latest:
                return "cancellation timestamps reversed"
        if value.maximum_period is not None and not (0 < value.maximum_period <= RETENTION):
            return f"maximum period {value.maximum_period} outside (0,{RETENTION}]"
        period = latest_period(value)
        if period is not None and value.maximum_period is not None and value.maximum_period < period:
            return "maximum observed period is below latest period"
    return None


def find_counterexample(rules: Rules) -> tuple[list[str], str] | None:
    initial = State()
    queue = deque([(initial, [])])
    seen = {(initial, 0)}
    while queue:
        state, trace = queue.popleft()
        if len(trace) >= MAX_DEPTH:
            continue
        candidates: list[tuple[State, str, str | None]] = [(tick(state), "tick", None)]
        for key in KEYS:
            after_cancel, actual_cancel, expected_cancel = cancel(state, key, rules)
            cancel_reason = None
            if actual_cancel != expected_cancel:
                cancel_reason = (
                    f"cancellation observation {actual_cancel} differs from {expected_cancel}"
                )
            candidates.append(
                (
                    after_cancel,
                    f"cancel({key})->warm({actual_cancel.should_warm},period={actual_cancel.period})",
                    cancel_reason,
                )
            )

            after_begin, actual_begin, expected_begin = begin(state, key, rules)
            begin_reason = None
            if actual_begin != expected_begin:
                begin_reason = f"admission {actual_begin} differs from {expected_begin}"
            elif actual_begin.stabilization < 0 or actual_begin.stabilization > RETENTION + 1:
                begin_reason = f"stabilization {actual_begin.stabilization} outside [0,{RETENTION + 1}]"
            candidates.append(
                (
                    after_begin,
                    f"begin({key})->handoff({actual_begin.preserves_fetch}),"
                    f"stabilize({actual_begin.stabilization})",
                    begin_reason,
                )
            )
        for after, label, reason in candidates:
            reason = reason or invariant(after)
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
        next_states = [tick(state)]
        for key in KEYS:
            next_states.append(cancel(state, key, Rules())[0])
            next_states.append(begin(state, key, Rules())[0])
        for after in next_states:
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
        "enable-after-one-cancellation": Rules(enable_after_one=True),
        "zero-stabilization": Rules(zero_stabilization=True),
        "non-strict-stabilization": Rules(non_strict_stabilization=True),
        "latest-period-only": Rules(latest_period_only=True),
        "remaining-period-wait": Rules(remaining_period_wait=True),
        "cross-presentation-class": Rules(cross_key_state=True),
        "expired-state-survives": Rules(skip_expiration=True),
        "state-cap-disabled": Rules(skip_state_trim=True),
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
        "Adaptive image admission model: "
        f"states={states} transitions={transitions} depth={MAX_DEPTH} "
        f"mutantsKilled={len(mutants) - len(survivors)}/{len(mutants)}"
    )
    return 1 if survivors else 0


if __name__ == "__main__":
    raise SystemExit(main())
