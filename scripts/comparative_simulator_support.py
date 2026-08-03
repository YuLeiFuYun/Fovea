#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import json
import os
import re
import signal
import subprocess
import time
from pathlib import Path
from typing import Any, Callable

SIMULATOR_RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
SIMULATOR_RUNTIME_BUILD = "23E254a"
SIMULATOR_RUNTIME_VERSION = "26.4.1"
SIMULATOR_DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17e"
SIMULATOR_NAME = "Fovea Comparative iPhone 17e R26"
SIMULATOR_REGISTRY = Path(".artifacts/comparative-simulator-device.json")
HOST_PREFLIGHT_ARTIFACT = Path(".artifacts/comparative-host-preflight.json")
INITIALIZATION_HOST_PREFLIGHT_ARTIFACT = Path(".artifacts/comparative-initialization-host-preflight.json")
SIMULATOR_RECOVERY_ARTIFACT = Path(".artifacts/comparative-simulator-recovery.json")
CORESIMULATOR_HEALTH_ARTIFACT = Path(".artifacts/comparative-coresimulator-health.json")
MINIMUM_CPU_IDLE_PERCENT = 65.0
MAXIMUM_DISK_MEGABYTES_PER_SECOND = 12.0
HOST_SAMPLE_COUNT = 3
PROCESS_ENUMERATION_TIMEOUT_SECONDS = 45
FIRST_BOOT_TIMEOUT_SECONDS = 900
REGULAR_BOOT_TIMEOUT_SECONDS = 240
XCODEBUILD_RESOLVED_PACKAGE_FLAGS = [
    "-disableAutomaticPackageResolution",
    "-onlyUsePackageVersionsFromResolvedFile",
    "-skipPackageUpdates",
]

RunCommand = Callable[..., subprocess.CompletedProcess[str]]


def assert_coresimulator_healthy(
    *,
    run_command: RunCommand,
    env: dict[str, str],
    root: Path,
) -> dict[str, Any]:
    output = run_command(
        ["ps", "-axo", "pid=,ppid=,state=,etime=,command="],
        env=env,
        timeout=PROCESS_ENUMERATION_TIMEOUT_SECONDS,
    ).stdout
    relevant_markers = (
        "simdiskimaged",
        "CoreSimulator.CoreSimulatorService",
        "launchd_sim ",
        "/CoreSimulator/Volumes/",
        "/CoreSimulator/Devices/",
    )
    blocked: list[dict[str, Any]] = []
    for line in output.splitlines():
        fields = line.strip().split(None, 4)
        if len(fields) != 5:
            continue
        try:
            pid = int(fields[0])
            parent = int(fields[1])
        except ValueError:
            continue
        state = fields[2]
        command = fields[4]
        if "U" not in state or not any(marker in command for marker in relevant_markers):
            continue
        blocked.append(
            {
                "pid": pid,
                "parentPID": parent,
                "state": state,
                "elapsed": fields[3],
                "command": command[:2_000],
            }
        )
    artifact = {
        "schemaVersion": 1,
        "capturedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "status": "blocked-uninterruptible-processes" if blocked else "healthy",
        "uninterruptibleProcesses": blocked,
    }
    path = root / CORESIMULATOR_HEALTH_ARTIFACT
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)
    if blocked:
        descriptions = ", ".join(
            f"pid={item['pid']} state={item['state']}" for item in blocked
        )
        raise RuntimeError(
            "CoreSimulator health gate rejected uninterruptible processes: "
            f"{descriptions}; evidence={path.relative_to(root)}"
        )
    return artifact


