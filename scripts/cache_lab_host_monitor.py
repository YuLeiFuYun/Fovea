#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import os
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

BUILD_DRIVERS = {
    "swift-build",
    "swift-test",
    "swift-run",
    "xcodebuild",
}
ACTIVE_COMPILERS = {
    "swift-frontend",
    "swiftc",
    "clang",
    "clang++",
    "ld",
    "ld64",
}
POLICY_SCHEMA_VERSION = 3
POLICY_ID = "external-compiler-process-block-v3"


@dataclass(frozen=True)
class ProcessRecord:
    pid: int
    parent_pid: int
    cpu_percent: float
    executable: str
    command_digest: str


def _basename(value: str) -> str:
    return Path(value).name


def parse_process_listing(output: str) -> list[ProcessRecord]:
    records: list[ProcessRecord] = []
    for line in output.splitlines():
        fields = line.strip().split(maxsplit=4)
        if len(fields) < 5:
            continue
        try:
            pid = int(fields[0])
            parent_pid = int(fields[1])
            cpu_percent = float(fields[2])
        except ValueError:
            continue
        command = fields[4]
        command_executable = _basename(command.split(maxsplit=1)[0])
        comm_executable = _basename(fields[3])
        executable = (
            command_executable
            if command_executable in BUILD_DRIVERS | ACTIVE_COMPILERS
            else comm_executable
        )
        is_driver = executable in BUILD_DRIVERS
        is_active_compiler = executable in ACTIVE_COMPILERS and cpu_percent >= 0.5
        if not is_driver and not is_active_compiler:
            continue
        command_digest = hashlib.sha256(fields[4].encode()).hexdigest()
        records.append(
            ProcessRecord(
                pid=pid,
                parent_pid=parent_pid,
                cpu_percent=cpu_percent,
                executable=executable,
                command_digest=command_digest,
            )
        )
    return records


def compiler_processes() -> list[ProcessRecord]:
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,pcpu=,comm=,command="],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return parse_process_listing(result.stdout)


def summarized_processes(records: list[ProcessRecord]) -> list[dict[str, Any]]:
    # Paths and full commands are intentionally excluded from shareable evidence.
    unique: dict[tuple[str, str], ProcessRecord] = {}
    for record in records:
        unique[(record.executable, record.command_digest)] = record
    return [
        {
            "executable": record.executable,
            "commandDigest": record.command_digest,
        }
        for record in sorted(unique.values(), key=lambda item: (item.executable, item.command_digest))
    ]


def wait_for_quiescence(
    *,
    required_clean_samples: int,
    sample_interval_seconds: float,
    timeout_seconds: float,
) -> dict[str, Any]:
    started = time.monotonic()
    clean_samples = 0
    observed_samples = 0
    observed_external: list[ProcessRecord] = []
    while time.monotonic() - started < timeout_seconds:
        observed_samples += 1
        external = compiler_processes()
        if external:
            clean_samples = 0
            observed_external.extend(external)
        else:
            clean_samples += 1
            if clean_samples >= required_clean_samples:
                return {
                    "requiredCleanSamples": required_clean_samples,
                    "observedConsecutiveCleanSamples": clean_samples,
                    "observedSamples": observed_samples,
                    "sampleIntervalMilliseconds": int(sample_interval_seconds * 1000),
                    "timeoutSeconds": timeout_seconds,
                    "passed": True,
                    "externalProcesses": summarized_processes(observed_external),
                }
        time.sleep(sample_interval_seconds)
    return {
        "requiredCleanSamples": required_clean_samples,
        "observedConsecutiveCleanSamples": clean_samples,
        "observedSamples": observed_samples,
        "sampleIntervalMilliseconds": int(sample_interval_seconds * 1000),
        "timeoutSeconds": timeout_seconds,
        "passed": False,
        "externalProcesses": summarized_processes(observed_external),
    }


