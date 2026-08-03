"""Simulator and Xcode phase execution for FoveaWorkbench verification."""
from __future__ import annotations

import json
import os
import plistlib
import re
import signal
import shutil
import subprocess
import sys
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, Sequence

from ios_example_process import digest, inactivity_expired, run, terminate_process_group

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "Examples/FoveaWorkbenchApp"
PROJECT = EXAMPLE / "FoveaWorkbench.xcodeproj"
ARTIFACTS = ROOT / ".artifacts/ios-example"
UI_TEST_SUITE_BASE_TIMEOUT_SECONDS = 1_200
UI_TEST_CASE_TIMEOUT_SECONDS = 180
UI_TEST_INACTIVITY_TIMEOUT_SECONDS = 240


@dataclass(frozen=True)
class PhaseAttempt:
    command: list[str]
    destination: str
    log: Path
    return_code: int
    output: str
    timed_out: bool
    stalled: bool


def test_count(output: str) -> int:
    counts = [int(value) for value in re.findall(r"Executed (\d+) tests?, with 0 failures", output)]
    return max(counts, default=0)


def ui_test_methods(source: Path) -> list[str]:
    methods = re.findall(
        r"^\s*func\s+(test[A-Za-z0-9_]*)\s*\(", source.read_text(), flags=re.MULTILINE
    )
    if not methods:
        raise RuntimeError(f"No UI test cases discovered in {source.relative_to(ROOT)}")
    if len(methods) != len(set(methods)):
        raise RuntimeError(f"Duplicate UI test methods discovered in {source.relative_to(ROOT)}")
    return methods


def ui_test_methods_in_files(sources: Sequence[Path]) -> list[str]:
    methods = [method for source in sources for method in ui_test_methods(source)]
    if len(methods) != len(set(methods)):
        raise RuntimeError("Duplicate UI test methods discovered across Workbench UI test files")
    return methods


def ui_test_case_count(source: Path) -> int:
    return len(ui_test_methods(source))


def balanced_shards(methods: list[str], shard_count: int) -> list[list[str]]:
    if not methods:
        raise ValueError("methods must not be empty")
    if shard_count < 1 or shard_count > len(methods):
        raise ValueError("shard_count must be between one and the method count")
    base, extra = divmod(len(methods), shard_count)
    shards: list[list[str]] = []
    offset = 0
    for index in range(shard_count):
        length = base + (1 if index < extra else 0)
        shards.append(methods[offset : offset + length])
        offset += length
    return shards


def ui_suite_timeout_seconds(source: Path, *, additional_test_cases: int = 0) -> int:
    if additional_test_cases < 0:
        raise ValueError("additional_test_cases must be nonnegative")
    return UI_TEST_SUITE_BASE_TIMEOUT_SECONDS + (
        ui_test_case_count(source) + additional_test_cases
    ) * UI_TEST_CASE_TIMEOUT_SECONDS


def xcode_environment() -> dict[str, str]:
    env = os.environ.copy()
    selected = subprocess.run(
        [str(ROOT / "scripts/select-xcode.sh")], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
    ).stdout.strip()
    env["DEVELOPER_DIR"] = selected
    return env


