#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / ".artifacts/progressive-presentation-simulator"
TEST_CLASS = "FoveaTests/ProgressivePresentationHostTests"
TEST_METHODS = [
    "testChunkedURLSessionPreviewReachesDisplayLinkBeforeFinal_UI_PT_029",
    "testIdentityReplacementClosesPublicationFenceBeforeOldPreview_UI_PT_030",
]
EVIDENCE_PREFIX = "FOVEA_PROGRESSIVE_HOST_EVIDENCE_BASE64:"


def run(*args: str, check: bool = True, capture: bool = True, env: dict[str, str] | None = None):
    return subprocess.run(
        list(args), cwd=ROOT, check=check, text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
        env=env,
    )


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_output(*args: str) -> str:
    return run("git", *args).stdout.strip()


def package_revision(identity: str) -> str:
    data = json.loads((ROOT / "Package.resolved").read_text())
    pin = next(x for x in data["pins"] if x["identity"] == identity)
    return pin["state"]["revision"]



def integer_statistics(values: list[int]) -> dict[str, int]:
    ordered = sorted(values)
    if not ordered:
        raise AssertionError("duration sample set is empty")
    rank = max(1, (len(ordered) * 90 + 99) // 100)
    return {
        "minimum": ordered[0],
        "median": (ordered[(len(ordered) - 1) // 2] + ordered[len(ordered) // 2]) // 2,
        "p90": ordered[min(len(ordered) - 1, rank - 1)],
        "maximum": ordered[-1],
        "mean": sum(ordered) // len(ordered),
    }


def validate_evidence_sample(sample: dict[str, object]) -> None:
    if sample.get("schemaVersion") != 1:
        raise AssertionError("progressive host sample schema mismatch")
    source = sample.get("source")
    if not isinstance(source, dict) or source.get("byteCount") != 370_199:
        raise AssertionError("progressive host source identity mismatch")
    network = sample.get("networkChunks")
    generated = sample.get("generatedPreviews")
    emitted = sample.get("emittedPreviews")
    suppressed = sample.get("suppressedPreviews")
    displays = sample.get("displayObservations")
    if not all(isinstance(value, list) for value in (network, generated, emitted, suppressed, displays)):
        raise AssertionError("progressive host sample arrays are missing")
    if [event["index"] for event in network] != list(range(len(network))):
        raise AssertionError("network chunk sequence is not contiguous")
    cumulative = [event["cumulativeByteCount"] for event in network]
    if cumulative != sorted(set(cumulative)):
        raise AssertionError("network cumulative byte count is not strict")
    generations = [event["generation"] for event in generated]
    source_counts = [event["sourceByteCount"] for event in generated]
    if generations != sorted(set(generations)) or source_counts != sorted(set(source_counts)):
        raise AssertionError("generated preview order is not strict")

    scenario = sample.get("scenario")
    if scenario == "complete":
        if not network or cumulative[-1] != source["byteCount"]:
            raise AssertionError("complete scenario did not receive the full body")
        generated_identity = [
            (event["generation"], event["sourceByteCount"]) for event in generated
        ]
        emitted_identity = [
            (event["generation"], event["sourceByteCount"]) for event in emitted
        ]
        if len(generated) < 2 or emitted_identity != generated_identity or suppressed:
            raise AssertionError("complete scenario preview publication mismatch")
        if sample.get("finalEmittedElapsedNanoseconds") is None:
            raise AssertionError("complete scenario did not emit final pixels")
        if sample.get("previewDisplayedBeforeFinal") is not True:
            raise AssertionError("CADisplayLink did not observe preview before final")
        kinds = [event["kind"] for event in displays]
        if "preview" not in kinds or "final" not in kinds:
            raise AssertionError("complete scenario display observations are incomplete")
        if sample.get("publicationFenceClosedElapsedNanoseconds") is not None:
            raise AssertionError("complete scenario unexpectedly closed publication fence")
    elif scenario == "identity-replacement":
        if len(generated) != 1 or emitted or len(suppressed) != 1:
            raise AssertionError("identity replacement suppression cardinality mismatch")
        if sample.get("finalEmittedElapsedNanoseconds") is not None:
            raise AssertionError("old identity emitted final pixels")
        if sample.get("publicationFenceBeforeSuppression") is not True:
            raise AssertionError("publication fence did not precede suppression")
        if sample.get("oldPreviewObservedAfterReplacement") is not False:
            raise AssertionError("old preview reached display after replacement")
    else:
        raise AssertionError(f"unknown progressive host scenario: {scenario}")


def summarize_evidence(samples: list[dict[str, object]]) -> dict[str, object]:
    complete = [sample for sample in samples if sample["scenario"] == "complete"]
    replacement = [sample for sample in samples if sample["scenario"] == "identity-replacement"]

    def first_display(sample: dict[str, object], kind: str) -> int:
        return next(
            event["elapsedNanoseconds"]
            for event in sample["displayObservations"]
            if event["kind"] == kind
        )

    return {
        "complete": {
            "sampleCount": len(complete),
            "networkChunkCount": integer_statistics(
                [len(sample["networkChunks"]) for sample in complete]
            ),
            "generatedPreviewCount": integer_statistics(
                [len(sample["generatedPreviews"]) for sample in complete]
            ),
            "firstPreviewGeneratedElapsed": integer_statistics(
                [sample["generatedPreviews"][0]["elapsedNanoseconds"] for sample in complete]
            ),
            "firstPreviewDisplayLinkObservedElapsed": integer_statistics(
                [first_display(sample, "preview") for sample in complete]
            ),
            "finalEmittedElapsed": integer_statistics(
                [sample["finalEmittedElapsedNanoseconds"] for sample in complete]
            ),
            "finalDisplayLinkObservedElapsed": integer_statistics(
                [first_display(sample, "final") for sample in complete]
            ),
            "generationSequences": [
                [event["generation"] for event in sample["generatedPreviews"]]
                for sample in complete
            ],
            "generationSourceByteCounts": [
                [event["sourceByteCount"] for event in sample["generatedPreviews"]]
                for sample in complete
            ],
        },
        "identityReplacement": {
            "sampleCount": len(replacement),
            "networkReceivedByteCount": integer_statistics(
                [sample["networkChunks"][-1]["cumulativeByteCount"] for sample in replacement]
            ),
            "publicationFenceClosedElapsed": integer_statistics(
                [sample["publicationFenceClosedElapsedNanoseconds"] for sample in replacement]
            ),
            "suppressionElapsed": integer_statistics(
                [sample["suppressedPreviews"][0]["elapsedNanoseconds"] for sample in replacement]
            ),
            "suppressionAfterFence": integer_statistics(
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

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 20:
        parser.error("--iterations must be between 1 and 20")

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    result_bundle = output / "ProgressivePresentationHost.xcresult"
    log_path = output / "xcodebuild.log"
    summary_path = output / "xcresult-summary.json"
    report_path = output / "report.json"
    if result_bundle.exists():
        shutil.rmtree(result_bundle)

    developer = run(str(ROOT / "scripts/select-xcode.sh")).stdout.strip()
    simulator = run(sys.executable, str(ROOT / "scripts/select-ios-simulator.py")).stdout.strip()
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = developer
    command = [
        "xcodebuild", "-scheme", "Fovea-Package",
        "-destination", f"platform=iOS Simulator,id={simulator}",
        "-collect-test-diagnostics", "never",
        "-resultBundlePath", str(result_bundle),
    ]
    if args.iterations > 1:
        command.extend([
            "-test-iterations", str(args.iterations),
            "-test-repetition-relaunch-enabled", "YES",
        ])
    command.extend([
        "APPINTENTS_METADATA_PROCESSING_ENABLED=NO",
        f"-only-testing:{TEST_CLASS}", "test",
    ])
    completed = run(*command, check=False, env=env)
    log_path.write_text(completed.stdout)
    if not result_bundle.exists():
        print(completed.stdout[-4000:], file=sys.stderr)
        return completed.returncode or 1

    summary_text = run(
        "xcrun", "xcresulttool", "get", "test-results", "summary",
        "--path", str(result_bundle), "--format", "json", env=env,
    ).stdout
    summary_path.write_text(summary_text)
    summary = json.loads(summary_text)
    expected_unique = len(TEST_METHODS)
    expected_executions = expected_unique * args.iterations
    passed_unique = summary.get("passedTests")
    result = summary.get("result")
    execution_pattern = re.compile(
        r"Test Case '-\[FoveaTests\.ProgressivePresentationHostTests "
        r"(?:" + "|".join(re.escape(method) for method in TEST_METHODS) + r")\]' passed"
    )
    passed_executions = len(execution_pattern.findall(completed.stdout))
    encoded_samples = re.findall(
        re.escape(EVIDENCE_PREFIX) + r"([A-Za-z0-9+/=]+)",
        completed.stdout,
    )
    evidence_samples = [
        json.loads(base64.b64decode(value).decode("utf-8"))
        for value in encoded_samples
    ]
    for sample in evidence_samples:
        validate_evidence_sample(sample)
    scenario_counts = {
        scenario: sum(1 for sample in evidence_samples if sample["scenario"] == scenario)
        for scenario in ("complete", "identity-replacement")
    }
    evidence_valid = (
        len(evidence_samples) == expected_executions
        and scenario_counts["complete"] == args.iterations
        and scenario_counts["identity-replacement"] == args.iterations
    )
    worktree = git_output("status", "--porcelain")
    report = {
        "schemaVersion": 2,
        "labID": "fovea-progressive-presentation-simulator-v2",
        "capturedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "boundary": (
            "URLSessionDataDelegate -> ImageCraft progressive session -> "
            "FoveaImageView identity/publication fence -> CADisplayLink observation; "
            "CADisplayLink callback is not Core Animation/GPU scanout proof"
        ),
        "command": command,
        "iterationsPerTest": args.iterations,
        "expectedUniqueTests": expected_unique,
        "expectedTestExecutions": expected_executions,
        "testClass": TEST_CLASS,
        "testMethods": TEST_METHODS,
        "result": result,
        "passedUniqueTests": passed_unique,
        "passedTestExecutions": passed_executions,
        "evidenceSampleCount": len(evidence_samples),
        "scenarioCounts": scenario_counts,
        "samples": evidence_samples,
        "evidenceSummary": summarize_evidence(evidence_samples) if evidence_valid else None,
        "failedTests": summary.get("failedTests"),
        "skippedTests": summary.get("skippedTests"),
        "devicesAndConfigurations": summary.get("devicesAndConfigurations"),
        "environmentDescription": summary.get("environmentDescription"),
        "foveaCommit": git_output("rev-parse", "HEAD"),
        "foveaTree": git_output("rev-parse", "HEAD^{tree}"),
        "includesWorkingTreeChanges": bool(worktree),
        "workingTreeStatus": worktree.splitlines(),
        "imageCraftRevision": package_revision("imagecraft"),
        "akashicRevision": package_revision("akashic"),
        "xcodeVersion": run("xcodebuild", "-version", env=env).stdout.strip(),
        "swiftVersion": run("xcrun", "swift", "--version", env=env).stdout.strip(),
        "artifacts": {
            "xcodebuildLog": {"path": str(log_path), "sha256": sha256(log_path)},
            "xcresultSummary": {"path": str(summary_path), "sha256": sha256(summary_path)},
            "xcresultBundle": {"path": str(result_bundle)},
        },
        "claims": {
            "supported": [
                "A URLSession delegate can feed ImageCraft progressive JPEG generations into FoveaImageView.",
                "CADisplayLink observes at least one preview identity before the final identity in the retained scenario.",
                "Closing the publication fence before cancellation suppresses a generated old-identity preview.",
            ],
            "unsupported": [
                "Physical display scanout or GPU presentation latency.",
                "Production URLSessionTransport streaming support.",
                "Cross-device performance, energy, or universal generation counts.",
            ],
        },
    }
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "Progressive presentation lab: "
        f"{result}, unique={passed_unique}/{expected_unique}, "
        f"executions={passed_executions}/{expected_executions}"
    )
    print(f"Report: {report_path} sha256:{sha256(report_path)}")
    if (
        completed.returncode != 0
        or result != "Passed"
        or passed_unique != expected_unique
        or passed_executions != expected_executions
        or not evidence_valid
    ):
        print(completed.stdout[-8000:], file=sys.stderr)
        return completed.returncode or 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
