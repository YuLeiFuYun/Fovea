#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

import cache_lab_host_monitor as monitor


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def record(executable: str = "swift-build") -> monitor.ProcessRecord:
    return monitor.ProcessRecord(
        pid=123,
        parent_pid=1,
        cpu_percent=10.0,
        executable=executable,
        command_digest="a" * 64,
    )


def test_policy_matches_preregistered_plan() -> None:
    root = Path(__file__).resolve().parents[1]
    plan = json.loads((root / "Benchmarks/CacheLab/cache-plan.json").read_text())
    policy = plan["hostExecutionPolicy"]
    require(
        monitor.POLICY_SCHEMA_VERSION == policy["schemaVersion"],
        "host monitor schema must match the preregistered plan",
    )
    require(
        monitor.POLICY_ID == policy["policyID"],
        "host monitor policy ID must match the preregistered plan",
    )


def test_truncated_comm_uses_full_command_executable() -> None:
    listing = (
        "18532 1 0.0 /Applications/Xc "
        "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild "
        "-scheme Afferent-Package\n"
        "18533 1 0.0 /bin/zsh /bin/zsh -f -c echo xcodebuild\n"
        "18534 1 4.2 /Applications/Xc "
        "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/"
        "XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend -c a.swift\n"
    )
    records = monitor.parse_process_listing(listing)
    require(
        [item.executable for item in records] == ["xcodebuild", "swift-frontend"],
        "full command executable must recover truncated ps comm values without matching shell text",
    )


def test_quiescence_state_machine() -> None:
    original = monitor.compiler_processes
    try:
        samples = iter([[record()], [], []])
        monitor.compiler_processes = lambda: next(samples)
        passed = monitor.wait_for_quiescence(
            required_clean_samples=2,
            sample_interval_seconds=0,
            timeout_seconds=1,
        )
        require(passed["passed"], "two consecutive clean samples must pass")
        require(
            passed["observedConsecutiveCleanSamples"] == 2,
            "clean samples must be consecutive",
        )
        require(
            passed["externalProcesses"]
            == [{"executable": "swift-build", "commandDigest": "a" * 64}],
            "shareable evidence must retain only executable and command digest",
        )

        monitor.compiler_processes = lambda: [record("xcodebuild")]
        failed = monitor.wait_for_quiescence(
            required_clean_samples=1,
            sample_interval_seconds=0.001,
            timeout_seconds=0.01,
        )
        require(not failed["passed"], "persistent build activity must fail preflight")
    finally:
        monitor.compiler_processes = original


def test_monitor_aborts_on_contamination() -> None:
    original = monitor.compiler_processes
    try:
        monitor.compiler_processes = lambda: [record("swift-frontend")]
        with tempfile.TemporaryDirectory(prefix="cache-lab-monitor-") as directory:
            log = Path(directory) / "runner.log"
            return_code, evidence = monitor.run_monitored(
                ["/bin/sleep", "5"],
                cwd=Path(directory),
                env=os.environ.copy(),
                log_path=log,
                timeout_seconds=10,
                sample_interval_seconds=0.01,
                abort_on_contamination=True,
            )
        require(return_code != 0, "contaminated runner must be terminated")
        require(evidence["contaminated"], "contamination must be recorded")
        require(
            evidence["abortedForContamination"],
            "formal monitor must identify contamination abort",
        )
        require(not evidence["timedOut"], "contamination abort is not a timeout")
    finally:
        monitor.compiler_processes = original


def clean_monitor() -> dict[str, object]:
    return {
        "coveredEntireRunner": True,
        "sampleCount": 2,
        "contaminatedSampleCount": 0,
        "sampleIntervalMilliseconds": 1000,
        "durationMilliseconds": 1200,
        "contaminated": False,
        "abortedForContamination": False,
        "timedOut": False,
        "externalProcesses": [],
    }


