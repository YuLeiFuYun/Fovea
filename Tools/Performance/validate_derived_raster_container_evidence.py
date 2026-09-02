#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
import subprocess
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
REAL_ROOT = ROOT.parent / "ImageCraft/Evidence/Fixtures/ProgressiveJPEGRealPhoto/v1/sources"
HERO_ROOT = ROOT / "Benchmarks/ComparativeLab/Apps/GeneratedResources/heroes"
TARGETS = [(390, 260), (780, 520), (1170, 780)]
INPUTS = {
    "animal-usda-cow-sunset": (REAL_ROOT / "animal-usda-cow-sunset.jpg", "real-photo"),
    "architecture-usda-snow": (REAL_ROOT / "architecture-usda-snow.jpg", "real-photo"),
    "landscape-coconino-sunflowers": (REAL_ROOT / "landscape-coconino-sunflowers.jpg", "real-photo"),
    "people-usda-meeting": (REAL_ROOT / "people-usda-meeting.jpg", "real-photo"),
    "hero-12mp-4000x3000": (HERO_ROOT / "hero-12mp-4000x3000.jpg", "hero"),
    "hero-24mp-6000x4000": (HERO_ROOT / "hero-24mp-6000x4000.jpg", "hero"),
    "hero-48mp-8000x6000": (HERO_ROOT / "hero-48mp-8000x6000.jpg", "hero"),
}
DURATION_FIELDS = [
    "directDecode",
    "directDecodeAndRGBMaterialization",
    "containerEncodeFromRGB",
    "containerMaterializeAndEncode",
    "containerCreationFromOriginal",
    "containerValidateAndDecode",
    "containerDecodeVerifiedBytes",
    "akashicLoadAndDecode",
]


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def median_int(samples: list[int]) -> int:
    ordered = sorted(samples)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) // 2


def p95(samples: list[int]) -> int:
    ordered = sorted(samples)
    return ordered[min(len(ordered) - 1, math.ceil(len(ordered) * 0.95) - 1)]


def git_identity() -> dict[str, Any]:
    def text(*args: str) -> str:
        return subprocess.run(
            ["git", *args], cwd=ROOT, check=True, text=True,
            stdout=subprocess.PIPE,
        ).stdout

    head = text("rev-parse", "HEAD").strip()
    dirty = bool(text("status", "--porcelain=v1").strip())
    digest = hashlib.sha256()
    digest.update(b"fovea-worktree-v1\0" + head.encode())
    digest.update(subprocess.run(
        ["git", "diff", "--binary", "HEAD"], cwd=ROOT, check=True,
        stdout=subprocess.PIPE,
    ).stdout)
    untracked = text("ls-files", "--others", "--exclude-standard", "-z").split("\0")
    for relative in sorted(value for value in untracked if value):
        path = ROOT / relative
        if path.is_file() and not path.is_symlink():
            digest.update(relative.encode() + b"\0" + path.read_bytes() + b"\0")
    return {
        "commit": head,
        "sourceTreeDigest": digest.hexdigest(),
        "includesWorkingTreeChanges": dirty,
    }


def load_report(path: Path, input_path: Path, width: int, height: int) -> dict[str, Any]:
    value = json.loads(path.read_text())
    if value.get("schemaVersion") != 1:
        raise ValueError(f"{path}: unsupported schema")
    if value.get("evidenceVersion") != "fovea-derived-raster-container-performance-v1":
        raise ValueError(f"{path}: wrong evidence version")
    input_bytes = input_path.read_bytes()
    expected = {
        "inputPathBasename": input_path.name,
        "inputByteCount": len(input_bytes),
        "inputSHA256": sha256_bytes(input_bytes),
        "targetWidth": width,
        "targetHeight": height,
        "warmupIterations": 3,
        "measuredIterations": 15,
    }
    for key, expected_value in expected.items():
        if value.get(key) != expected_value:
            raise ValueError(f"{path}: {key} mismatch")
    counts = value.get("orderCounts")
    if not isinstance(counts, dict) or set(counts) != {"rotation-0", "rotation-1", "rotation-2"}:
        raise ValueError(f"{path}: order counts missing")
    order_values = list(counts.values())
    if sum(order_values) != 15 or max(order_values) - min(order_values) > 1:
        raise ValueError(f"{path}: order counts are not balanced")
    for digest_key in ("outputRGBSHA256", "containerSHA256"):
        digest = value.get(digest_key)
        if not isinstance(digest, str) or len(digest) != 64:
            raise ValueError(f"{path}: invalid {digest_key}")
    if value.get("containerByteCount", 0) <= 120:
        raise ValueError(f"{path}: invalid container size")
    if value.get("outputWidth", 0) <= 0 or value.get("outputHeight", 0) <= 0:
        raise ValueError(f"{path}: invalid output dimensions")
    for field in DURATION_FIELDS:
        summary = value.get(field)
        if not isinstance(summary, dict):
            raise ValueError(f"{path}: missing {field}")
        samples = summary.get("samplesNanoseconds")
        if not isinstance(samples, list) or len(samples) != 15:
            raise ValueError(f"{path}: invalid {field} samples")
        if any(not isinstance(sample, int) or sample <= 0 for sample in samples):
            raise ValueError(f"{path}: nonpositive {field} sample")
        if summary.get("medianNanoseconds") != median_int(samples):
            raise ValueError(f"{path}: {field} median mismatch")
        if summary.get("p95Nanoseconds") != p95(samples):
            raise ValueError(f"{path}: {field} p95 mismatch")
    return value