def _runtime_selection(run_command: RunCommand, env: dict[str, str]) -> dict[str, Any]:
    records = json.loads(
        run_command(
            ["xcrun", "simctl", "runtime", "list", "-v", "-j"],
            env=env,
            timeout=60,
        ).stdout
    )
    candidates: list[tuple[str, dict[str, Any]]] = [
        (storage_identifier, record)
        for storage_identifier, record in records.items()
        if record.get("runtimeIdentifier") == SIMULATOR_RUNTIME
        and record.get("build") == SIMULATOR_RUNTIME_BUILD
    ]
    if len(candidates) != 1:
        raise RuntimeError(
            "expected exactly one iOS 26.4.1 runtime build "
            f"{SIMULATOR_RUNTIME_BUILD}, found {len(candidates)}"
        )
    storage_identifier, selected = candidates[0]
    if selected.get("signatureState") != "Verified":
        raise RuntimeError("selected simulator runtime signature is not verified")
    runtime_bundle = selected.get("runtimeBundlePath")
    mount_path = selected.get("mountPath")
    if not isinstance(runtime_bundle, str) or not Path(runtime_bundle).is_dir():
        raise RuntimeError("selected simulator runtime bundle is not mounted")
    if not isinstance(mount_path, str) or not Path(mount_path).is_dir():
        raise RuntimeError("selected simulator runtime volume is not mounted")
    conflicts = [
        {
            "runtimeStorageIdentifier": other_identifier,
            "runtimeBuild": record.get("build"),
            "runtimeVersion": record.get("version"),
            "runtimeMountPath": record.get("mountPath"),
        }
        for other_identifier, record in records.items()
        if other_identifier != storage_identifier
        and record.get("runtimeIdentifier") == SIMULATOR_RUNTIME
        and record.get("mountPath")
    ]
    return {
        "runtimeStorageIdentifier": storage_identifier,
        "runtimeIdentifier": SIMULATOR_RUNTIME,
        "runtimeBuild": SIMULATOR_RUNTIME_BUILD,
        "runtimeVersion": SIMULATOR_RUNTIME_VERSION,
        "runtimeBundlePath": runtime_bundle,
        "runtimeMountPath": mount_path,
        "otherMountedRuntimeBuilds": conflicts,
    }


def _registry_path(root: Path) -> Path:
    return root / SIMULATOR_REGISTRY


def _read_registry(root: Path) -> dict[str, Any] | None:
    path = _registry_path(root)
    if not path.is_file():
        return None
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise RuntimeError("simulator registry must contain a JSON object")
    return value


def _write_registry(root: Path, value: dict[str, Any]) -> None:
    path = _registry_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def _device_matches(
    run_command: RunCommand,
    env: dict[str, str],
) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    data = json.loads(
        run_command(
            ["xcrun", "simctl", "list", "devices", "available", "-j"],
            env=env,
            timeout=30,
        ).stdout
    )
    devices = data.get("devices", {}).get(SIMULATOR_RUNTIME, [])
    matches = [item for item in devices if item.get("name") == SIMULATOR_NAME]
    if len(matches) > 1:
        raise RuntimeError("multiple dedicated Fovea simulators have the exact active name")
    return (matches[0] if matches else None), data


def _validated_registry(
    root: Path,
    device: dict[str, Any],
    runtime: dict[str, Any],
) -> dict[str, Any]:
    registry = _read_registry(root)
    if registry is None:
        raise RuntimeError(
            "dedicated simulator exists without a runtime-build registry; archive it and "
            "let the runner recreate it from the exact runtime bundle path"
        )
    required = {
        "deviceUDID": device.get("udid"),
        "deviceName": SIMULATOR_NAME,
        "runtimeIdentifier": SIMULATOR_RUNTIME,
        "runtimeBuild": SIMULATOR_RUNTIME_BUILD,
        "runtimeStorageIdentifier": runtime["runtimeStorageIdentifier"],
        "runtimeBundlePath": runtime["runtimeBundlePath"],
    }
    drift = {
        key: {"expected": expected, "actual": registry.get(key)}
        for key, expected in required.items()
        if registry.get(key) != expected
    }
    if drift:
        raise RuntimeError(f"dedicated simulator runtime registry drifted: {drift}")
    return registry



