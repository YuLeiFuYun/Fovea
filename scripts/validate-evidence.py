#!/usr/bin/env python3
import json
from pathlib import Path
import re
import sys

TRUSTED_PRODUCERS = {"trusted-ci", "held-out-evaluator", "human-reviewer", "release-builder"}
COMMIT = re.compile(r"^[0-9a-fA-F]{7,64}$")
TRUSTED_CI_LOCATOR = re.compile(r"^https://[^/]+/.+/actions/runs/[0-9]+(?:[#/].*)?$")


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def validate(path: Path) -> None:
    data = json.loads(path.read_text())
    required = {
        "schemaVersion", "changeID", "baseCommit", "headCommit", "verifiedCommit",
        "assuranceStage", "taskContextFingerprint", "riskClass", "accountableOwner",
        "requirements", "agent", "permissions", "changedFiles", "verification",
        "assumptions", "rollback",
    }
    missing = sorted(required - data.keys())
    if missing:
        fail(f"{path}: missing fields {missing}")
    if data["schemaVersion"] != 1:
        fail(f"{path}: unsupported schemaVersion")
    for field in ("baseCommit", "headCommit", "verifiedCommit"):
        if not COMMIT.fullmatch(data[field]):
            fail(f"{path}: invalid {field}")
    if data["assuranceStage"] not in {"0a-bootstrap", "0a-complete", "0b-in-progress", "0b", "release"}:
        fail(f"{path}: invalid assuranceStage")
    permissions = data["permissions"]
    for field in ("hadProductionSecrets", "couldWriteProtectedBranch", "couldReadHeldOutTests"):
        if permissions.get(field) is not False:
            fail(f"{path}: {field} must be false")
    if data["headCommit"] != data["verifiedCommit"]:
        fail(f"{path}: headCommit must equal verifiedCommit")
    if data["assuranceStage"] == "0a-complete":
        if "humanAttestation" not in data:
            fail(f"{path}: 0a-complete requires humanAttestation")
        if data["accountableOwner"].startswith("pending-"):
            fail(f"{path}: 0a-complete requires a resolved accountableOwner")
    for result in data["verification"]:
        status = result.get("status")
        producer = result.get("producer")
        digest = result.get("evidenceDigest", "")
        locator = result.get("evidenceLocator", "")
        if status == "pass" and producer not in TRUSTED_PRODUCERS:
            fail(f"{path}: pass result {result.get('id')} has untrusted producer {producer}")
        if status == "pass" and producer == "trusted-ci" and not TRUSTED_CI_LOCATOR.fullmatch(locator):
            fail(f"{path}: trusted-ci result {result.get('id')} lacks a durable CI run locator")
        if result.get("verifiedCommit") != data["verifiedCommit"]:
            fail(f"{path}: result {result.get('id')} is not bound to verifiedCommit")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            fail(f"{path}: invalid evidenceDigest for {result.get('id')}")
    print(f"Evidence valid: {path}")


if len(sys.argv) < 2:
    fail("Usage: validate-evidence.py <evidence.json> [...]")
for argument in sys.argv[1:]:
    validate(Path(argument))