def stats(values: list[int | float]) -> dict[str, int | float]:
    return {
        "minimum": min(values),
        "median": statistics.median(values),
        "maximum": max(values),
    }


def summarize(docs: list[dict[str, Any]]) -> dict[str, Any]:
    byte_ratios = []
    memory_speedups = []
    store_speedups = []
    validation_ratios = []
    encode_rgb_ms = []
    materialize_encode_ms = []
    full_creation_ms = []
    break_even_rgb = []
    break_even_cgimage = []
    for doc in docs:
        direct = doc["directDecode"]["medianNanoseconds"]
        memory = doc["containerDecodeVerifiedBytes"]["medianNanoseconds"]
        store = doc["akashicLoadAndDecode"]["medianNanoseconds"]
        encode = doc["containerEncodeFromRGB"]["medianNanoseconds"]
        materialize = doc["containerMaterializeAndEncode"]["medianNanoseconds"]
        savings = direct - store
        byte_ratios.append(doc["containerByteCount"] / doc["inputByteCount"])
        memory_speedups.append(direct / memory)
        store_speedups.append(direct / store)
        validation_ratios.append(doc["containerValidateAndDecode"]["medianNanoseconds"] / memory)
        encode_rgb_ms.append(encode / 1_000_000)
        materialize_encode_ms.append(materialize / 1_000_000)
        full_creation_ms.append(doc["containerCreationFromOriginal"]["medianNanoseconds"] / 1_000_000)
        if savings > 0:
            break_even_rgb.append(math.ceil(encode / savings) + 1)
            break_even_cgimage.append(math.ceil(materialize / savings) + 1)
    return {
        "targetCount": len(docs),
        "containerToOriginalByteRatio": stats(byte_ratios),
        "directDecodeToMemoryContainerSpeedup": stats(memory_speedups),
        "directDecodeToAkashicContainerSpeedup": stats(store_speedups),
        "completeValidationToStorageVerifiedDecodeRatio": stats(validation_ratios),
        "encodeFromRGBMilliseconds": stats(encode_rgb_ms),
        "materializeAndEncodeMilliseconds": stats(materialize_encode_ms),
        "decodeMaterializeAndEncodeMilliseconds": stats(full_creation_ms),
        "breakEvenFutureHitsFromRGBWithOneSafetyHit": stats(break_even_rgb),
        "breakEvenFutureHitsFromCGImageWithOneSafetyHit": stats(break_even_cgimage),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report_directory", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    expected_names: set[str] = set()
    groups: dict[str, list[dict[str, Any]]] = {"real-photo": [], "hero": []}
    entries = []
    for input_name, (input_path, group) in INPUTS.items():
        if not input_path.is_file():
            raise FileNotFoundError(input_path)
        for width, height in TARGETS:
            filename = f"{input_name}-{width}x{height}.json"
            expected_names.add(filename)
            path = args.report_directory / filename
            if not path.is_file():
                raise FileNotFoundError(path)
            doc = load_report(path, input_path, width, height)
            groups[group].append(doc)
            entries.append({
                "fileName": filename,
                "sha256": sha256_bytes(path.read_bytes()),
                "input": input_name,
                "targetWidth": width,
                "targetHeight": height,
                "outputRGBSHA256": doc["outputRGBSHA256"],
                "containerSHA256": doc["containerSHA256"],
            })
    observed_names = {
        path.name
        for path in args.report_directory.glob("*.json")
        if path.resolve() != args.output.resolve()
    }
    if observed_names != expected_names:
        raise ValueError(
            f"report set mismatch: missing={sorted(expected_names-observed_names)} "
            f"extra={sorted(observed_names-expected_names)}"
        )
    aggregate = {
        "schemaVersion": 1,
        "reportID": "FOVEA-DERIVED-RASTER-CONTAINER-DIRECTIONAL-V1",
        "qualification": "dirty-local-directional",
        "claimBoundary": {
            "productionPipelineEnabled": False,
            "physicalDeviceQualified": False,
            "crossOSGuarantee": False,
            "globalPerformanceSuperiority": False,
        },
        "sourceIdentity": git_identity(),
        "reportCount": len(entries),
        "reports": sorted(entries, key=lambda value: value["fileName"]),
        "groups": {group: summarize(docs) for group, docs in groups.items()},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(aggregate, indent=2, sort_keys=True) + "\n")
    print(
        "validated derived raster container evidence: "
        f"reports={len(entries)} sourceDirty={aggregate['sourceIdentity']['includesWorkingTreeChanges']}"
    )
    for group, summary in aggregate["groups"].items():
        print(
            f"{group}: targets={summary['targetCount']} "
            f"storeSpeedupMedian={summary['directDecodeToAkashicContainerSpeedup']['median']:.3f} "
            f"byteRatioMedian={summary['containerToOriginalByteRatio']['median']:.3f}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