def _process_ancestry() -> set[int]:
    ancestry: set[int] = set()
    pid = os.getpid()
    parent_by_pid: dict[int, int] = {}
    output = subprocess.run(
        ["ps", "-axo", "pid=,ppid="],
        text=True,
        capture_output=True,
        timeout=PROCESS_ENUMERATION_TIMEOUT_SECONDS,
        check=True,
    ).stdout
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 2:
            parent_by_pid[int(fields[0])] = int(fields[1])
    while pid > 0 and pid not in ancestry:
        ancestry.add(pid)
        pid = parent_by_pid.get(pid, 0)
    return ancestry


def _competing_processes() -> list[dict[str, Any]]:
    ancestry = _process_ancestry()
    output = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,state=,%cpu=,command="],
        text=True,
        capture_output=True,
        timeout=PROCESS_ENUMERATION_TIMEOUT_SECONDS,
        check=True,
    ).stdout
    patterns = (
        re.compile(r"(?:^|/)(?:xcodebuild|swift-build|swift-test|swift-frontend)(?:\s|$)"),
        re.compile(r"(?:^|/)simctl\s+(?:diagnose|install|uninstall|bootstatus|launch)(?:\s|$)"),
        re.compile(r"run-(?:comparative|asyncimage)-simulator-lab\.py"),
    )
    competitors: list[dict[str, Any]] = []
    for line in output.splitlines():
        fields = line.strip().split(None, 4)
        if len(fields) != 5:
            continue
        pid = int(fields[0])
        if pid in ancestry:
            continue
        command = fields[4]
        if not any(pattern.search(command) for pattern in patterns):
            continue
        competitors.append(
            {
                "pid": pid,
                "parentPID": int(fields[1]),
                "state": fields[2],
                "cpuPercent": float(fields[3]),
                "command": command[:2_000],
            }
        )
    return competitors


def _cpu_idle_samples() -> list[float]:
    result = subprocess.run(
        ["top", "-l", str(HOST_SAMPLE_COUNT + 1), "-s", "1", "-n", "0"],
        text=True,
        capture_output=True,
        timeout=15,
        check=True,
    )
    samples: list[float] = []
    for line in result.stdout.splitlines():
        if "CPU usage:" not in line:
            continue
        match = re.search(r"([0-9]+(?:\.[0-9]+)?)% idle", line)
        if match:
            samples.append(float(match.group(1)))
    if len(samples) < HOST_SAMPLE_COUNT:
        raise RuntimeError("could not collect enough host CPU idle samples")
    return samples[-HOST_SAMPLE_COUNT:]


def _disk_throughput_samples() -> list[float]:
    result = subprocess.run(
        ["iostat", "-d", "-w", "1", "-c", str(HOST_SAMPLE_COUNT + 1)],
        text=True,
        capture_output=True,
        timeout=15,
        check=True,
    )
    rows: list[float] = []
    for line in result.stdout.splitlines():
        fields = line.split()
        if not fields or any(character.isalpha() for character in "".join(fields)):
            continue
        try:
            numbers = [float(field) for field in fields]
        except ValueError:
            continue
        if len(numbers) < 3 or len(numbers) % 3 != 0:
            continue
        rows.append(sum(numbers[index] for index in range(2, len(numbers), 3)))
    if len(rows) < HOST_SAMPLE_COUNT + 1:
        raise RuntimeError("could not collect enough host disk-throughput samples")
    # The first iostat row is the since-boot average; only interval rows are admissible.
    return rows[-HOST_SAMPLE_COUNT:]


