#!/usr/bin/env python3
"""Validate the completed local Akashic/FoveaStorage boundary extraction."""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "docs/project-memory/akashic-contract-migration.json"
ARTIFACT = ROOT / ".artifacts/project-memory/akashic-contract-migration-verification.json"
AKASHIC_ROOTS = [
    ROOT / "Sources/AkashicCore",
    ROOT / "Sources/AkashicMemory",
    ROOT / "Sources/AkashicDisk",
]


def canonical_digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def load() -> dict[str, Any]:
    value = json.loads(MIGRATION.read_text())
    if not isinstance(value, dict):
        raise TypeError("Akashic migration manifest must contain an object")
    return value


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def main() -> int:
    document = load()
    errors: list[str] = []

    if document.get("schemaVersion") != 1:
        errors.append("unexpected schemaVersion")
    if document.get("migrationID") != "FOVEA-AKASHIC-DOMAIN-NEUTRAL-MIGRATION-V1":
        errors.append("unexpected migrationID")
    if document.get("phase") != "P3":
        errors.append("migration must remain assigned to P3")
    if document.get("status") != (
        "domain-contracts-extracted-public-exact-dependency-embedded-source-removed-clean-copy-rollback-forward-passed"
    ):
        errors.append(
            "migration status must reflect the public exact dependency, removed embedded source, and passed clean-copy/rollback/forward evidence"
        )

    evidence = document.get("independentEvidence")
    if not isinstance(evidence, str) or not (ROOT / evidence).is_file():
        errors.append(f"independent evidence missing: {evidence}")
    adr = document.get("canonicalADR")
    if not isinstance(adr, str) or not (ROOT / adr).is_file():
        errors.append(f"canonical ADR missing: {adr}")

    expected_inventory = {
        "OriginalEncodedStoring": "FoveaStorage",
        "OriginalEncodedMaintaining": "FoveaStorage",
        "StorageNamespaceFingerprint": "FoveaStorage",
        "StoredBlob": "FoveaStorage",
        "StoredContentReference": "FoveaStorage",
        "GarbageCollectionResult": "FoveaStorage",
        "BlobDigest": "AkashicCore",
        "CachePartitionID": "AkashicCore",
        "PhysicalBlobID": "AkashicCore",
        "FileBlobStore": "AkashicDisk",
        "StoreGenerationHandle": "AkashicDisk",
        "StoreGenerationDirectory": "AkashicDisk",
        "MemoryCache": "AkashicMemory",
    }
    inventory = document.get("currentPublicInventory", [])
    observed_inventory: dict[str, str] = {}
    for item in inventory:
        if not isinstance(item, dict):
            errors.append("currentPublicInventory entry must be an object")
            continue
        symbol = item.get("symbol")
        path_value = item.get("path")
        anchor = item.get("anchor")
        owner = item.get("owner")
        if not isinstance(symbol, str) or not symbol or symbol in observed_inventory:
            errors.append(f"invalid or duplicate current symbol: {symbol}")
            continue
        observed_inventory[symbol] = str(owner)
        path = ROOT / str(path_value)
        if str(owner).startswith("Akashic"):
            if not isinstance(path_value, str) or not path_value.startswith("Sources/Akashic"):
                errors.append(f"external Akashic inventory path drifted: {path_value}")
            if path.exists():
                errors.append(f"external Akashic inventory must not be embedded in Fovea: {path_value}")
        elif not path.is_file():
            errors.append(f"inventory path missing: {path_value}")
        elif not isinstance(anchor, str) or anchor not in path.read_text():
            errors.append(f"inventory anchor drifted: {path_value} :: {anchor}")
        if not isinstance(item.get("classification"), str) or len(item["classification"]) < 8:
            errors.append(f"inventory classification missing for {symbol}")
        if not isinstance(item.get("target"), str) or not item["target"]:
            errors.append(f"inventory target missing for {symbol}")
    if observed_inventory != expected_inventory:
        errors.append(
            "post-extraction inventory drifted: "
            f"expected={expected_inventory} actual={observed_inventory}"
        )

    required_moves = {
        "NamespaceGenerationPersisting": "Sources/FoveaStorage/NamespaceGenerationPersisting.swift",
        "NamespaceStorageLimits": "Sources/FoveaStorage/NamespaceStorageLimits.swift",
        "StoredContentIdentifier": "Sources/FoveaStorage/StoredContentIdentifier.swift",
    }
    moves = document.get("packageInternalMoves", [])
    observed_moves: dict[str, str] = {}
    for move in moves:
        if not isinstance(move, dict):
            errors.append("packageInternalMoves entry must be an object")
            continue
        symbol = move.get("symbol")
        current_path = move.get("currentPath")
        if isinstance(symbol, str):
            observed_moves[symbol] = str(current_path)
        if not isinstance(current_path, str) or not (ROOT / current_path).is_file():
            errors.append(f"package internal move path missing: {current_path}")
        if not str(move.get("decision", "")).startswith("completed-"):
            errors.append(f"package internal move is not completed: {symbol}")
    if observed_moves != required_moves:
        errors.append(f"completed package moves drifted: {observed_moves}")

    target_contracts = document.get("targetContracts", [])
    target_symbols = {
        contract.get("symbol") for contract in target_contracts if isinstance(contract, dict)
    }
    required_targets = {
        "BlobDigest",
        "CachePartitionID",
        "PhysicalBlobID",
        "StoreGenerationID",
        "BlobStage",
        "BlobStoring",
        "TransactionalBlobStoring",
        "BlobStoreMaintaining",
    }
    if target_symbols != required_targets:
        errors.append(
            f"typed Akashic target contract set drifted: expected={sorted(required_targets)} "
            f"actual={sorted(str(item) for item in target_symbols)}"
        )
    for contract in target_contracts:
        if not isinstance(contract, dict):
            continue
        if contract.get("module") != "AkashicCore":
            errors.append(f"target contract {contract.get('symbol')} must remain in AkashicCore")
        if not isinstance(contract.get("mustNotKnow"), list) or not contract["mustNotKnow"]:
            errors.append(f"target contract {contract.get('symbol')} lacks mustNotKnow")

    files = sorted(path for root in AKASHIC_ROOTS for path in root.rglob("*.swift"))
    tracked = document.get("trackedDomainLeaks", [])
    expected_patterns = {
        "OriginalEncoded",
        "contentID",
        "namespace",
        "dev.fovea|fovea-storage",
    }
    observed_patterns: set[str] = set()
    leak_counts: dict[str, int] = {}
    for entry in tracked:
        if not isinstance(entry, dict):
            errors.append("trackedDomainLeaks entry must be an object")
            continue
        pattern = entry.get("pattern")
        if not isinstance(pattern, str) or not pattern or pattern in observed_patterns:
            errors.append(f"invalid or duplicate leak pattern: {pattern}")
            continue
        observed_patterns.add(pattern)
        if entry.get("allowedPaths") != []:
            errors.append(f"completed extraction must not retain allowed leak paths: {pattern}")
        if entry.get("status") != "zero-verified":
            errors.append(f"completed extraction leak status drifted: {pattern}")
        try:
            compiled = re.compile(pattern, re.IGNORECASE)
        except re.error as error:
            errors.append(f"invalid leak regex {pattern}: {error}")
            continue
        matches: list[str] = []
        for path in files:
            if compiled.search(path.read_text()):
                matches.append(relative(path))
        leak_counts[pattern] = len(matches)
        if matches:
            errors.append(f"Akashic domain leak {pattern!r} remains in {matches}")
        if not isinstance(entry.get("targetState"), str) or len(entry["targetState"]) < 12:
            errors.append(f"leak target state missing: {pattern}")
    if observed_patterns != expected_patterns:
        errors.append(
            f"tracked zero-leak patterns drifted: expected={sorted(expected_patterns)} "
            f"actual={sorted(observed_patterns)}"
        )

    storage_root = ROOT / "Sources/FoveaStorage"
    if not storage_root.is_dir():
        errors.append("FoveaStorage module is missing")
    else:
        for path in storage_root.rglob("*.swift"):
            text = path.read_text()
            for forbidden in ("import AkashicDisk", "import FoveaHTTP", "import FoveaCore", "import FoveaPersistence"):
                if forbidden in text:
                    errors.append(f"FoveaStorage dependency leak in {relative(path)}: {forbidden}")

    retired_fovea_files = (
        "OriginalEncodedStore.swift",
        "OriginalEncodedStoreIdentity.swift",
        "OriginalEncodedAccessJournal.swift",
        "OriginalEncodedPhysicalRemovalSummary.swift",
    )
    for retired in retired_fovea_files:
        if (ROOT / "Sources/FoveaPersistence" / retired).exists():
            errors.append(f"retired legacy Fovea store returned: {retired}")
    limits = ROOT / "Sources/FoveaPersistence/OriginalEncodedStoreLimits.swift"
    if not limits.is_file() or "package struct OriginalEncodedStoreLimits" not in limits.read_text():
        errors.append("typed adapter host limits must remain package-owned by FoveaPersistence")
    for obsolete in (
        "OriginalEncodedStore.swift",
        "OriginalEncodedStoreLimits.swift",
        "OriginalEncodedStoreIdentity.swift",
        "OriginalEncodedAccessJournal.swift",
        "OriginalEncodedPhysicalRemovalSummary.swift",
    ):
        if (ROOT / "Sources/AkashicDisk" / obsolete).exists():
            errors.append(f"legacy overlay returned to AkashicDisk: {obsolete}")

    disk = document.get("diskCompatibility", {})
    if disk.get("retiredLegacyOriginalEncodedSchemaVersion") != 4:
        errors.append("retired legacy schema history must remain recorded as version 4")
    if disk.get("currentTypedBlobSchemaVersion") != 1:
        errors.append("current typed blob schema version must remain 1")
    if disk.get("currentStoreGenerationSchemaVersion") != 1:
        errors.append("store generation schema version must remain 1")
    if disk.get("defaultIfUnproven") != "create-new-store-generation-and-rebuild-cache":
        errors.append("unproven compatibility must create a new generation")
    if document.get("deduplicationPolicy", {}).get("crossPartitionDeduplication") != (
        "forbidden-until-confidentiality-and-accounting-policy-is-explicit"
    ):
        errors.append("cross-partition deduplication must remain fail closed")

    host = document.get("hostMigration", {})
    if host.get("domainContractModule") != "FoveaStorage":
        errors.append("host domain contract module drifted")
    if host.get("domainLeakGate") != "zero-in-Akashic-production-source":
        errors.append("host domain leak gate drifted")
    if host.get("legacyOriginalEncodedStoreRemoved") is not True:
        errors.append("legacy OriginalEncodedStore removal must remain recorded")
    if host.get("embeddedAkashicSwiftFileCount") != 0:
        errors.append("embedded Akashic Swift file count must remain zero")
    for field in (
        "cleanCopyHostTestsPassed",
        "previousCompatibleRollbackHostTestsPassed",
        "forwardCurrentRecoveryHostTestsPassed",
    ):
        if host.get(field) != 475:
            errors.append(f"completed Akashic host drill count drifted: {field}")
    for root in AKASHIC_ROOTS:
        if root.exists():
            errors.append(f"embedded Akashic production source returned: {relative(root)}")
    obligations = host.get("obligations", {})
    for identifier in ("AKASHIC-CT-022", "AKASHIC-CT-023", "AKASHIC-CT-024", "AKASHIC-CT-025", "AKASHIC-CT-026"):
        if obligations.get(identifier) != "implemented-host-local":
            errors.append(f"host obligation drifted: {identifier}")

    blockers = document.get("extractionBlockers", [])
    if not isinstance(blockers, list) or len(blockers) < 5:
        errors.append("release blockers must remain explicit")

    result = {
        "schemaVersion": 1,
        "migrationID": document.get("migrationID"),
        "migrationSHA256": canonical_digest(document),
        "boundaryInventoryCount": len(inventory),
        "targetContractCount": len(target_contracts),
        "trackedLeakCounts": leak_counts,
        "status": "failed" if errors else "passed",
        "errors": errors,
    }
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic contract extraction: "
        f"inventory={len(inventory)} target={len(target_contracts)} "
        f"zeroLeakPatterns={len(observed_patterns)} errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
