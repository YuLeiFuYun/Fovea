#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
EXPECTED_EVIDENCE_ID = "FOVEA-PROGRESSIVE-PRESENTATION-SIMULATOR-V2-2026-08-04"
EXPECTED_COMMIT = "3c82fdc3b2633e77acfcd204c264cca5ed1a4fd1"
EXPECTED_TREE = "96fd9cbc03ef9951f4bf830d960ef98b4954046f"
EXPECTED_IMAGECRAFT = "bc93b8df0337d7a57779b53106dd744ad97b095e"
EXPECTED_AKASHIC = "2715f23d50b5a17b7328be41608eaf1b1c99b0d6"
FIXTURE_PATH = "Sources/FoveaTesting/Fixtures/progressive-people-usda-meeting-1920x1280.jpg"
FIXTURE_SHA256 = "494941339b490cededbb482a47ff7e1352761a4dcc93c82527775ae46c573a87"
FIXTURE_BYTE_COUNT = 370_199


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def integer_statistics(values: list[int]) -> dict[str, int]:
    require(bool(values), "statistics input is empty")
    ordered = sorted(values)
    rank = max(1, (len(ordered) * 90 + 99) // 100)
    return {
        "minimum": ordered[0],
        "median": (ordered[(len(ordered) - 1) // 2] + ordered[len(ordered) // 2]) // 2,
        "p90": ordered[min(len(ordered) - 1, rank - 1)],
        "maximum": ordered[-1],
        "mean": sum(ordered) // len(ordered),
    }


def stable_preview_identity(events: list[dict[str, Any]]) -> list[tuple[int, int]]:
    return [(event["generation"], event["sourceByteCount"]) for event in events]


def validate_sample(sample: dict[str, Any]) -> None:
    require(sample.get("schemaVersion") == 1, "sample schema drifted")
    source = sample.get("source")
    require(isinstance(source, dict), "sample source is missing")
    require(source.get("resourceID") == "progressive-people-usda-meeting-1920x1280.jpg", "fixture ID drifted")
    require(source.get("byteCount") == FIXTURE_BYTE_COUNT, "fixture byte count drifted")
    require(source.get("sha256") == FIXTURE_SHA256, "fixture digest drifted")
    require(source.get("pixelWidth") == 1920 and source.get("pixelHeight") == 1280, "fixture geometry drifted")
    require(sample.get("targetWidth") == 512 and sample.get("targetHeight") == 341, "output geometry drifted")

    network = sample.get("networkChunks")
    generated = sample.get("generatedPreviews")
    emitted = sample.get("emittedPreviews")
    suppressed = sample.get("suppressedPreviews")
    displays = sample.get("displayObservations")
    require(all(isinstance(value, list) for value in (network, generated, emitted, suppressed, displays)), "sample arrays are missing")
    require([event["index"] for event in network] == list(range(len(network))), "network indices are not contiguous")
    cumulative = [event["cumulativeByteCount"] for event in network]
    require(cumulative == sorted(set(cumulative)), "network bytes are not strictly increasing")
    require(
        [event["elapsedNanoseconds"] for event in network]
        == sorted(event["elapsedNanoseconds"] for event in network),
        "network event time regressed",
    )
    generations = [event["generation"] for event in generated]
    source_counts = [event["sourceByteCount"] for event in generated]
    require(generations == sorted(set(generations)), "generation order is not strict")
    require(source_counts == sorted(set(source_counts)), "generation source bytes are not strict")
    require(
        [event["elapsedNanoseconds"] for event in generated]
        == sorted(event["elapsedNanoseconds"] for event in generated),
        "generation time regressed",
    )
    require(
        [event["elapsedNanoseconds"] for event in displays]
        == sorted(event["elapsedNanoseconds"] for event in displays),
        "display observation time regressed",
    )

    scenario = sample.get("scenario")
    if scenario == "complete":
        require(sample.get("chunkSizeBytes") == 16 * 1024, "complete chunk size drifted")
        require(sample.get("intervalNanoseconds") == 30_000_000, "complete interval drifted")
        require(len(network) == 23 and cumulative[-1] == FIXTURE_BYTE_COUNT, "complete body delivery drifted")
        require(len(generated) == 4, "complete preview count drifted")
        require(stable_preview_identity(generated) == stable_preview_identity(emitted), "emitted preview identity drifted")
        require(not suppressed, "complete scenario suppressed a preview")
        final_emitted = sample.get("finalEmittedElapsedNanoseconds")
        require(isinstance(final_emitted, int), "complete final emission is missing")
        require(final_emitted >= generated[-1]["elapsedNanoseconds"], "final emission preceded last generation")
        require(sample.get("publicationFenceClosedElapsedNanoseconds") is None, "complete scenario closed cancellation fence")
        require(sample.get("previewDisplayedBeforeFinal") is True, "preview was not observed before final")
        preview_displays = [event for event in displays if event["kind"] == "preview"]
        final_displays = [event for event in displays if event["kind"] == "final"]
        require(bool(preview_displays) and len(final_displays) == 1, "complete display observations drifted")
        require(
            preview_displays[0]["elapsedNanoseconds"] < final_displays[0]["elapsedNanoseconds"],
            "preview display did not precede final display",
        )
        require(
            [event["generation"] for event in preview_displays]
            == sorted(set(event["generation"] for event in preview_displays)),
            "displayed generation order is not strict",
        )
    elif scenario == "identity-replacement":
        require(sample.get("chunkSizeBytes") == 32 * 1024, "replacement chunk size drifted")
        require(sample.get("intervalNanoseconds") == 20_000_000, "replacement interval drifted")
        require(len(network) == 1 and cumulative[-1] == 32 * 1024, "replacement network boundary drifted")
        require(len(generated) == 1 and not emitted and len(suppressed) == 1, "replacement publication cardinality drifted")
        require(stable_preview_identity(generated) == stable_preview_identity(suppressed), "suppressed preview identity drifted")
        require(sample.get("finalEmittedElapsedNanoseconds") is None, "old identity emitted final pixels")
        fence = sample.get("publicationFenceClosedElapsedNanoseconds")
        require(isinstance(fence, int), "replacement fence is missing")
        require(sample.get("publicationFenceBeforeSuppression") is True, "fence did not precede suppression")
        require(fence <= suppressed[0]["elapsedNanoseconds"], "suppression preceded fence")
        require(sample.get("oldPreviewObservedAfterReplacement") is False, "old preview reached replacement identity")
        require(all(event["kind"] != "preview" for event in displays), "old preview appeared in display observations")
    else:
        raise AssertionError(f"unknown sample scenario: {scenario}")


def first_display(sample: dict[str, Any], kind: str) -> int:
    return next(
        event["elapsedNanoseconds"]
        for event in sample["displayObservations"]
        if event["kind"] == kind
    )


def summarize_samples(samples: list[dict[str, Any]]) -> dict[str, Any]:
    complete = [sample for sample in samples if sample["scenario"] == "complete"]
    replacement = [sample for sample in samples if sample["scenario"] == "identity-replacement"]
    require(len(complete) == 5 and len(replacement) == 5, "scenario sample count drifted")
    return {
        "complete": {
            "sampleCount": len(complete),
            "networkChunkCount": integer_statistics([len(sample["networkChunks"]) for sample in complete]),
            "fullBodyReceivedElapsedNanoseconds": integer_statistics(
                [sample["networkChunks"][-1]["elapsedNanoseconds"] for sample in complete]
            ),
            "generatedPreviewCount": integer_statistics([len(sample["generatedPreviews"]) for sample in complete]),
            "firstPreviewGeneratedElapsedNanoseconds": integer_statistics(
                [sample["generatedPreviews"][0]["elapsedNanoseconds"] for sample in complete]
            ),
            "firstPreviewDisplayLinkObservedElapsedNanoseconds": integer_statistics(
                [first_display(sample, "preview") for sample in complete]
            ),
            "firstPreviewDisplayLinkDelayNanoseconds": integer_statistics(
                [
                    first_display(sample, "preview")
                    - sample["generatedPreviews"][0]["elapsedNanoseconds"]
                    for sample in complete
                ]
            ),
            "finalEmittedElapsedNanoseconds": integer_statistics(
                [sample["finalEmittedElapsedNanoseconds"] for sample in complete]
            ),
            "finalDisplayLinkObservedElapsedNanoseconds": integer_statistics(
                [first_display(sample, "final") for sample in complete]
            ),
            "finalDisplayLinkDelayNanoseconds": integer_statistics(
                [
                    first_display(sample, "final") - sample["finalEmittedElapsedNanoseconds"]
                    for sample in complete
                ]
            ),
            "progressiveVisibleWindowNanoseconds": integer_statistics(
                [first_display(sample, "final") - first_display(sample, "preview") for sample in complete]
            ),
            "generationSequences": [
                [event["generation"] for event in sample["generatedPreviews"]]
                for sample in complete
            ],
            "generationSourceByteCounts": [
                [event["sourceByteCount"] for event in sample["generatedPreviews"]]
                for sample in complete
            ],
            "displayedGenerationSequences": [
                [
                    event["generation"]
                    for event in sample["displayObservations"]
                    if event["kind"] == "preview"
                ]
                for sample in complete
            ],
        },
        "identityReplacement": {
            "sampleCount": len(replacement),
            "networkReceivedByteCount": integer_statistics(
                [sample["networkChunks"][-1]["cumulativeByteCount"] for sample in replacement]
            ),
            "publicationFenceClosedElapsedNanoseconds": integer_statistics(
                [sample["publicationFenceClosedElapsedNanoseconds"] for sample in replacement]
            ),
            "suppressionElapsedNanoseconds": integer_statistics(
                [sample["suppressedPreviews"][0]["elapsedNanoseconds"] for sample in replacement]
            ),
            "suppressionAfterFenceNanoseconds": integer_statistics(
                [
                    sample["suppressedPreviews"][0]["elapsedNanoseconds"]
                    - sample["publicationFenceClosedElapsedNanoseconds"]
                    for sample in replacement
                ]
            ),
            "oldPreviewObservedAfterReplacementCount": sum(
                1 for sample in replacement if sample["oldPreviewObservedAfterReplacement"]
            ),
        },
    }


def repository_has_git_history() -> bool:
    completed = subprocess.run(
        ["git", "rev-parse", "--is-inside-work-tree"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    return completed.returncode == 0 and completed.stdout.strip() == "true"


def git_bytes(*arguments: str) -> bytes:
    return subprocess.run(
        ["git", *arguments],
        cwd=ROOT,
        check=True,
        capture_output=True,
    ).stdout


def validate(path: Path) -> None:
    evidence = json.loads(path.read_text(encoding="utf-8"))
    require(evidence.get("schemaVersion") == 1, "evidence schema drifted")
    require(evidence.get("evidenceID") == EXPECTED_EVIDENCE_ID, "evidence identity drifted")
    require(evidence.get("status") == "clean-simulator-host-evidence-completed-production-streaming-gap", "evidence status drifted")
    source = evidence.get("sourceIdentity", {})
    require(source.get("foveaCommit") == EXPECTED_COMMIT, "measured commit drifted")
    require(source.get("foveaTree") == EXPECTED_TREE, "measured tree drifted")
    require(source.get("includesWorkingTreeChanges") is False, "measured source was dirty")
    require(source.get("imageCraftRevision") == EXPECTED_IMAGECRAFT, "ImageCraft pin drifted")
    require(source.get("akashicRevision") == EXPECTED_AKASHIC, "Akashic pin drifted")
    fixture = source.get("fixture", {})
    require(fixture.get("path") == FIXTURE_PATH, "fixture path drifted")
    require(fixture.get("sha256") == FIXTURE_SHA256, "fixture digest drifted")
    require(fixture.get("byteCount") == FIXTURE_BYTE_COUNT, "fixture byte count drifted")
    fixture_path = ROOT / FIXTURE_PATH
    require(fixture_path.is_file(), "fixture is missing")
    require(fixture_path.stat().st_size == FIXTURE_BYTE_COUNT, "current fixture byte count drifted")
    require(sha256_bytes(fixture_path.read_bytes()) == FIXTURE_SHA256, "current fixture digest drifted")

    if repository_has_git_history():
        tree = git_bytes("rev-parse", f"{EXPECTED_COMMIT}^{{tree}}").decode().strip()
        require(tree == EXPECTED_TREE, "Git commit tree does not match evidence")
        fixture_at_commit = git_bytes("show", f"{EXPECTED_COMMIT}:{FIXTURE_PATH}")
        require(len(fixture_at_commit) == FIXTURE_BYTE_COUNT, "measured fixture size drifted")
        require(sha256_bytes(fixture_at_commit) == FIXTURE_SHA256, "measured fixture digest drifted")

    method = evidence.get("methodIdentity", {})
    require(method.get("labID") == "fovea-progressive-presentation-simulator-v2", "lab method drifted")
    require(method.get("iterationsPerTest") == 5, "iteration count drifted")
    require(method.get("testExecutionCount") == 10, "test execution count drifted")
    require(method.get("presentationBoundary") == "CADisplayLink observation, not Core Animation/GPU/physical scanout", "presentation boundary drifted")

    execution = evidence.get("execution", {})
    require(execution.get("result") == "Passed", "lab result failed")
    require(execution.get("passedUniqueTests") == 2, "unique test count drifted")
    require(execution.get("passedTestExecutions") == 10, "passed execution count drifted")
    require(execution.get("evidenceSampleCount") == 10, "sample count drifted")
    require(execution.get("scenarioCounts") == {"complete": 5, "identity-replacement": 5}, "scenario counts drifted")

    samples = evidence.get("samples")
    require(isinstance(samples, list) and len(samples) == 10, "embedded samples drifted")
    for sample in samples:
        validate_sample(sample)
    recomputed = summarize_samples(samples)
    require(evidence.get("summary") == recomputed, "embedded summary is not reproducible")

    artifacts = evidence.get("capturedArtifactDigests", {})
    for name in ("rawReportSHA256", "xcresultSummarySHA256", "xcodebuildLogSHA256"):
        value = artifacts.get(name)
        require(isinstance(value, str) and len(value) == 64, f"artifact digest missing: {name}")
    require(isinstance(artifacts.get("xcresultBundleByteCount"), int) and artifacts["xcresultBundleByteCount"] > 0, "xcresult size missing")

    boundary = evidence.get("claimBoundary", {})
    require(boundary.get("productionStreamingSupported") is False, "evidence overclaims production streaming")
    require(boundary.get("physicalPresentationMeasured") is False, "evidence overclaims physical presentation")
    require(boundary.get("releasePerformanceClaimPermitted") is False, "evidence overclaims release performance")
    require(evidence.get("findings"), "findings are missing")
    require(evidence.get("remainingEvidence"), "remaining evidence is missing")
    print(f"Progressive presentation evidence passed: {path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    arguments = parser.parse_args()
    validate(arguments.evidence)


if __name__ == "__main__":
    main()