def simulator(env: dict[str, str], device_family: str) -> str:
    override_key = "FOVEA_IPAD_SIMULATOR_ID" if device_family == "ipad" else "FOVEA_IPHONE_SIMULATOR_ID"
    if identifier := env.get(override_key):
        return identifier
    command = [
        sys.executable, str(ROOT / "scripts/select-ios-simulator.py"),
        "--device-family", device_family,
    ]
    if runtime_version := env.get("FOVEA_IOS_RUNTIME_VERSION"):
        command.extend(["--runtime-version", runtime_version])

    initial_error: RuntimeError | None = None
    for attempt_index in range(2):
        completed = subprocess.run(
            command, cwd=ROOT, env=env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        identifier = completed.stdout.strip()
        if completed.returncode == 0 and identifier:
            return identifier
        detail = completed.stderr.strip() or identifier or f"exit {completed.returncode}"
        error = RuntimeError(
            f"{device_family} simulator discovery failed: {detail}"
        )
        if attempt_index == 0:
            initial_error = error
            try:
                recover_core_simulator_service(env)
            except RuntimeError as recovery_error:
                raise RuntimeError(
                    f"{error}; CoreSimulatorService recovery failed: {recovery_error}"
                ) from recovery_error
            continue
        raise RuntimeError(
            f"{device_family} simulator discovery failed before and after "
            f"CoreSimulatorService recovery; initial={initial_error}; final={error}"
        ) from error
    raise AssertionError("unreachable")


def simulator_state(identifier: str, env: dict[str, str]) -> str | None:
    completed = run(["xcrun", "simctl", "list", "devices", "-j"], env=env, timeout=30)
    if completed.returncode != 0:
        return None
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return None
    for devices in (payload.get("devices") or {}).values():
        for device in devices:
            if device.get("udid") == identifier:
                return str(device.get("state") or "") or None
    return None


def ensure_simulator_booted(identifier: str, env: dict[str, str]) -> None:
    initial_state = simulator_state(identifier, env)
    if initial_state == "Booted":
        return

    boot = run(["xcrun", "simctl", "boot", identifier], env=env, timeout=60)
    readiness = run(
        ["xcrun", "simctl", "bootstatus", identifier, "-b", "-d"],
        env=env,
        timeout=240,
    )
    if readiness.returncode == 0:
        return

    last_state = simulator_state(identifier, env)
    boot_detail = boot.stdout.strip() or f"exit {boot.returncode}"
    readiness_detail = readiness.stdout.strip() or f"exit {readiness.returncode}"
    raise RuntimeError(
        f"Simulator {identifier} did not complete bounded bootstatus; "
        f"initial_state={initial_state or 'unknown'}; "
        f"last_state={last_state or 'unknown'}; boot={boot_detail}; "
        f"bootstatus={readiness_detail}"
    )


def is_simulator_infrastructure_failure(output: str) -> bool:
    markers = (
        "Mach error -308", "server died", "Unable to find a device matching",
        "The requested device could not be found", "Accessibility error kAXErrorIPCTimeout",
        "kAXErrorServerNotFound", "Timed out while synthesizing event.",
        "Activation point invalid and no suggested hit points based on element frame",
        "Failed to get list of active applications", "Failed to prepare device",
        "Timed out trying to boot simulator",
        "visual xcodebuild made no log progress",
        "visual xcodebuild exceeded total timeout",
    )
    return any(marker in output for marker in markers)


def xcode_command(destination: str, actions: Sequence[str]) -> list[str]:
    return [
        "xcodebuild", "-project", str(PROJECT.relative_to(ROOT)),
        "-scheme", "FoveaWorkbench", "-destination",
        f"platform=iOS Simulator,id={destination}",
        "APPINTENTS_METADATA_PROCESSING_ENABLED=NO", *actions,
    ]


@contextmanager
def phase_signal_handlers(process: subprocess.Popen[str]) -> Iterator[None]:
    previous = {signum: signal.getsignal(signum) for signum in (signal.SIGINT, signal.SIGTERM)}

    def interrupt(_signum: int, _frame: object) -> None:
        terminate_process_group(process)
        raise KeyboardInterrupt

    for signum in previous:
        signal.signal(signum, interrupt)
    try:
        yield
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def monitor_xcode_process(
    process: subprocess.Popen[str], log: Path, stream: object,
    timeout_seconds: int, inactivity_timeout_seconds: int | None,
) -> tuple[int, bool, bool]:
    started_at = last_activity_at = time.monotonic()
    last_size = log.stat().st_size
    while True:
        if (return_code := process.poll()) is not None:
            return return_code, False, False
        time.sleep(1)
        now = time.monotonic()
        current_size = log.stat().st_size
        if current_size != last_size:
            last_size, last_activity_at = current_size, now
        if inactivity_expired(last_activity_at, now, inactivity_timeout_seconds):
            stream.write(
                "=== infrastructure stall: no log progress for "
                f"{inactivity_timeout_seconds} seconds ===\n"
            )
            stream.flush()
            terminate_process_group(process)
            return -1, False, True
        if now - started_at >= timeout_seconds:
            stream.write(f"=== phase timeout after {timeout_seconds} seconds ===\n")
            stream.flush()
            terminate_process_group(process)
            return -1, True, False


def execute_xcode_attempt(
    name: str, actions: Sequence[str], destination: str, env: dict[str, str],
    attempt: int, attempts: int, timeout_seconds: int,
    inactivity_timeout_seconds: int | None,
) -> PhaseAttempt:
    log = ARTIFACTS / f"{name}.log"
    command = xcode_command(destination, actions)
    with log.open("w" if attempt == 0 else "a") as stream:
        stream.write(f"=== attempt {attempt + 1}/{attempts} simulator={destination} ===\n")
        stream.flush()
        process = subprocess.Popen(
            command, cwd=ROOT, env=env, text=True, stdout=stream,
            stderr=subprocess.STDOUT, start_new_session=True,
        )
        with phase_signal_handlers(process):
            return_code, timed_out, stalled = monitor_xcode_process(
                process, log, stream, timeout_seconds, inactivity_timeout_seconds
            )
    return PhaseAttempt(
        command, destination, log, return_code, log.read_text(errors="replace"),
        timed_out, stalled,
    )


def successful_phase_result(
    name: str, attempt: PhaseAttempt, device_family: str, require_no_skips: bool
) -> dict[str, str]:
    if require_no_skips and re.search(r"\b[1-9][0-9]* test(?:s)? skipped\b", attempt.output):
        raise RuntimeError(f"FoveaWorkbench {name} reported skipped tests; live evidence was not executed")
    print(f"FoveaWorkbench {name} passed on simulator {attempt.destination}")
    return {
        "name": name, "simulatorID": attempt.destination,
        "deviceFamily": device_family, "log": str(attempt.log.relative_to(ROOT)),
        "logSha256": digest(attempt.log), "testCount": test_count(attempt.output),
    }


def phase_is_retryable(attempt: PhaseAttempt) -> bool:
    return attempt.stalled or (
        not attempt.timed_out and is_simulator_infrastructure_failure(attempt.output)
    )


def raise_phase_failure(
    name: str, attempt: PhaseAttempt, timeout_seconds: int,
    inactivity_timeout_seconds: int | None,
) -> None:
    tail = "\n".join(attempt.output.splitlines()[-120:])
    if attempt.stalled:
        raise RuntimeError(
            f"FoveaWorkbench {name} made no log progress for "
            f"{inactivity_timeout_seconds} seconds after infrastructure retry:\n{tail}"
        )
    if attempt.timed_out:
        raise RuntimeError(f"FoveaWorkbench {name} timed out after {timeout_seconds} seconds:\n{tail}")
    raise RuntimeError(f"FoveaWorkbench {name} failed:\n{tail}")


def run_xcode_phase(
    name: str, actions: list[str], *, env: dict[str, str],
    retry_infrastructure_once: bool = True, device_family: str = "iphone",
    require_no_skips: bool = False, timeout_seconds: int = 600,
    inactivity_timeout_seconds: int | None = None,
) -> dict[str, str]:
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    attempts = 2 if retry_infrastructure_once else 1
    last: PhaseAttempt | None = None
    initial_boot_error: RuntimeError | None = None
    for attempt_index in range(attempts):
        destination = simulator(env, device_family)
        try:
            ensure_simulator_booted(destination, env)
        except RuntimeError as boot_error:
            if attempt_index + 1 < attempts:
                initial_boot_error = boot_error
                try:
                    recover_core_simulator_service(env)
                except RuntimeError as recovery_error:
                    raise RuntimeError(
                        f"Simulator {destination} boot failed and "
                        f"CoreSimulatorService recovery failed; "
                        f"boot={boot_error}; recovery={recovery_error}"
                    ) from recovery_error
                continue
            if initial_boot_error is not None:
                raise RuntimeError(
                    f"Simulator {destination} boot failed before and after "
                    f"CoreSimulatorService recovery; "
                    f"initial={initial_boot_error}; final={boot_error}"
                ) from boot_error
            raise
        last = execute_xcode_attempt(
            name, actions, destination, env, attempt_index, attempts,
            timeout_seconds, inactivity_timeout_seconds,
        )
        if last.return_code == 0:
            return successful_phase_result(name, last, device_family, require_no_skips)
        if attempt_index + 1 < attempts and phase_is_retryable(last):
            restart_simulator(destination, env)
            continue
        break
    if last is None:
        raise RuntimeError(f"FoveaWorkbench {name} did not start an Xcode attempt")
    raise_phase_failure(name, last, timeout_seconds, inactivity_timeout_seconds)
    raise AssertionError("unreachable")


def aggregate_shard_logs(
    name: str, shards: Sequence[Sequence[str]], results: Sequence[dict[str, str]]
) -> Path:
    aggregate = ARTIFACTS / f"{name}.log"
    with aggregate.open("w") as stream:
        for index, (shard, result) in enumerate(zip(shards, results), start=1):
            stream.write(f"=== shard {index}/{len(shards)} methods={','.join(shard)} ===\n")
            text = (ROOT / result["log"]).read_text(errors="replace")
            stream.write(text)
            if not text.endswith("\n"):
                stream.write("\n")
    return aggregate


def run_xcode_sharded_phase(
    name: str, suite: str, methods: list[str], *, shard_count: int,
    env: dict[str, str], device_family: str,
) -> dict[str, str]:
    shards = balanced_shards(methods, shard_count)
    destination = simulator(env, device_family)
    results: list[dict[str, str]] = []
    for index, shard in enumerate(shards, start=1):
        if index > 1:
            restart_simulator(destination, env)
        selected = [f"-only-testing:{suite}/{method}" for method in shard]
        result = run_xcode_phase(
            f"{name}-shard-{index}", [*selected, "test"], env=env,
            device_family=device_family,
            timeout_seconds=UI_TEST_SUITE_BASE_TIMEOUT_SECONDS + len(shard) * UI_TEST_CASE_TIMEOUT_SECONDS,
            inactivity_timeout_seconds=UI_TEST_INACTIVITY_TIMEOUT_SECONDS,
        )
        if int(result["testCount"]) != len(shard):
            raise RuntimeError(
                f"FoveaWorkbench {name} shard {index} executed {result['testCount']}/{len(shard)} tests"
            )
        results.append(result)
    aggregate = aggregate_shard_logs(name, shards, results)
    total = sum(int(result["testCount"]) for result in results)
    print(f"FoveaWorkbench {name} passed in {len(shards)} shards on simulator {destination}: {total} tests")
    return {
        "name": name, "simulatorID": destination, "deviceFamily": device_family,
        "log": str(aggregate.relative_to(ROOT)), "logSha256": digest(aggregate),
        "testCount": total,
    }


def verify_release_build(
    env: dict[str, str], *, clean_derived_data: bool = True
) -> dict[str, str]:
    release_derived = ARTIFACTS / "release-derived"
    if clean_derived_data:
        shutil.rmtree(release_derived, ignore_errors=True)
    phase = run_xcode_phase(
        "build", ["-configuration", "Release", "-derivedDataPath", str(release_derived), "build"],
        env=env, retry_infrastructure_once=False,
    )
    app = release_derived / "Build/Products/Release-iphonesimulator/FoveaWorkbench.app"
    binary = app / "FoveaWorkbench"
    if not binary.is_file():
        raise RuntimeError("FoveaWorkbench Release executable is missing")
    strings = "\n".join(
        subprocess.run(
            ["strings", str(path)], text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, check=True,
        ).stdout
        for path in [binary, *app.glob("*.dylib")]
    )
    forbidden_tokens = (
        "--ui-testing", "--ui-story", "--ui-studio", "--ui-contract-first",
        "WorkbenchUITestRoute",
    )
    if forbidden := [token for token in forbidden_tokens if token in strings]:
        raise RuntimeError(f"Release binary exposes UI-test routing tokens: {forbidden}")
    if (app / "PlugIns").exists():
        raise RuntimeError("Release app unexpectedly contains test plug-ins")
    manifest_path = app / "PrivacyInfo.xcprivacy"
    if not manifest_path.is_file():
        raise RuntimeError("Release app is missing its root PrivacyInfo.xcprivacy")
    manifest = plistlib.loads(manifest_path.read_bytes())
    declarations = {
        item.get("NSPrivacyAccessedAPIType"): item.get("NSPrivacyAccessedAPITypeReasons")
        for item in manifest.get("NSPrivacyAccessedAPITypes", []) if isinstance(item, dict)
    }
    expected = {
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
    }
    if declarations != expected:
        raise RuntimeError(f"Release app privacy declarations differ from reviewed reasons: {declarations}")
    if manifest.get("NSPrivacyTracking") is not False:
        raise RuntimeError("Release app privacy manifest enables tracking")
    return phase


def recover_core_simulator_service(env: dict[str, str]) -> None:
    run(
        ["pkill", "-9", "-f", "com.apple.CoreSimulator.CoreSimulatorService"],
        env=env, timeout=30,
    )
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        completed = run(["xcrun", "simctl", "list", "devices", "-j"], env=env, timeout=15)
        if completed.returncode == 0:
            try:
                json.loads(completed.stdout)
            except json.JSONDecodeError:
                pass
            else:
                return
        time.sleep(2)
    raise RuntimeError("CoreSimulatorService did not recover within 60 seconds")


def restart_simulator(identifier: str, env: dict[str, str]) -> None:
    shutdown = run(["xcrun", "simctl", "shutdown", identifier], env=env, timeout=60)
    if shutdown.returncode == 0:
        try:
            ensure_simulator_booted(identifier, env)
            return
        except RuntimeError as initial_error:
            pass
    else:
        detail = shutdown.stdout.strip() or f"exit {shutdown.returncode}"
        initial_error = RuntimeError(
            f"Simulator {identifier} shutdown did not complete: {detail}"
        )

    recover_core_simulator_service(env)
    try:
        ensure_simulator_booted(identifier, env)
    except RuntimeError as recovery_error:
        raise RuntimeError(
            f"Simulator {identifier} restart failed before and after "
            f"CoreSimulatorService recovery; initial={initial_error}; recovery={recovery_error}"
        ) from recovery_error