def run_monitored(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    log_path: Path,
    timeout_seconds: float,
    sample_interval_seconds: float,
    abort_on_contamination: bool,
) -> tuple[int, dict[str, Any]]:
    started = time.monotonic()
    samples = 0
    contaminated_samples = 0
    observed_external: list[ProcessRecord] = []
    timed_out = False
    aborted_for_contamination = False
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as stream:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            env=env,
            text=True,
            stdout=stream,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        while True:
            return_code = process.poll()
            if return_code is not None:
                break
            samples += 1
            external = compiler_processes()
            if external:
                contaminated_samples += 1
                observed_external.extend(external)
                if abort_on_contamination:
                    aborted_for_contamination = True
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        return_code = process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        return_code = process.wait(timeout=5)
                    break
            if time.monotonic() - started >= timeout_seconds:
                timed_out = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    return_code = process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    return_code = process.wait(timeout=5)
                break
            time.sleep(sample_interval_seconds)

    evidence = {
        "coveredEntireRunner": True,
        "sampleCount": samples,
        "contaminatedSampleCount": contaminated_samples,
        "sampleIntervalMilliseconds": int(sample_interval_seconds * 1000),
        "durationMilliseconds": int((time.monotonic() - started) * 1000),
        "contaminated": contaminated_samples > 0,
        "abortedForContamination": aborted_for_contamination,
        "timedOut": timed_out,
        "externalProcesses": summarized_processes(observed_external),
    }
    return int(return_code or 0), evidence


def aggregate_monitors(monitors: list[dict[str, Any]]) -> dict[str, Any]:
    external: dict[tuple[str, str], dict[str, Any]] = {}
    for item in monitors:
        for process in item.get("externalProcesses", []):
            if isinstance(process, dict):
                executable = process.get("executable")
                digest = process.get("commandDigest")
                if isinstance(executable, str) and isinstance(digest, str):
                    external[(executable, digest)] = {
                        "executable": executable,
                        "commandDigest": digest,
                    }
    contaminated_samples = sum(
        int(item.get("contaminatedSampleCount", 0)) for item in monitors
    )
    return {
        "coveredEntireRunner": all(
            item.get("coveredEntireRunner") is True for item in monitors
        ),
        "sampleCount": sum(int(item.get("sampleCount", 0)) for item in monitors),
        "contaminatedSampleCount": contaminated_samples,
        "sampleIntervalMilliseconds": (
            monitors[0].get("sampleIntervalMilliseconds") if monitors else 1000
        ),
        "durationMilliseconds": sum(
            int(item.get("durationMilliseconds", 0)) for item in monitors
        ),
        "contaminated": contaminated_samples > 0,
        "abortedForContamination": any(
            item.get("abortedForContamination") is True for item in monitors
        ),
        "timedOut": any(item.get("timedOut") is True for item in monitors),
        "externalProcesses": [external[key] for key in sorted(external)],
    }


def _valid_preflight(
    value: Any,
    *,
    required_minimum: int,
    sample_interval_milliseconds: int,
) -> bool:
    if not isinstance(value, dict):
        return False
    required = value.get("requiredCleanSamples")
    observed_clean = value.get("observedConsecutiveCleanSamples")
    observed = value.get("observedSamples")
    return (
        isinstance(value.get("passed"), bool)
        and isinstance(required, int)
        and required >= required_minimum
        and isinstance(observed_clean, int)
        and observed_clean >= 0
        and isinstance(observed, int)
        and observed >= observed_clean
        and (not value["passed"] or observed_clean >= required)
        and value.get("sampleIntervalMilliseconds")
        == sample_interval_milliseconds
        and isinstance(value.get("externalProcesses"), list)
    )


def _valid_monitor(
    value: Any,
    *,
    sample_interval_milliseconds: int,
    require_sample: bool,
) -> bool:
    if not isinstance(value, dict):
        return False
    samples = value.get("sampleCount")
    contaminated_samples = value.get("contaminatedSampleCount")
    return (
        value.get("coveredEntireRunner") is True
        and isinstance(samples, int)
        and samples >= (1 if require_sample else 0)
        and isinstance(contaminated_samples, int)
        and 0 <= contaminated_samples <= samples
        and value.get("sampleIntervalMilliseconds")
        == sample_interval_milliseconds
        and isinstance(value.get("durationMilliseconds"), int)
        and value["durationMilliseconds"] >= 0
        and isinstance(value.get("contaminated"), bool)
        and value["contaminated"] == (contaminated_samples > 0)
        and isinstance(value.get("abortedForContamination"), bool)
        and isinstance(value.get("timedOut"), bool)
        and isinstance(value.get("externalProcesses"), list)
    )


