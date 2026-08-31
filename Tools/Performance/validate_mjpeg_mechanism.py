#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import pathlib
import statistics


def fail(message: str) -> None:
    raise SystemExit(message)


def p95(values: list[float]) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, math.ceil(len(ordered) * 0.95) - 1)]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=pathlib.Path)
    parser.add_argument("--blocks", type=int, default=6)
    args = parser.parse_args()
    root = args.directory.resolve()
    manifest = json.loads((root / "capture-manifest.json").read_text())
    if manifest.get("schemaVersion") != 1 or manifest.get("blockCount") != args.blocks:
        fail("manifest schema or block count mismatch")
    repository = pathlib.Path(__file__).resolve().parents[2]
    for relative, expected in manifest["source"]["relevantFiles"].items():
        actual = hashlib.sha256((repository / relative).read_bytes()).hexdigest()
        if actual != expected:
            fail(f"source identity drift: {relative}")
    all_trials = []
    block_summaries = []
    for block in range(args.blocks):
        path = root / f"block-{block:02d}.json"
        report = json.loads(path.read_text())
        if report.get("schemaVersion") != 1 or report.get("mode") != "mjpeg-latest-only-mechanism":
            fail(f"{path}: schema or mode mismatch")
        if not report.get("allCorrect") or not report.get("orderBalanced"):
            fail(f"{path}: correctness or order balance failed")
        if report.get("frameCount") != 120 or report.get("encodedBytesPerFrame") != 4096:
            fail(f"{path}: workload identity mismatch")
        trials = report.get("trials")
        if not isinstance(trials, list) or len(trials) != 8:
            fail(f"{path}: trial count mismatch")
        if sum(t["order"] == "latest-first" for t in trials) != 4:
            fail(f"{path}: order rotation mismatch")
        for trial in trials:
            if trial["latestDecodeCount"] != 2 or trial["decodeEveryCount"] != 120:
                fail(f"{path}: decode count mismatch")
            if trial["latestDroppedFrameCount"] != 118:
                fail(f"{path}: drop count mismatch")
            if trial["finalSourceIndex"] != 119 or not trial["finalPixelDigestEqual"]:
                fail(f"{path}: final correctness mismatch")
            if trial["latestPeakQueuedEncodedBytes"] != 4096:
                fail(f"{path}: latest queue bound mismatch")
            if trial["decodeEveryPeakQueuedEncodedBytes"] != 4096 * 120:
                fail(f"{path}: baseline queue identity mismatch")
            if trial["latestElapsedNanoseconds"] <= 0 or trial["decodeEveryElapsedNanoseconds"] <= 0:
                fail(f"{path}: invalid timing")
        ratios = [t["latestElapsedNanoseconds"] / t["decodeEveryElapsedNanoseconds"] for t in trials]
        block_summaries.append({
            "block": block,
            "medianPairedElapsedRatio": statistics.median(ratios),
            "p95PairedElapsedRatio": p95(ratios),
            "medianLatestNanoseconds": statistics.median(t["latestElapsedNanoseconds"] for t in trials),
            "medianDecodeEveryNanoseconds": statistics.median(t["decodeEveryElapsedNanoseconds"] for t in trials),
        })
        all_trials.extend(trials)
    all_ratios = [t["latestElapsedNanoseconds"] / t["decodeEveryElapsedNanoseconds"] for t in all_trials]
    aggregate = {
        "schemaVersion": 1,
        "sourceManifest": str(root / "capture-manifest.json"),
        "blockCount": args.blocks,
        "trialCount": len(all_trials),
        "allCorrect": True,
        "orderBalanced": True,
        "latestDecodeFraction": 2 / 120,
        "latestQueueByteFraction": 1 / 120,
        "medianPairedElapsedRatio": statistics.median(all_ratios),
        "p95PairedElapsedRatio": p95(all_ratios),
        "maximumPairedElapsedRatio": max(all_ratios),
        "pairedRatiosAboveOneCount": sum(value > 1 for value in all_ratios),
        "blockSummaries": block_summaries,
        "claimBoundary": [
            "synthetic CPU decode work; not codec throughput",
            "decode-every queue is intentionally not memory-equivalent",
            "no network, display deadline, energy, thermal or physical-device evidence",
            "no performance threshold or overall product ranking",
        ],
    }
    (root / "aggregate.json").write_text(json.dumps(aggregate, indent=2, sort_keys=True) + "\n")
    print(json.dumps({
        "blocks": args.blocks,
        "trials": len(all_trials),
        "medianPairedElapsedRatio": aggregate["medianPairedElapsedRatio"],
        "p95PairedElapsedRatio": aggregate["p95PairedElapsedRatio"],
        "maximumPairedElapsedRatio": aggregate["maximumPairedElapsedRatio"],
        "pairedRatiosAboveOneCount": aggregate["pairedRatiosAboveOneCount"],
    }, sort_keys=True))


if __name__ == "__main__":
    main()