def _assert_host_quiet(
    *,
    root: Path,
    artifact_path: Path,
    purpose: str,
) -> dict[str, Any]:
    competitors = _competing_processes()
    cpu_idle = _cpu_idle_samples()
    disk_megabytes = _disk_throughput_samples()
    failures: list[str] = []
    if competitors:
        failures.append(f"{len(competitors)} competing build or simulator processes")
    if min(cpu_idle) < MINIMUM_CPU_IDLE_PERCENT:
        failures.append(
            "CPU idle below threshold: "
            f"samples={cpu_idle} required>={MINIMUM_CPU_IDLE_PERCENT}"
        )
    if max(disk_megabytes) > MAXIMUM_DISK_MEGABYTES_PER_SECOND:
        failures.append(
            "disk throughput above threshold: "
            f"MB/s={disk_megabytes} required<={MAXIMUM_DISK_MEGABYTES_PER_SECOND}"
        )
    artifact = {
        "schemaVersion": 1,
        "capturedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "purpose": purpose,
        "minimumCPUIdlePercent": MINIMUM_CPU_IDLE_PERCENT,
        "maximumDiskMegabytesPerSecond": MAXIMUM_DISK_MEGABYTES_PER_SECOND,
        "cpuIdlePercentSamples": cpu_idle,
        "diskMegabytesPerSecondSamples": disk_megabytes,
        "competingProcesses": competitors,
        "passed": not failures,
        "failures": failures,
    }
    path = root / artifact_path
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)
    if failures:
        raise RuntimeError(
            f"{purpose} host is not quiescent: " + "; ".join(failures)
            + f"; evidence={path.relative_to(root)}"
        )
    # Give short-lived scheduler and filesystem activity from sampling itself time to settle.
    time.sleep(2)
    return artifact


def assert_measurement_host_quiet(*, root: Path) -> dict[str, Any]:
    return _assert_host_quiet(
        root=root,
        artifact_path=HOST_PREFLIGHT_ARTIFACT,
        purpose="measurement",
    )


def assert_initialization_host_quiet(*, root: Path) -> dict[str, Any]:
    return _assert_host_quiet(
        root=root,
        artifact_path=INITIALIZATION_HOST_PREFLIGHT_ARTIFACT,
        purpose="simulator initialization",
    )

def recover_dedicated_simulator_user_services(
    *,
    udid: str,
    root: Path,
    reason: str,
) -> dict[str, Any]:
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,state=,command="],
        text=True,
        capture_output=True,
        timeout=PROCESS_ENUMERATION_TIMEOUT_SECONDS,
        check=True,
    )
    rows: list[tuple[int, int, str, str]] = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) != 4:
            continue
        try:
            rows.append((int(fields[0]), int(fields[1]), fields[2], fields[3]))
        except ValueError:
            continue
    children: dict[int, list[int]] = {}
    command_by_pid: dict[int, str] = {}
    state_by_pid: dict[int, str] = {}
    for pid, parent, state, command in rows:
        children.setdefault(parent, []).append(pid)
        command_by_pid[pid] = command
        state_by_pid[pid] = state
    launchd_roots = [
        pid for pid, _, _, command in rows if "launchd_sim " in command
    ]
    target_roots = [
        pid
        for pid in launchd_roots
        if f"/Devices/{udid}/" in command_by_pid[pid]
    ]
    targets: set[int] = set(target_roots)
    pending = list(target_roots)
    while pending:
        parent = pending.pop()
        for child in children.get(parent, []):
            if child not in targets:
                targets.add(child)
                pending.append(child)
    core_service_pids = [
        pid
        for pid, _, _, command in rows
        if "CoreSimulator.CoreSimulatorService" in command
    ]
    restart_core_service = bool(target_roots) and len(launchd_roots) == len(target_roots)
    if restart_core_service:
        targets.update(core_service_pids)
    attempted: list[dict[str, Any]] = []
    for pid in sorted(targets, reverse=True):
        outcome = "sent-SIGKILL"
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            outcome = "already-exited"
        except PermissionError:
            outcome = "permission-denied"
        attempted.append(
            {
                "pid": pid,
                "state": state_by_pid.get(pid),
                "command": command_by_pid.get(pid, "<unknown>")[:2_000],
                "outcome": outcome,
            }
        )
    artifact = {
        "schemaVersion": 1,
        "capturedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "deviceUDID": udid,
        "reason": reason,
        "targetLaunchdSimPIDs": target_roots,
        "otherLaunchdSimPIDs": sorted(set(launchd_roots) - set(target_roots)),
        "coreSimulatorServiceRestartAttempted": restart_core_service,
        "attemptedProcesses": attempted,
    }
    path = root / SIMULATOR_RECOVERY_ARTIFACT
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)
    time.sleep(3)
    return artifact