def validate_host_execution_evidence(
    value: Any,
    *,
    policy: dict[str, Any],
    formal: bool,
    expected_repetitions: int,
) -> tuple[bool, bool]:
    if not isinstance(value, dict):
        return False, False
    if (
        value.get("schemaVersion") != policy.get("schemaVersion")
        or value.get("policyID") != policy.get("policyID")
    ):
        return False, False
    runner = value.get("runnerExecution")
    preflight = value.get("preflight")
    if not isinstance(runner, dict):
        return False, False
    interval = int(policy.get("sampleIntervalMilliseconds", 0))
    required_minimum = (
        int(policy.get("formalRequiredConsecutiveCleanSamples", 0))
        if formal
        else 0
    )
    if not _valid_preflight(
        preflight,
        required_minimum=required_minimum,
        sample_interval_milliseconds=interval,
    ):
        return False, False
    if (
        runner.get("directBinary") is not True
        or runner.get("buildExcludedFromMeasurement") is not True
        or not isinstance(runner.get("completed"), bool)
        or not isinstance(value.get("quiescentHostBound"), bool)
    ):
        return False, False

    if not formal:
        monitor = value.get("monitor")
        bound = (
            runner.get("processModel") == "single-calibration-process"
            and _valid_monitor(
                monitor,
                sample_interval_milliseconds=interval,
                require_sample=False,
            )
        )
        if not bound:
            return False, False
        quiescent = (
            value["quiescentHostBound"] is True
            and runner["completed"] is True
            and preflight["passed"] is True
            and monitor["contaminated"] is False
            and monitor["timedOut"] is False
        )
        return True, quiescent

    correctness = value.get("correctness")
    accepted_blocks = value.get("acceptedBlocks")
    rejected_attempts = value.get("rejectedAttempts")
    recovery_preflights = value.get("recoveryPreflights")
    aggregate = value.get("monitor")
    if (
        runner.get("processModel") != "independent-process-per-resampling-unit"
        or runner.get("acceptedBlockCount") != expected_repetitions
        or not isinstance(correctness, dict)
        or not isinstance(accepted_blocks, list)
        or not isinstance(rejected_attempts, list)
        or not isinstance(recovery_preflights, list)
    ):
        return False, False
    correctness_monitor = correctness.get("monitor")
    if (
        not isinstance(correctness.get("attempt"), int)
        or correctness["attempt"] < 1
        or not _valid_monitor(
            correctness_monitor,
            sample_interval_milliseconds=interval,
            require_sample=True,
        )
    ):
        return False, False
    repetitions: set[int] = set()
    accepted_monitors: list[dict[str, Any]] = [correctness_monitor]
    for block in accepted_blocks:
        if not isinstance(block, dict):
            return False, False
        repetition = block.get("repetition")
        monitor = block.get("monitor")
        if (
            not isinstance(repetition, int)
            or repetition < 0
            or repetition in repetitions
            or not isinstance(block.get("attempt"), int)
            or block["attempt"] < 1
            or not _valid_monitor(
                monitor,
                sample_interval_milliseconds=interval,
                require_sample=True,
            )
        ):
            return False, False
        repetitions.add(repetition)
        accepted_monitors.append(monitor)
    if repetitions != set(range(expected_repetitions)):
        return False, False
    for preflight_item in recovery_preflights:
        if not _valid_preflight(
            preflight_item,
            required_minimum=required_minimum,
            sample_interval_milliseconds=interval,
        ):
            return False, False
    for attempt in rejected_attempts:
        if not isinstance(attempt, dict):
            return False, False
        monitor = attempt.get("monitor")
        if (
            attempt.get("phase") not in {"correctness", "block"}
            or not isinstance(attempt.get("attempt"), int)
            or attempt["attempt"] < 1
            or not _valid_monitor(
                monitor,
                sample_interval_milliseconds=interval,
                require_sample=True,
            )
        ):
            return False, False
    expected_aggregate = aggregate_monitors(accepted_monitors)
    if aggregate != expected_aggregate:
        return False, False
    clean_accepted = all(
        monitor["contaminated"] is False and monitor["timedOut"] is False
        for monitor in accepted_monitors
    )
    quiescent = (
        value["quiescentHostBound"] is True
        and runner["completed"] is True
        and preflight["passed"] is True
        and clean_accepted
        and aggregate["contaminated"] is False
        and aggregate["timedOut"] is False
    )
    return True, quiescent
