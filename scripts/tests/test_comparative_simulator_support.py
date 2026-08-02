#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import comparative_simulator_support as support


class FakeRunner:
    def __init__(
        self,
        *,
        runtime_records: dict[str, object],
        devices: list[dict[str, object]] | None = None,
        live_build: str = support.SIMULATOR_RUNTIME_BUILD,
        unhealthy_coresimulator: bool = False,
        bootstatus_timeout: bool = False,
    ) -> None:
        self.runtime_records = runtime_records
        self.devices = devices or []
        self.commands: list[list[str]] = []
        self.created_udid = "11111111-2222-3333-4444-555555555555"
        self.live_build = live_build
        self.unhealthy_coresimulator = unhealthy_coresimulator
        self.bootstatus_timeout = bootstatus_timeout

    def __call__(
        self,
        command: list[str],
        *,
        env: dict[str, str],
        timeout: int,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        del env, check
        self.commands.append(command)
        if command[1:5] == ["simctl", "runtime", "list", "-v"]:
            return subprocess.CompletedProcess(command, 0, json.dumps(self.runtime_records), "")
        if command[1:4] == ["simctl", "list", "devices"]:
            payload = {"devices": {support.SIMULATOR_RUNTIME: self.devices}}
            return subprocess.CompletedProcess(command, 0, json.dumps(payload), "")
        if command[1:3] == ["simctl", "create"]:
            return subprocess.CompletedProcess(command, 0, self.created_udid + "\n", "")
        if command[0] == "ps" and "state=" in " ".join(command):
            if self.unhealthy_coresimulator:
                output = (
                    "900 1 Us 12:34 /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/bin/simdiskimaged\n"
                )
            else:
                output = (
                    "901 1 Ss 00:30 /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/bin/simdiskimaged\n"
                )
            return subprocess.CompletedProcess(command, 0, output, "")
        if command[0] == "ps":
            udid = (
                str(self.devices[0]["udid"])
                if self.devices
                else self.created_udid
            )
            output = (
                f"100 1 launchd_sim /private/tmp/fovea-synthetic-home/Library/Developer/CoreSimulator/Devices/{udid}/data/var/run/launchd_bootstrap.plist\n"
                f"101 100 /Library/Developer/CoreSimulator/Volumes/iOS_{self.live_build}/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.4.simruntime/Contents/Resources/RuntimeRoot/usr/libexec/installd\n"
                f"102 100 /Library/Developer/CoreSimulator/Volumes/iOS_{self.live_build}/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.4.simruntime/Contents/Resources/RuntimeRoot/System/Library/CoreServices/SpringBoard.app/SpringBoard\n"
                f"103 100 /Library/Developer/CoreSimulator/Volumes/iOS_{self.live_build}/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.4.simruntime/Contents/Resources/RuntimeRoot/usr/libexec/backboardd\n"
                f"104 100 /Library/Developer/CoreSimulator/Volumes/iOS_{self.live_build}/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.4.simruntime/Contents/Resources/RuntimeRoot/usr/libexec/runningboardd\n"
                f"105 100 /Library/Developer/CoreSimulator/Volumes/iOS_{self.live_build}/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.4.simruntime/Contents/Resources/RuntimeRoot/usr/libexec/lsd\n"
            )
            return subprocess.CompletedProcess(command, 0, output, "")
        if command[1:3] == ["simctl", "bootstatus"] and self.bootstatus_timeout:
            raise subprocess.TimeoutExpired(
                command,
                timeout=timeout,
                output="Status=2 Waiting on Data Migration",
            )
        if command[1:3] in (
            ["simctl", "boot"],
            ["simctl", "bootstatus"],
            ["simctl", "shutdown"],
        ):
            return subprocess.CompletedProcess(command, 0, "", "")
        raise AssertionError(f"unexpected command: {command}")


def runtime_records(
    root: Path,
    *,
    include_mounted_conflict: bool = False,
) -> dict[str, object]:
    selected_mount = root / "iOS_23E254a"
    selected_bundle = selected_mount / "iOS 26.4.simruntime"
    selected_bundle.mkdir(parents=True)
    records: dict[str, object] = {
        "selected-storage": {
            "runtimeIdentifier": support.SIMULATOR_RUNTIME,
            "build": support.SIMULATOR_RUNTIME_BUILD,
            "version": support.SIMULATOR_RUNTIME_VERSION,
            "signatureState": "Verified",
            "runtimeBundlePath": str(selected_bundle),
            "mountPath": str(selected_mount),
        }
    }
    if include_mounted_conflict:
        old_mount = root / "iOS_23E244"
        old_bundle = old_mount / "iOS 26.4.simruntime"
        old_bundle.mkdir(parents=True)
        records["old-storage"] = {
            "runtimeIdentifier": support.SIMULATOR_RUNTIME,
            "build": "23E244",
            "version": "26.4",
            "signatureState": "Verified",
            "runtimeBundlePath": str(old_bundle),
            "mountPath": str(old_mount),
        }
    return records


class CoreSimulatorHealthTests(unittest.TestCase):
    def test_rejects_uninterruptible_coresimulator_process(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner = FakeRunner(
                runtime_records=runtime_records(root),
                unhealthy_coresimulator=True,
            )
            with self.assertRaisesRegex(RuntimeError, "health gate rejected"):
                support.ensure_dedicated_simulator(
                    run_command=runner,
                    env={},
                    root=root,
                )
            artifact = json.loads(
                (root / support.CORESIMULATOR_HEALTH_ARTIFACT).read_text()
            )
            self.assertEqual(artifact["status"], "blocked-uninterruptible-processes")
            self.assertEqual(artifact["uninterruptibleProcesses"][0]["pid"], 900)


class RuntimeSelectionTests(unittest.TestCase):
    def setUp(self) -> None:
        super().setUp()
        patcher = mock.patch.object(
            support,
            "assert_initialization_host_quiet",
            return_value={"passed": True, "purpose": "simulator initialization"},
        )
        self.initialization_gate = patcher.start()
        self.addCleanup(patcher.stop)

    def test_selects_exact_verified_runtime_build(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner = FakeRunner(runtime_records=runtime_records(root))
            selected = support._runtime_selection(runner, {})
            self.assertEqual(selected["runtimeBuild"], "23E254a")
            self.assertEqual(selected["runtimeStorageIdentifier"], "selected-storage")
            self.assertTrue(selected["runtimeBundlePath"].endswith("iOS 26.4.simruntime"))

    def test_reports_another_mounted_build_without_preempting_live_validation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner = FakeRunner(
                runtime_records=runtime_records(root, include_mounted_conflict=True)
            )
            selected = support._runtime_selection(runner, {})
            self.assertEqual(
                selected["otherMountedRuntimeBuilds"][0]["runtimeBuild"],
                "23E244",
            )

    def test_creates_device_from_exact_bundle_path_and_records_binding(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            records = runtime_records(root)
            runner = FakeRunner(runtime_records=records)
            udid = support.ensure_dedicated_simulator(
                run_command=runner,
                env={},
                root=root,
            )
            self.assertEqual(udid, runner.created_udid)
            create = next(command for command in runner.commands if command[2] == "create")
            self.assertEqual(
                create[-1],
                records["selected-storage"]["runtimeBundlePath"],
            )
            registry = json.loads((root / support.SIMULATOR_REGISTRY).read_text())
            self.assertEqual(registry["deviceUDID"], runner.created_udid)
            self.assertEqual(registry["runtimeBuild"], "23E254a")
            self.assertIsNotNone(registry["firstBootCompletedAt"])

    def test_rejects_wrong_live_runtime_build_and_shuts_down_device(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            records = runtime_records(root)
            runner = FakeRunner(runtime_records=records, live_build="23E244")
            with self.assertRaisesRegex(RuntimeError, "runtime build mismatch"):
                support.ensure_dedicated_simulator(
                    run_command=runner,
                    env={},
                    root=root,
                )
            self.assertIn(
                ["xcrun", "simctl", "shutdown", runner.created_udid],
                runner.commands,
            )

    def test_failed_first_boot_is_recorded_and_not_reused(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            records = runtime_records(root)
            runner = FakeRunner(
                runtime_records=records,
                bootstatus_timeout=True,
            )
            with self.assertRaisesRegex(RuntimeError, "did not finish booting"):
                support.ensure_dedicated_simulator(
                    run_command=runner,
                    env={},
                    root=root,
                )
            registry_path = root / support.SIMULATOR_REGISTRY
            registry = json.loads(registry_path.read_text())
            self.assertIsNotNone(registry["lastFirstBootFailureAt"])
            self.assertIn("Waiting on Data Migration", registry["lastBootFailureProgressTail"])

            existing = {
                "name": support.SIMULATOR_NAME,
                "udid": runner.created_udid,
                "state": "Shutdown",
            }
            second = FakeRunner(runtime_records=records, devices=[existing])
            with self.assertRaisesRegex(RuntimeError, "recorded incomplete first boot"):
                support.ensure_dedicated_simulator(
                    run_command=second,
                    env={},
                    root=root,
                )


    def test_initialization_gate_blocks_before_device_creation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner = FakeRunner(runtime_records=runtime_records(root))
            self.initialization_gate.side_effect = RuntimeError(
                "simulator initialization host is not quiescent"
            )
            with self.assertRaisesRegex(RuntimeError, "initialization host"):
                support.ensure_dedicated_simulator(
                    run_command=runner,
                    env={},
                    root=root,
                )
            self.assertFalse(
                any(command[1:3] == ["simctl", "create"] for command in runner.commands)
            )

    def test_install_readiness_can_skip_terminal_boot_after_first_boot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            records = runtime_records(root)
            device = {
                "name": support.SIMULATOR_NAME,
                "udid": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                "state": "Booted",
            }
            runner = FakeRunner(runtime_records=records, devices=[device])
            registry_path = root / support.SIMULATOR_REGISTRY
            registry_path.parent.mkdir(parents=True)
            registry_path.write_text(
                json.dumps(
                    {
                        "deviceUDID": device["udid"],
                        "deviceName": support.SIMULATOR_NAME,
                        "runtimeIdentifier": support.SIMULATOR_RUNTIME,
                        "runtimeBuild": support.SIMULATOR_RUNTIME_BUILD,
                        "runtimeStorageIdentifier": "selected-storage",
                        "runtimeBundlePath": records["selected-storage"]["runtimeBundlePath"],
                        "firstBootCompletedAt": "2026-07-31T00:00:00+00:00",
                    }
                )
            )
            support.ensure_dedicated_simulator(
                run_command=runner,
                env={},
                root=root,
                require_terminal_boot=False,
            )
            self.assertFalse(
                any(
                    len(command) > 2 and command[2] == "bootstatus"
                    for command in runner.commands
                )
            )
            registry = json.loads(registry_path.read_text())
            self.assertEqual(
                registry["lastReadinessMode"],
                "install-critical-services",
            )

    def test_rejects_device_registry_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            records = runtime_records(root)
            device = {
                "name": support.SIMULATOR_NAME,
                "udid": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                "state": "Shutdown",
            }
            runner = FakeRunner(runtime_records=records, devices=[device])
            registry_path = root / support.SIMULATOR_REGISTRY
            registry_path.parent.mkdir(parents=True)
            registry_path.write_text(
                json.dumps(
                    {
                        "deviceUDID": device["udid"],
                        "deviceName": support.SIMULATOR_NAME,
                        "runtimeIdentifier": support.SIMULATOR_RUNTIME,
                        "runtimeBuild": "23E244",
                        "runtimeStorageIdentifier": "selected-storage",
                        "runtimeBundlePath": records["selected-storage"]["runtimeBundlePath"],
                    }
                )
            )
            with self.assertRaisesRegex(RuntimeError, "registry drifted"):
                support.ensure_dedicated_simulator(
                    run_command=runner,
                    env={},
                    root=root,
                )




class RecoveryTests(unittest.TestCase):
    def test_recovery_targets_only_dedicated_tree_and_restarts_core_when_alone(self) -> None:
        ps_output = """100 1 S launchd_sim /private/tmp/fovea-synthetic-home/Library/Developer/CoreSimulator/Devices/TARGET/data/var/run/launchd_bootstrap.plist
101 100 U /Runtime/usr/libexec/installd
102 100 S /Runtime/System/Library/CoreServices/SpringBoard.app/SpringBoard
200 1 S /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/com.apple.CoreSimulator.CoreSimulatorService
"""
        completed = subprocess.CompletedProcess(["ps"], 0, ps_output, "")
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            support.subprocess, "run", return_value=completed
        ), mock.patch.object(support.os, "kill") as kill, mock.patch.object(
            support.time, "sleep"
        ):
            artifact = support.recover_dedicated_simulator_user_services(
                udid="TARGET",
                root=Path(directory),
                reason="test timeout",
            )
            self.assertTrue(artifact["coreSimulatorServiceRestartAttempted"])
            self.assertEqual(
                {call.args[0] for call in kill.call_args_list},
                {100, 101, 102, 200},
            )
            on_disk = json.loads(
                (Path(directory) / support.SIMULATOR_RECOVERY_ARTIFACT).read_text()
            )
            self.assertEqual(on_disk["reason"], "test timeout")

class HostQuiescenceTests(unittest.TestCase):
    def test_initialization_gate_writes_separate_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            support, "_competing_processes", return_value=[]
        ), mock.patch.object(
            support, "_cpu_idle_samples", return_value=[80.0, 78.0, 82.0]
        ), mock.patch.object(
            support, "_disk_throughput_samples", return_value=[2.0, 3.0, 1.0]
        ), mock.patch.object(support.time, "sleep"):
            root = Path(directory)
            artifact = support.assert_initialization_host_quiet(root=root)
            self.assertTrue(artifact["passed"])
            self.assertEqual(artifact["purpose"], "simulator initialization")
            on_disk = json.loads(
                (root / support.INITIALIZATION_HOST_PREFLIGHT_ARTIFACT).read_text()
            )
            self.assertTrue(on_disk["passed"])
            self.assertFalse((root / support.HOST_PREFLIGHT_ARTIFACT).exists())

    def test_writes_passing_evidence_for_quiet_host(self) -> None:
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            support, "_competing_processes", return_value=[]
        ), mock.patch.object(
            support, "_cpu_idle_samples", return_value=[80.0, 78.0, 82.0]
        ), mock.patch.object(
            support, "_disk_throughput_samples", return_value=[2.0, 3.0, 1.0]
        ), mock.patch.object(support.time, "sleep"):
            root = Path(directory)
            artifact = support.assert_measurement_host_quiet(root=root)
            self.assertTrue(artifact["passed"])
            on_disk = json.loads((root / support.HOST_PREFLIGHT_ARTIFACT).read_text())
            self.assertTrue(on_disk["passed"])

    def test_rejects_busy_host_and_preserves_evidence(self) -> None:
        competitor = {
            "pid": 42,
            "parentPID": 1,
            "state": "R",
            "cpuPercent": 80.0,
            "command": "xcodebuild test",
        }
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            support, "_competing_processes", return_value=[competitor]
        ), mock.patch.object(
            support, "_cpu_idle_samples", return_value=[10.0, 20.0, 15.0]
        ), mock.patch.object(
            support, "_disk_throughput_samples", return_value=[20.0, 18.0, 30.0]
        ):
            root = Path(directory)
            with self.assertRaisesRegex(RuntimeError, "not quiescent"):
                support.assert_measurement_host_quiet(root=root)
            artifact = json.loads((root / support.HOST_PREFLIGHT_ARTIFACT).read_text())
            self.assertFalse(artifact["passed"])
            self.assertEqual(len(artifact["competingProcesses"]), 1)
            self.assertEqual(len(artifact["failures"]), 3)


if __name__ == "__main__":
    unittest.main()