def _critical_device_services(
    *,
    run_command: RunCommand,
    env: dict[str, str],
    udid: str,
) -> tuple[bool, list[str]]:
    output = run_command(
        ["ps", "-axo", "pid=,ppid=,command="],
        env=env,
        timeout=PROCESS_ENUMERATION_TIMEOUT_SECONDS,
    ).stdout
    rows: list[tuple[int, int, str]] = []
    for line in output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3:
            continue
        try:
            rows.append((int(fields[0]), int(fields[1]), fields[2]))
        except ValueError:
            continue
    launchd_pid = next(
        (
            pid
            for pid, _, command in rows
            if "launchd_sim " in command and f"/Devices/{udid}/" in command
        ),
        None,
    )
    if launchd_pid is None:
        return False, ["launchd_sim"]
    children: dict[int, list[tuple[int, int, str]]] = {}
    for row in rows:
        children.setdefault(row[1], []).append(row)
    commands: list[str] = []
    pending = [launchd_pid]
    while pending:
        parent = pending.pop()
        for child in children.get(parent, []):
            pending.append(child[0])
            commands.append(child[2])
    required = {
        "SpringBoard": "SpringBoard.app/SpringBoard",
        "backboardd": "/usr/libexec/backboardd",
        "runningboardd": "/usr/libexec/runningboardd",
        "lsd": "/usr/libexec/lsd",
    }
    missing = [
        label
        for label, marker in required.items()
        if not any(marker in command for command in commands)
    ]
    return not missing, missing


def _wait_for_install_readiness(
    *,
    run_command: RunCommand,
    env: dict[str, str],
    udid: str,
    timeout_seconds: int = 180,
) -> None:
    deadline = time.monotonic() + timeout_seconds
    last_missing: list[str] = ["unknown"]
    while time.monotonic() < deadline:
        ready, last_missing = _critical_device_services(
            run_command=run_command,
            env=env,
            udid=udid,
        )
        if ready:
            return
        time.sleep(1)
    raise RuntimeError(
        "dedicated simulator did not expose install-critical services within "
        f"{timeout_seconds} seconds; missing={last_missing}"
    )


def _live_device_runtime_builds(
    *,
    run_command: RunCommand,
    env: dict[str, str],
    udid: str,
) -> set[str]:
    output = run_command(
        ["ps", "-axo", "pid=,ppid=,command="],
        env=env,
        timeout=PROCESS_ENUMERATION_TIMEOUT_SECONDS,
    ).stdout
    rows: list[tuple[int, int, str]] = []
    for line in output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3:
            continue
        try:
            rows.append((int(fields[0]), int(fields[1]), fields[2]))
        except ValueError:
            continue
    launchd_pid = next(
        (
            pid
            for pid, _, command in rows
            if "launchd_sim " in command and f"/Devices/{udid}/" in command
        ),
        None,
    )
    if launchd_pid is None:
        raise RuntimeError(
            f"dedicated simulator {udid} has no live launchd_sim process after boot"
        )
    children: dict[int, list[tuple[int, int, str]]] = {}
    for row in rows:
        children.setdefault(row[1], []).append(row)
    builds: set[str] = set()
    pending = [launchd_pid]
    while pending:
        parent = pending.pop()
        for child in children.get(parent, []):
            pending.append(child[0])
            match = re.search(r"/CoreSimulator/Volumes/iOS_([^/]+)/", child[2])
            if match:
                builds.add(match.group(1))
    if not builds:
        raise RuntimeError(
            f"dedicated simulator {udid} exposed no runtime-build paths after boot"
        )
    return builds


def _verify_live_device_runtime(
    *,
    run_command: RunCommand,
    env: dict[str, str],
    udid: str,
) -> set[str]:
    builds = _live_device_runtime_builds(
        run_command=run_command,
        env=env,
        udid=udid,
    )
    expected = {SIMULATOR_RUNTIME_BUILD}
    if builds != expected:
        run_command(
            ["xcrun", "simctl", "shutdown", udid],
            env=env,
            timeout=60,
            check=False,
        )
        raise RuntimeError(
            "dedicated simulator runtime build mismatch: "
            f"expected={sorted(expected)} actual={sorted(builds)}; device was shut down"
        )
    return builds


