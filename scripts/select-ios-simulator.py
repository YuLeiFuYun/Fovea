#!/usr/bin/env python3
import json
import subprocess
import sys

payload = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True)
devices = json.loads(payload).get("devices", {})

candidates = []
for runtime, entries in devices.items():
    if "iOS" not in runtime:
        continue
    for device in entries:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
            candidates.append((runtime, device.get("state") != "Booted", device["name"], device["udid"]))

if not candidates:
    print("No available iPhone simulator.", file=sys.stderr)
    sys.exit(1)

candidates.sort()
print(candidates[-1][3])
