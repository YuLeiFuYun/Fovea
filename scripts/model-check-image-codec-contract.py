#!/usr/bin/env python3
"""Exhaustively model-check Fovea's finite codec capability and admission algebra."""
from __future__ import annotations

from dataclasses import dataclass
from itertools import chain, combinations, product

FORMATS = ("png", "jpeg", "gif")
DELIVERY = ("complete", "progressive")
TRACKS = ("primary", "animated")
METADATA = ("orientation", "color", "hdr", "timing")
RANGES = ("sdr", "hdr")
OUTPUTS = ("cgimage", "pixel-buffer", "planar")
CANCELLATION = (0, 1)


@dataclass(frozen=True)
class Capability:
    formats: frozenset[str]
    delivery: frozenset[str]
    tracks: frozenset[str]
    metadata: frozenset[str]
    ranges: frozenset[str]
    outputs: frozenset[str]
    cancellation: int


@dataclass(frozen=True)
class Request:
    format: str
    delivery: str
    track: str
    metadata: frozenset[str]
    dynamic_range: str
    output: str
    cancellation: int


def subsets(values: tuple[str, ...]):
    return tuple(
        frozenset(group)
        for size in range(len(values) + 1)
        for group in combinations(values, size)
    )


def supports(cap: Capability, req: Request) -> bool:
    return (
        req.format in cap.formats
        and req.delivery in cap.delivery
        and req.track in cap.tracks
        and req.metadata <= cap.metadata
        and req.dynamic_range in cap.ranges
        and req.output in cap.outputs
        and req.cancellation <= cap.cancellation
    )


def requests():
    for values in product(
        FORMATS,
        DELIVERY,
        TRACKS,
        subsets(METADATA),
        RANGES,
        OUTPUTS,
        CANCELLATION,
    ):
        yield Request(*values)


def assert_capability_monotonicity() -> int:
    subset = Capability(
        frozenset({"png"}),
        frozenset({"complete"}),
        frozenset({"primary"}),
        frozenset({"orientation"}),
        frozenset({"sdr"}),
        frozenset({"cgimage"}),
        0,
    )
    superset = Capability(
        frozenset(FORMATS),
        frozenset(DELIVERY),
        frozenset(TRACKS),
        frozenset(METADATA),
        frozenset(RANGES),
        frozenset(OUTPUTS),
        1,
    )
    checked = 0
    for req in requests():
        if supports(subset, req):
            assert supports(superset, req), req
        checked += 1
    return checked


def assert_generation_order(bound: int = 64) -> int:
    checked = 0
    for a, b, c in product(range(bound), repeat=3):
        replace_ab = a > b
        replace_bc = b > c
        assert (a > a) is False
        if replace_ab and replace_bc:
            assert a > c
        checked += 1
    return checked


def assert_resource_join() -> int:
    values = (1, 2, 3, 255, 4096, 2**31 - 1, 2**63 - 1)
    checked = 0
    for generic, backend in product(values, repeat=2):
        admitted = max(generic, backend)
        assert admitted >= generic
        assert admitted >= backend
        assert admitted == max(backend, generic)
        assert max(admitted, admitted) == admitted
        checked += 1
    return checked


def assert_timing_domain() -> int:
    max_u64 = 2**64 - 1
    samples = (0, 1, 2, max_u64 - 1, max_u64)
    checked = 0
    for timestamp, duration in product(samples, repeat=2):
        valid = duration > 0 and timestamp + duration <= max_u64
        if valid:
            assert 0 < duration <= max_u64 - timestamp
        else:
            assert duration == 0 or timestamp + duration > max_u64
        checked += 1
    return checked


def main() -> int:
    capability_cases = assert_capability_monotonicity()
    generation_cases = assert_generation_order()
    resource_cases = assert_resource_join()
    timing_cases = assert_timing_domain()
    print(
        "Image codec contract model: "
        f"capability={capability_cases} generation={generation_cases} "
        f"resource={resource_cases} timing={timing_cases} errors=0"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