def ensure_dedicated_simulator(
    *,
    run_command: RunCommand,
    env: dict[str, str],
    root: Path,
    require_terminal_boot: bool = True,
) -> str:
    assert_coresimulator_healthy(
        run_command=run_command,
        env=env,
        root=root,
    )
    runtime = _runtime_selection(run_command, env)
    device, _ = _device_matches(run_command, env)
    if device is None:
        assert_initialization_host_quiet(root=root)
        udid = run_command(
            [
                "xcrun",
                "simctl",
                "create",
                SIMULATOR_NAME,
                SIMULATOR_DEVICE_TYPE,
                runtime["runtimeBundlePath"],
            ],
            env=env,
            timeout=60,
        ).stdout.strip()
        if not udid:
            raise RuntimeError("failed to create the dedicated Fovea simulator")
        registry: dict[str, Any] = {
            **runtime,
            "deviceUDID": udid,
            "deviceName": SIMULATOR_NAME,
            "deviceType": SIMULATOR_DEVICE_TYPE,
            "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "firstBootCompletedAt": None,
        }
        _write_registry(root, registry)
        state = "Shutdown"
    else:
        udid = str(device["udid"])
        state = device.get("state")
        registry = _validated_registry(root, device, runtime)
        if (
            not registry.get("firstBootCompletedAt")
            and registry.get("lastFirstBootFailureAt")
        ):
            raise RuntimeError(
                "dedicated simulator has a recorded incomplete first boot; "
                "archive the device and registry before recreating it"
            )
        if not registry.get("firstBootCompletedAt"):
            assert_initialization_host_quiet(root=root)

    if state != "Booted":
        run_command(
            ["xcrun", "simctl", "boot", udid],
            env=env,
            timeout=120,
            check=False,
        )
    first_boot_pending = not registry.get("firstBootCompletedAt")
    terminal_boot_required = require_terminal_boot or first_boot_pending
    if terminal_boot_required:
        timeout = (
            FIRST_BOOT_TIMEOUT_SECONDS
            if first_boot_pending
            else REGULAR_BOOT_TIMEOUT_SECONDS
        )
        try:
            run_command(
                ["xcrun", "simctl", "bootstatus", udid, "-b", "-d"],
                env=env,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as error:
            output = error.output or ""
            if isinstance(output, bytes):
                output = output.decode(errors="replace")
            tail = output[-8_000:] if output else "<no bootstatus progress captured>"
            failure_time = dt.datetime.now(dt.timezone.utc).isoformat()
            registry["lastBootFailureAt"] = failure_time
            registry["lastBootFailureTimeoutSeconds"] = timeout
            registry["lastBootFailureProgressTail"] = tail
            if first_boot_pending:
                registry["lastFirstBootFailureAt"] = failure_time
            _write_registry(root, registry)
            raise RuntimeError(
                f"dedicated simulator did not finish booting within {timeout} seconds; "
                f"last bootstatus progress:\n{tail}"
            ) from error
        readiness_mode = "terminal-boot"
    else:
        _wait_for_install_readiness(
            run_command=run_command,
            env=env,
            udid=udid,
        )
        readiness_mode = "install-critical-services"
    live_builds = _verify_live_device_runtime(
        run_command=run_command,
        env=env,
        udid=udid,
    )
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    if first_boot_pending:
        registry["firstBootCompletedAt"] = now
    registry["lastLiveRuntimeVerificationAt"] = now
    registry["lastLiveRuntimeBuilds"] = sorted(live_builds)
    registry["lastReadinessMode"] = readiness_mode
    registry["otherMountedRuntimeBuildsAtVerification"] = runtime.get(
        "otherMountedRuntimeBuilds", []
    )
    _write_registry(root, registry)
    return udid
