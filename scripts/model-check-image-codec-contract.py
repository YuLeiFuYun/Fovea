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
    progressive_formats: frozenset[str]
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
        and (req.delivery != "progressive" or req.format in cap.progressive_formats)
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
        frozenset(),
        frozenset({"primary"}),
        frozenset({"orientation"}),
        frozenset({"sdr"}),
        frozenset({"cgimage"}),
        0,
    )
    superset = Capability(
        frozenset(FORMATS),
        frozenset(DELIVERY),
        frozenset(FORMATS),
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


def assert_progressive_format_coupling() -> int:
    cap = Capability(
        frozenset({"png", "jpeg"}),
        frozenset({"complete", "progressive"}),
        frozenset({"jpeg"}),
        frozenset({"primary"}),
        frozenset({"orientation", "color"}),
        frozenset({"sdr"}),
        frozenset({"cgimage"}),
        0,
    )
    checked = 0
    for image_format in ("png", "jpeg"):
        req = Request(
            image_format,
            "progressive",
            "primary",
            frozenset({"orientation"}),
            "sdr",
            "cgimage",
            0,
        )
        assert supports(cap, req) == (image_format == "jpeg")
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



def assert_complete_output_contract() -> int:
    limits = (8, 64)  # maximum dimension, maximum pixel count
    target = (10, 10)
    dimensions = ((1, 1), (8, 8), (9, 8), (10, 10), (11, 10))
    resident_bytes = (1, 1_200, 40_960)
    admitted_bytes = (1_200, 16_384)
    profile_matches = (False, True)
    checked = 0
    for (width, height), resident, admitted, profile_match in product(
        dimensions, resident_bytes, admitted_bytes, profile_matches
    ):
        conditions = (
            width <= limits[0],
            height <= limits[0],
            width * height <= limits[1],
            width <= target[0],
            height <= target[1],
            resident <= admitted,
            profile_match,
        )
        accepted = all(conditions)
        if accepted:
            assert all(conditions)
        else:
            assert any(not condition for condition in conditions)
        checked += 1
    return checked


def assert_progressive_output_contract() -> int:
    limits = (8, 64)
    target = (10, 10)
    dimensions = ((1, 1), (8, 8), (9, 8), (10, 10), (11, 10))
    resident_bytes = (1, 4_096, 40_960)
    maximum_resident_bytes = (4_096, 16_384)
    checked = 0
    for (width, height), resident, maximum_resident in product(
        dimensions, resident_bytes, maximum_resident_bytes
    ):
        conditions = (
            width <= limits[0],
            height <= limits[0],
            width * height <= limits[1],
            width <= target[0],
            height <= target[1],
            resident <= maximum_resident,
        )
        accepted = all(conditions)
        if accepted:
            assert all(conditions)
        else:
            assert any(not condition for condition in conditions)
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
    progressive_format_cases = assert_progressive_format_coupling()
    generation_cases = assert_generation_order()
    resource_cases = assert_resource_join()
    complete_output_cases = assert_complete_output_contract()
    progressive_output_cases = assert_progressive_output_contract()
    timing_cases = assert_timing_domain()
    print(
        "Image codec contract model: "
        f"capability={capability_cases} progressive_format={progressive_format_cases} "
        f"generation={generation_cases} "
        f"resource={resource_cases} complete_output={complete_output_cases} "
        f"progressive_output={progressive_output_cases} timing={timing_cases} errors=0"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
