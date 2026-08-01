#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
from typing import Any

SIMCTL_LIST_TIMEOUT_SECONDS = 30
SIMCTL_TERMINATION_GRACE_SECONDS = 5


def runtime_version(identifier: str) -> tuple[int, ...]:
    match = re.search(r"iOS[- ](\d+(?:[-.]\d+)*)", identifier)
    if not match:
        return (0,)
    return tuple(int(part) for part in re.split(r"[-.]", match.group(1)))


def device_preference(name: str, family: str) -> int:
    if family == "ipad":
        if "Pro 11-inch" in name:
            return 5
        if "Air 11-inch" in name:
            return 4
        if "mini" in name:
            return 3
        if name.startswith("iPad ("):
            return 2
        if "Pro 13-inch" in name:
            return 1
        return 0
    if "Pro" in name and "Max" not in name:
        return 3
    if "Pro Max" in name:
        return 2
    if "Air" in name:
        return 1
    return 0


def signal_process_group(
    process: subprocess.Popen[str],
    signal_number: signal.Signals,
) -> None:
    try:
        os.killpg(process.pid, signal_number)
        return
    except ProcessLookupError:
        return
    except PermissionError:
        # Some Xcode tool wrappers hand work to a child outside the original
        # process group. Fall back to the leader instead of leaking a traceback.
        pass
    try:
        if signal_number == signal.SIGTERM:
            process.terminate()
        else:
            process.kill()
    except ProcessLookupError:
        return


def terminate_process_group(process: subprocess.Popen[str]) -> None:
    # communicate() may time out after the xcrun leader has exited because a
    # simctl descendant still owns stdout/stderr. Always signal the original
    # session group rather than returning solely from process.poll().
    signal_process_group(process, signal.SIGTERM)
    try:
        process.wait(timeout=SIMCTL_TERMINATION_GRACE_SECONDS)
        return
    except subprocess.TimeoutExpired:
        pass
    signal_process_group(process, signal.SIGKILL)
    try:
        process.wait(timeout=SIMCTL_TERMINATION_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        # Do not turn infrastructure cleanup into an unbounded verifier hang.
        # Closing the captured pipes also prevents an orphan descendant from
        # keeping communicate() alive indefinitely.
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()


def available_devices() -> dict[str, list[dict[str, Any]]]:
    process = subprocess.Popen(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=SIMCTL_LIST_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        terminate_process_group(process)
        raise RuntimeError(
            f"simctl device discovery timed out after {SIMCTL_LIST_TIMEOUT_SECONDS} seconds"
        ) from error
    if process.returncode != 0:
        detail = stderr.strip() or stdout.strip()
        raise RuntimeError(f"simctl device discovery failed: {detail}")
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("simctl device discovery returned invalid JSON") from error
    devices = payload.get("devices", {})
    if not isinstance(devices, dict):
        raise RuntimeError("simctl device discovery omitted the devices mapping")
    return devices


def main() -> int:
    parser = argparse.ArgumentParser(description="Select an available Apple simulator.")
    parser.add_argument("--device-family", choices=("iphone", "ipad"), default="iphone")
    parser.add_argument(
        "--runtime-version",
        help="Prefer an exact iOS runtime version such as 26.4.",
    )
    args = parser.parse_args()
    try:
        devices = available_devices()
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        return 1

    candidates: list[tuple[tuple[int, ...], bool, int, str, str]] = []
    for runtime, entries in devices.items():
        if "iOS" not in runtime:
            continue
        version = runtime_version(runtime)
        if args.runtime_version and version != runtime_version(f"iOS-{args.runtime_version}"):
            continue
        for device in entries:
            name = device.get("name", "")
            expected_prefix = "iPhone" if args.device_family == "iphone" else "iPad"
            if not device.get("isAvailable") or not name.startswith(expected_prefix):
                continue
            candidates.append(
                (
                    version,
                    device.get("state") == "Booted",
                    device_preference(name, args.device_family),
                    name,
                    device["udid"],
                )
            )

    if not candidates:
        print(f"No available {args.device_family} simulator.", file=sys.stderr)
        return 1

    # A single discovery snapshot avoids a second unbounded CoreSimulator round trip.
    # The verifier immediately confirms the selected device through bootstatus.
    print(max(candidates)[4])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
