#!/usr/bin/env python3
"""有限穷举 HTTP 元数据规范化的计数、字节、重复和溢出不变量。"""
from __future__ import annotations

from dataclasses import dataclass
from itertools import combinations, product

MAX_HEADER_COUNT = 2
MAX_HEADER_BYTES = 15
MAX_FIELD_NAME_BYTES = 2
MAX_FIELD_VALUE_BYTES = 3
MACHINE_LIMIT = 32
WRAPPING_MODULUS = 16

NAMES = ("A", "a", "B", "bb", "bad\n", "xxx")
VALUES = ("", "v", "vvv", "vvvv", "\n")


@dataclass(frozen=True)
class Rules:
    skip_count_limit: bool = False
    skip_name_validation: bool = False
    skip_value_validation: bool = False
    count_duplicate_bytes: bool = False
    wrapping_addition: bool = False
    skip_total_byte_limit: bool = False


@dataclass(frozen=True)
class Outcome:
    accepted: bool
    headers: tuple[tuple[str, str], ...] = ()
    total_bytes: int = 0


def valid_name(name: str) -> bool:
    if not name or len(name.encode()) > MAX_FIELD_NAME_BYTES:
        return False
    punctuation = set("!#$%&'*+-.^_`|~")
    return all(character.isascii() and (character.isalnum() or character in punctuation) for character in name)


def valid_value(value: str) -> bool:
    if len(value.encode()) > MAX_FIELD_VALUE_BYTES:
        return False
    return all(ord(character) >= 0x20 and ord(character) != 0x7F or character == "\t" for character in value)


def canonical(input_headers: tuple[tuple[str, str], ...]) -> Outcome:
    if len(input_headers) > MAX_HEADER_COUNT:
        return Outcome(False)
    result: dict[str, str] = {}
    total = 0
    items = sorted(
        ((name.lower(), name, value) for name, value in input_headers),
        key=lambda item: (item[0], item[1], item[2]),
    )
    for normalized, _, value in items:
        if not valid_name(normalized) or not valid_value(value):
            return Outcome(False)
        if normalized in result:
            continue
        addition = len(normalized.encode()) + len(value.encode()) + 4
        next_total = total + addition
        if next_total >= MACHINE_LIMIT or next_total > MAX_HEADER_BYTES:
            return Outcome(False)
        total = next_total
        result[normalized] = value
    return Outcome(True, tuple(sorted(result.items())), total)


def implementation(input_headers: tuple[tuple[str, str], ...], rules: Rules) -> Outcome:
    if not rules.skip_count_limit and len(input_headers) > MAX_HEADER_COUNT:
        return Outcome(False)
    result: dict[str, str] = {}
    total = 0
    items = sorted(
        ((name.lower(), name, value) for name, value in input_headers),
        key=lambda item: (item[0], item[1], item[2]),
    )
    for normalized, _, value in items:
        if not rules.skip_name_validation and not valid_name(normalized):
            return Outcome(False)
        if not rules.skip_value_validation and not valid_value(value):
            return Outcome(False)
        duplicate = normalized in result
        if duplicate and not rules.count_duplicate_bytes:
            continue
        addition = len(normalized.encode()) + len(value.encode()) + 4
        if rules.wrapping_addition:
            next_total = (total + addition) % WRAPPING_MODULUS
        else:
            next_total = total + addition
            if next_total >= MACHINE_LIMIT:
                return Outcome(False)
        if not rules.skip_total_byte_limit and next_total > MAX_HEADER_BYTES:
            return Outcome(False)
        total = next_total
        if not duplicate:
            result[normalized] = value
    return Outcome(True, tuple(sorted(result.items())), total)


def inputs() -> tuple[tuple[tuple[str, str], ...], ...]:
    pairs = tuple(product(NAMES, VALUES))
    values: list[tuple[tuple[str, str], ...]] = [()]
    # Dictionary-like input may contain case-insensitive duplicates but not exact duplicate keys.
    for length in range(1, 4):
        for indices in combinations(range(len(pairs)), length):
            candidate = tuple(pairs[index] for index in indices)
            names = [name for name, _ in candidate]
            if len(set(names)) == len(names):
                values.append(candidate)
    return tuple(values)


INPUTS = inputs()


def mismatch(rules: Rules) -> tuple[tuple[tuple[str, str], ...], Outcome, Outcome] | None:
    for candidate in INPUTS:
        expected = canonical(candidate)
        actual = implementation(candidate, rules)
        if actual != expected:
            return candidate, expected, actual
    return None


def main() -> int:
    canonical_mismatch = mismatch(Rules())
    if canonical_mismatch:
        print(f"canonical implementation differs from oracle: {canonical_mismatch}")
        return 1

    mutants = {
        "skip-header-count-limit": Rules(skip_count_limit=True),
        "skip-field-name-validation": Rules(skip_name_validation=True),
        "skip-field-value-validation": Rules(skip_value_validation=True),
        "count-case-insensitive-duplicate-bytes": Rules(count_duplicate_bytes=True),
        "wrapping-byte-addition": Rules(wrapping_addition=True),
        "skip-total-header-byte-limit": Rules(skip_total_byte_limit=True),
    }
    survivors: list[str] = []
    for name, rules in mutants.items():
        result = mismatch(rules)
        if result is None:
            survivors.append(name)
            print(f"mutant survived: {name}")
        else:
            candidate, expected, actual = result
            print(
                f"mutant killed: {name}: input={candidate} "
                f"expected={expected} actual={actual}"
            )

    print(
        "HTTP metadata finite model: "
        f"inputs={len(INPUTS)} mutantsKilled={len(mutants)-len(survivors)}/{len(mutants)} "
        f"limits=count:{MAX_HEADER_COUNT},bytes:{MAX_HEADER_BYTES},"
        f"name:{MAX_FIELD_NAME_BYTES},value:{MAX_FIELD_VALUE_BYTES}"
    )
    return 1 if survivors else 0


if __name__ == "__main__":
    raise SystemExit(main())