def formal_campaign_evidence() -> tuple[dict[str, object], dict[str, object]]:
    root = Path(__file__).resolve().parents[1]
    policy = json.loads((root / "Benchmarks/CacheLab/cache-plan.json").read_text())[
        "hostExecutionPolicy"
    ]
    correctness_monitor = clean_monitor()
    accepted = [
        {"repetition": index, "attempt": 1, "monitor": clean_monitor()}
        for index in range(20)
    ]
    aggregate = monitor.aggregate_monitors(
        [correctness_monitor] + [item["monitor"] for item in accepted]
    )
    evidence: dict[str, object] = {
        "schemaVersion": policy["schemaVersion"],
        "policyID": policy["policyID"],
        "runnerExecution": {
            "directBinary": True,
            "buildExcludedFromMeasurement": True,
            "completed": True,
            "processModel": "independent-process-per-resampling-unit",
            "acceptedBlockCount": 20,
        },
        "preflight": {
            "requiredCleanSamples": 10,
            "observedConsecutiveCleanSamples": 10,
            "observedSamples": 10,
            "sampleIntervalMilliseconds": 1000,
            "timeoutSeconds": 120,
            "passed": True,
            "externalProcesses": [],
        },
        "correctness": {"attempt": 1, "monitor": correctness_monitor},
        "acceptedBlocks": accepted,
        "rejectedAttempts": [
            {
                "phase": "block",
                "repetition": 7,
                "attempt": 1,
                "monitor": {
                    **clean_monitor(),
                    "contaminatedSampleCount": 1,
                    "contaminated": True,
                    "abortedForContamination": True,
                    "externalProcesses": [
                        {"executable": "swift-test", "commandDigest": "b" * 64}
                    ],
                },
            }
        ],
        "recoveryPreflights": [],
        "monitor": aggregate,
        "quiescentHostBound": True,
    }
    return evidence, policy


def test_formal_campaign_evidence() -> None:
    evidence, policy = formal_campaign_evidence()
    bound, clean = monitor.validate_host_execution_evidence(
        evidence, policy=policy, formal=True, expected_repetitions=20
    )
    require(bound and clean, "twenty clean process blocks must bind a formal campaign")

    missing = dict(evidence)
    missing["acceptedBlocks"] = list(evidence["acceptedBlocks"])[:-1]
    bound, _ = monitor.validate_host_execution_evidence(
        missing, policy=policy, formal=True, expected_repetitions=20
    )
    require(not bound, "a missing process block must invalidate the campaign")

    contaminated = json.loads(json.dumps(evidence))
    contaminated["acceptedBlocks"][3]["monitor"]["contaminatedSampleCount"] = 1
    contaminated["acceptedBlocks"][3]["monitor"]["contaminated"] = True
    contaminated["monitor"] = monitor.aggregate_monitors(
        [contaminated["correctness"]["monitor"]]
        + [item["monitor"] for item in contaminated["acceptedBlocks"]]
    )
    contaminated["quiescentHostBound"] = False
    bound, clean = monitor.validate_host_execution_evidence(
        contaminated, policy=policy, formal=True, expected_repetitions=20
    )
    require(bound and not clean, "a contaminated accepted block must block quiescent evidence")


def test_clean_short_runner() -> None:
    original = monitor.compiler_processes
    try:
        monitor.compiler_processes = lambda: []
        with tempfile.TemporaryDirectory(prefix="cache-lab-monitor-clean-") as directory:
            log = Path(directory) / "runner.log"
            return_code, evidence = monitor.run_monitored(
                ["/usr/bin/true"],
                cwd=Path(directory),
                env=os.environ.copy(),
                log_path=log,
                timeout_seconds=10,
                sample_interval_seconds=0.01,
                abort_on_contamination=True,
            )
        require(return_code == 0, "clean runner must complete")
        require(not evidence["contaminated"], "clean runner must remain uncontaminated")
        require(not evidence["timedOut"], "clean runner must not time out")
    finally:
        monitor.compiler_processes = original


def main() -> int:
    test_policy_matches_preregistered_plan()
    test_truncated_comm_uses_full_command_executable()
    test_quiescence_state_machine()
    test_monitor_aborts_on_contamination()
    test_formal_campaign_evidence()
    test_clean_short_runner()
    print("Cache Lab host monitor regression passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
