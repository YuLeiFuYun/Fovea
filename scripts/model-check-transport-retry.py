#!/usr/bin/env python3
"""有限穷举传输重试的尝试、退避、Retry-After、延迟和字节预算。"""
from __future__ import annotations

from dataclasses import dataclass
from itertools import product

MAX_ATTEMPTS = 4
BASE_DELAY = 2
MAX_DELAY = 6
MAX_TOTAL_DELAY = 7
MAX_ADDITIONAL_BYTES = 5
MACHINE_LIMIT = 16
WRAP_MODULUS = 8


@dataclass(frozen=True)
class State:
    attempt: int
    total_delay: int
    additional_bytes: int


@dataclass(frozen=True)
class Event:
    retryable: bool
    status: int | None
    received_bytes: int | None
    retry_after: int | None
    jitter_permille: int


@dataclass(frozen=True)
class Plan:
    delay: int
    additional_bytes: int | None


@dataclass(frozen=True)
class Rules:
    retry_terminal: bool = False
    ignore_attempt_limit: bool = False
    uncapped_exponential: bool = False
    undercut_retry_after: bool = False
    ignore_total_delay: bool = False
    wrap_total_delay: bool = False
    ignore_byte_budget: bool = False
    retry_not_modified: bool = False


def exponential(failed_attempt: int, rules: Rules) -> int:
    if failed_attempt <= 0 or BASE_DELAY <= 0:
        return 0
    value = BASE_DELAY * (1 << (failed_attempt - 1))
    return value if rules.uncapped_exponential else min(MAX_DELAY, value)


def jittered_delay(event: Event, state: State, rules: Rules) -> int:
    exp = exponential(state.attempt, rules)
    fraction = min(1000, max(0, event.jitter_permille))
    jittered = exp * fraction // 1000
    server_minimum = min(MAX_DELAY, event.retry_after or 0)
    if rules.undercut_retry_after:
        return min(MAX_DELAY, jittered)
    return max(server_minimum, min(MAX_DELAY, jittered))


def oracle(state: State, event: Event) -> Plan | None:
    if not event.retryable or state.attempt >= MAX_ATTEMPTS or event.status == 304:
        return None
    next_bytes: int | None = None
    if event.received_bytes is not None:
        total_bytes = state.additional_bytes + event.received_bytes
        if total_bytes >= MACHINE_LIMIT or total_bytes > MAX_ADDITIONAL_BYTES:
            return None
        next_bytes = total_bytes
    delay = jittered_delay(event, state, Rules())
    next_delay = state.total_delay + delay
    if next_delay >= MACHINE_LIMIT or next_delay > MAX_TOTAL_DELAY:
        return None
    return Plan(delay=delay, additional_bytes=next_bytes)


def implementation(state: State, event: Event, rules: Rules) -> Plan | None:
    if not event.retryable and not rules.retry_terminal:
        return None
    if not rules.ignore_attempt_limit and state.attempt >= MAX_ATTEMPTS:
        return None
    if event.status == 304 and not rules.retry_not_modified:
        return None

    next_bytes: int | None = None
    if event.received_bytes is not None:
        total_bytes = state.additional_bytes + event.received_bytes
        if total_bytes >= MACHINE_LIMIT:
            return None
        if not rules.ignore_byte_budget and total_bytes > MAX_ADDITIONAL_BYTES:
            return None
        next_bytes = total_bytes

    delay = jittered_delay(event, state, rules)
    if rules.wrap_total_delay:
        next_delay = (state.total_delay + delay) % WRAP_MODULUS
    else:
        next_delay = state.total_delay + delay
        if next_delay >= MACHINE_LIMIT:
            return None
    if not rules.ignore_total_delay and next_delay > MAX_TOTAL_DELAY:
        return None
    return Plan(delay=delay, additional_bytes=next_bytes)


def states() -> tuple[State, ...]:
    return tuple(
        State(attempt, total, byte_count)
        for attempt, total, byte_count in product(range(1, 6), range(0, 9), range(0, 7))
    )


def events() -> tuple[Event, ...]:
    values: list[Event] = []
    for retryable, status, received, retry_after, jitter in product(
        (False, True),
        (None, 304, 503),
        (None, 0, 2, 6),
        (None, 0, 3, 9),
        (0, 500, 1000),
    ):
        # Transport failures have no HTTP response byte accounting.
        if status is None and received is not None:
            continue
        # HTTP responses always provide a byte count, including zero.
        if status is not None and received is None:
            continue
        values.append(Event(retryable, status, received, retry_after, jitter))
    return tuple(values)


STATES = states()
EVENTS = events()


def first_mismatch(rules: Rules) -> tuple[State, Event, Plan | None, Plan | None] | None:
    for state, event in product(STATES, EVENTS):
        expected = oracle(state, event)
        actual = implementation(state, event, rules)
        if expected != actual:
            return state, event, expected, actual
    return None


def main() -> int:
    canonical = first_mismatch(Rules())
    if canonical:
        print(f"canonical differs from oracle: {canonical}")
        return 1

    mutants = {
        "retry-terminal-failure": Rules(retry_terminal=True),
        "ignore-attempt-limit": Rules(ignore_attempt_limit=True),
        "uncapped-exponential": Rules(uncapped_exponential=True),
        "undercut-retry-after": Rules(undercut_retry_after=True),
        "ignore-total-delay-budget": Rules(ignore_total_delay=True),
        "wrapping-total-delay-addition": Rules(wrap_total_delay=True),
        "ignore-additional-byte-budget": Rules(ignore_byte_budget=True),
        "retry-304": Rules(retry_not_modified=True),
    }
    survivors: list[str] = []
    for name, rules in mutants.items():
        result = first_mismatch(rules)
        if result is None:
            survivors.append(name)
            print(f"mutant survived: {name}")
        else:
            state, event, expected, actual = result
            print(
                f"mutant killed: {name}: state={state} event={event} "
                f"expected={expected} actual={actual}"
            )

    print(
        "Transport retry finite model: "
        f"states={len(STATES)} events={len(EVENTS)} combinations={len(STATES)*len(EVENTS)} "
        f"mutantsKilled={len(mutants)-len(survivors)}/{len(mutants)}"
    )
    return 1 if survivors else 0


if __name__ == "__main__":
    raise SystemExit(main())
