#!/usr/bin/env python3
"""Verify Fovea against materialized, Git-free component release candidates."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass, replace
from pathlib import Path, PurePosixPath
from typing import Any

from component_candidate_sandbox import (
    BUILD_SYSTEM,
    POLICY_ID,
    SandboxLayout,
    prepare_state_environment,
    profile_digest,
    render_profile,
    run_escape_probes,
    sandbox_command,
    swiftpm_state_options,
)

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / ".artifacts/external-components/candidate-clean-copy.json"
LOG = ROOT / ".artifacts/external-components/candidate-clean-copy-swift-test.log"
SANDBOX_ARTIFACT = ROOT / ".artifacts/external-components/candidate-sandbox-probes.json"
COPY_PATHS = ("Sources", "Tests", "Tools", "Examples/FoveaGalleryDemo")
EXPECTED_TEST_COUNT = 478


@dataclass(frozen=True)
class ComponentCandidate:
    package_identity: str
    source: Path
    identity_id: str
    identity_document: Path
    required_top_level: frozenset[str]
    excluded_top_level: frozenset[str]
    excluded_subtrees: tuple[str, ...]
    excluded_anywhere: frozenset[str]


def run(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout: int = 1200,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
        timeout=timeout,
    )


def read_stable_file(path: Path) -> tuple[bytes, bool]:
    with path.open("rb") as handle:
        before = os.fstat(handle.fileno())
        data = handle.read()
        after = os.fstat(handle.fileno())
    before_identity = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
        before.st_mode,
    )
    after_identity = (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
        after.st_mode,
    )
    if before_identity != after_identity or len(data) != after.st_size:
        raise RuntimeError(f"source file changed while reading candidate: {path}")
    return data, bool(after.st_mode & 0o111)


def file_digest(root: Path) -> str:
    rows: list[bytes] = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        if any(part in {".build", ".swiftpm", ".artifacts"} for part in path.parts):
            continue
        relative = path.relative_to(root).as_posix()
        rows.append(
            relative.encode()
            + b"\0"
            + hashlib.sha256(path.read_bytes()).hexdigest().encode()
            + b"\n"
        )
    return hashlib.sha256(b"".join(rows)).hexdigest()


def immutable_fovea_digest(root: Path) -> str:
    rows: list[bytes] = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root).as_posix()
        if relative == "Package.resolved" or relative.startswith("Packages/"):
            continue
        if any(part in {".build", ".swiftpm", ".artifacts"} for part in path.parts):
            continue
        data, executable = read_stable_file(path)
        rows.append(
            relative.encode()
            + b"\0"
            + hashlib.sha256(data).hexdigest().encode()
            + b"\0"
            + (b"x" if executable else b"-")
            + b"\n"
        )
    return hashlib.sha256(b"".join(rows)).hexdigest()


def copy_source(destination: Path) -> None:
    for relative in ("Package.swift", "Package.resolved"):
        shutil.copy2(ROOT / relative, destination / relative)
    for relative in COPY_PATHS:
        shutil.copytree(
            ROOT / relative,
            destination / relative,
            ignore=shutil.ignore_patterns(
                ".DS_Store", ".build", ".swiftpm", ".artifacts", "__pycache__", "*.pyc"
            ),
        )


def find_dependency(value: Any, identity: str) -> dict[str, Any] | None:
    if isinstance(value, dict):
        if str(value.get("identity", "")).lower() == identity.lower():
            return value
        for child in value.values():
            found = find_dependency(child, identity)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_dependency(child, identity)
            if found is not None:
                return found
    return None


def validate_identity_manifest(
    candidate: ComponentCandidate, identity: dict[str, Any]
) -> None:
    if identity.get("schemaVersion") != 2:
        raise RuntimeError(
            f"{candidate.package_identity} candidate source identity schema drifted"
        )
    coverage = identity.get("coverage")
    if not isinstance(coverage, dict):
        raise RuntimeError(
            f"{candidate.package_identity} candidate source identity coverage is missing"
        )
    if coverage.get("mode") != "explicit-top-level-complete-v2":
        raise RuntimeError(
            f"{candidate.package_identity} candidate source identity coverage mode drifted"
        )
    included_top_level = coverage.get("includedTopLevel")
    excluded_top_level = coverage.get("excludedTopLevel")
    excluded_subtrees = coverage.get("excludedSubtrees")
    excluded_anywhere = coverage.get("excludedAnywhere")
    expected_included = sorted(candidate.required_top_level)
    expected_excluded_top_level = sorted(candidate.excluded_top_level)
    expected_excluded_subtrees = sorted(candidate.excluded_subtrees)
    expected_excluded_anywhere = sorted(candidate.excluded_anywhere)
    if included_top_level != expected_included:
        raise RuntimeError(
            f"{candidate.package_identity} candidate identity coverage roots drifted: "
            f"expected={expected_included!r} observed={included_top_level!r}"
        )
    if excluded_top_level != expected_excluded_top_level:
        raise RuntimeError(
            f"{candidate.package_identity} candidate top-level exclusions drifted: "
            f"expected={expected_excluded_top_level!r} observed={excluded_top_level!r}"
        )
    if excluded_subtrees != expected_excluded_subtrees:
        raise RuntimeError(
            f"{candidate.package_identity} candidate excluded subtrees drifted: "
            f"expected={expected_excluded_subtrees!r} observed={excluded_subtrees!r}"
        )
    if excluded_anywhere != expected_excluded_anywhere:
        raise RuntimeError(
            f"{candidate.package_identity} candidate recursive exclusions drifted: "
            f"expected={expected_excluded_anywhere!r} observed={excluded_anywhere!r}"
        )

    unexpected_top_level = sorted(
        item.name
        for item in candidate.source.iterdir()
        if item.name not in candidate.required_top_level
        and item.name not in candidate.excluded_top_level
        and item.name not in candidate.excluded_anywhere
    )
    if unexpected_top_level:
        raise RuntimeError(
            f"{candidate.package_identity} candidate contains unbound top-level entries: "
            + ", ".join(unexpected_top_level)
        )

    expected_paths: list[str] = []
    for name in expected_included:
        path = candidate.source / name
        if path.is_symlink():
            raise RuntimeError(
                f"{candidate.package_identity} candidate identity rejects symbolic links: {name!r}"
            )
        if path.is_file():
            expected_paths.append(name)
            continue
        if not path.is_dir():
            raise RuntimeError(
                f"{candidate.package_identity} candidate identity coverage root is missing: {name!r}"
            )
        excluded_subtree_parts = tuple(
            tuple(Path(value).parts) for value in candidate.excluded_subtrees
        )
        for item in sorted(path.rglob("*")):
            relative = item.relative_to(candidate.source)
            if any(
                relative.parts[: len(parts)] == parts
                for parts in excluded_subtree_parts
            ):
                continue
            if any(part in candidate.excluded_anywhere for part in relative.parts):
                continue
            reserved = next(
                (part for part in relative.parts if part in candidate.excluded_top_level),
                None,
            )
            if reserved is not None:
                raise RuntimeError(
                    f"{candidate.package_identity} candidate rejects nested top-level "
                    f"exclusion name {reserved!r} at {relative.as_posix()!r}"
                )
            if item.is_symlink():
                raise RuntimeError(
                    f"{candidate.package_identity} candidate identity rejects symbolic links: "
                    f"{relative.as_posix()!r}"
                )
            if item.is_file():
                expected_paths.append(relative.as_posix())
            elif not item.is_dir():
                raise RuntimeError(
                    f"{candidate.package_identity} candidate identity rejects unsupported "
                    f"filesystem entry: {relative.as_posix()!r}"
                )
    expected_paths.sort()

    entries = identity.get("files")
    if not isinstance(entries, list):
        raise RuntimeError(
            f"{candidate.package_identity} candidate source identity files are missing"
        )
    if identity.get("fileCount") != len(entries):
        raise RuntimeError(
            f"{candidate.package_identity} candidate source identity file count is inconsistent"
        )

    observed_paths: list[str] = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise RuntimeError(
                f"{candidate.package_identity} candidate source identity entry is invalid"
            )
        relative_value = entry.get("path")
        byte_count = entry.get("byteCount")
        digest = entry.get("sha256")
        executable = entry.get("executable")
        if not isinstance(relative_value, str) or not relative_value:
            raise RuntimeError(
                f"{candidate.package_identity} candidate source identity path is invalid"
            )
        relative = PurePosixPath(relative_value)
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or "\\" in relative_value
            or relative.as_posix() != relative_value
        ):
            raise RuntimeError(
                f"{candidate.package_identity} candidate source identity path escapes its root: "
                f"{relative_value!r}"
            )
        if not isinstance(byte_count, int) or isinstance(byte_count, bool) or byte_count < 0:
            raise RuntimeError(
                f"{candidate.package_identity} candidate byte count is invalid for "
                f"{relative_value!r}"
            )
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise RuntimeError(
                f"{candidate.package_identity} candidate file digest is invalid for "
                f"{relative_value!r}"
            )
        if not isinstance(executable, bool):
            raise RuntimeError(
                f"{candidate.package_identity} candidate executable flag is invalid for "
                f"{relative_value!r}"
            )

        lexical = candidate.source / Path(*relative.parts)
        if lexical.is_symlink():
            raise RuntimeError(
                f"{candidate.package_identity} candidate identity rejects symbolic links: "
                f"{relative_value!r}"
            )
        resolved = lexical.resolve()
        try:
            resolved.relative_to(candidate.source)
        except ValueError as error:
            raise RuntimeError(
                f"{candidate.package_identity} candidate source identity path escapes its root: "
                f"{relative_value!r}"
            ) from error
        if not resolved.is_file():
            raise RuntimeError(
                f"{candidate.package_identity} candidate identity references a missing file: "
                f"{relative_value!r}"
            )
        data, actual_executable = read_stable_file(resolved)
        if len(data) != byte_count:
            raise RuntimeError(
                f"{candidate.package_identity} candidate byte count drifted for "
                f"{relative_value!r}"
            )
        actual_digest = hashlib.sha256(data).hexdigest()
        if actual_digest != digest:
            raise RuntimeError(
                f"{candidate.package_identity} candidate file digest drifted for "
                f"{relative_value!r}"
            )
        if actual_executable != executable:
            raise RuntimeError(
                f"{candidate.package_identity} candidate executable flag drifted for "
                f"{relative_value!r}"
            )
        observed_paths.append(relative_value)

    if observed_paths != sorted(observed_paths) or len(observed_paths) != len(set(observed_paths)):
        raise RuntimeError(
            f"{candidate.package_identity} candidate source identity paths are not unique and sorted"
        )
    if observed_paths != expected_paths:
        missing = sorted(set(expected_paths).difference(observed_paths))
        extra = sorted(set(observed_paths).difference(expected_paths))
        raise RuntimeError(
            f"{candidate.package_identity} candidate identity coverage is incomplete: "
            f"missing={missing!r} extra={extra!r}"
        )

    canonical_payload = json.dumps(
        {
            "schemaVersion": identity["schemaVersion"],
            "identityID": identity["identityID"],
            "coverage": coverage,
            "files": entries,
        },
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    canonical_digest = hashlib.sha256(canonical_payload).hexdigest()
    if identity.get("sourceIdentitySHA256") != canonical_digest:
        raise RuntimeError(
            f"{candidate.package_identity} candidate source identity digest does not match its manifest"
        )


def materialize_candidate_snapshot(
    candidate: ComponentCandidate,
    identity: dict[str, Any],
    destination: Path,
) -> ComponentCandidate:
    if destination.exists():
        raise FileExistsError(destination)
    destination.mkdir(parents=True)

    for name in candidate.required_top_level:
        source_root = candidate.source / name
        if source_root.is_dir():
            (destination / name).mkdir(parents=True, exist_ok=True)

    files = identity["files"]
    for entry in files:
        relative = PurePosixPath(entry["path"])
        source = candidate.source / Path(*relative.parts)
        data, executable = read_stable_file(source)
        if len(data) != entry["byteCount"]:
            raise RuntimeError(
                f"{candidate.package_identity} candidate changed during snapshot: "
                f"byte count {entry['path']!r}"
            )
        if hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise RuntimeError(
                f"{candidate.package_identity} candidate changed during snapshot: "
                f"digest {entry['path']!r}"
            )
        if executable != entry["executable"]:
            raise RuntimeError(
                f"{candidate.package_identity} candidate changed during snapshot: "
                f"executable flag {entry['path']!r}"
            )
        target = destination / Path(*relative.parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        target.chmod(0o755 if executable else 0o644)

    snapshot_candidate = replace(candidate, source=destination.resolve())
    validate_identity_manifest(snapshot_candidate, identity)
    return snapshot_candidate


def load_candidate_identity(candidate: ComponentCandidate) -> dict[str, Any]:
    if not candidate.identity_document.is_file():
        raise RuntimeError(
            f"{candidate.package_identity} candidate identity document is missing"
        )
    identity = json.loads(candidate.identity_document.read_text())
    if identity.get("identityID") != candidate.identity_id:
        raise RuntimeError(
            f"{candidate.package_identity} candidate identity ID drifted: "
            f"expected={candidate.identity_id!r} observed={identity.get('identityID')!r}"
        )
    validate_identity_manifest(candidate, identity)
    return identity


def candidate_from_argument(
    package_identity: str,
    source: Path | None,
    identity_document: Path | None,
    identity_id: str,
    required_top_level: frozenset[str],
    excluded_top_level: frozenset[str],
    excluded_subtrees: tuple[str, ...],
    excluded_anywhere: frozenset[str],
) -> ComponentCandidate | None:
    if source is None and identity_document is None:
        return None
    if source is None or identity_document is None:
        raise ValueError(
            f"{package_identity} requires both source and identity document"
        )
    resolved = source.expanduser().resolve()
    resolved_identity = identity_document.expanduser().resolve()
    return ComponentCandidate(
        package_identity=package_identity,
        source=resolved,
        identity_id=identity_id,
        identity_document=resolved_identity,
        required_top_level=required_top_level,
        excluded_top_level=excluded_top_level,
        excluded_subtrees=excluded_subtrees,
        excluded_anywhere=excluded_anywhere,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--akashic-source", type=Path)
    parser.add_argument("--akashic-identity", type=Path)
    parser.add_argument("--imagecraft-source", type=Path)
    parser.add_argument("--imagecraft-identity", type=Path)
    parser.add_argument("--expected-test-count", type=int, default=EXPECTED_TEST_COUNT)
    parser.add_argument(
        "--identity-only",
        action="store_true",
        help="validate candidate identities without resolving or building Fovea",
    )
    args = parser.parse_args()

    excluded_top_level = frozenset({".artifacts", ".build", ".git", ".swiftpm"})
    excluded_anywhere = frozenset({"__pycache__", ".DS_Store"})
    candidates = tuple(
        candidate
        for candidate in (
            candidate_from_argument(
                "Akashic",
                args.akashic_source,
                args.akashic_identity,
                "AKASHIC-SOURCE-IDENTITY-V2",
                frozenset(
                    {
                        ".gitignore", ".github", "API", "CONTRIBUTING.md", "Fixtures",
                        "LICENSE", "Package.swift", "README.md", "ROADMAP.md", "SECURITY.md",
                        "Sources", "Tests", "Tools", "docs", "scripts",
                    }
                ),
                excluded_top_level,
                (),
                excluded_anywhere,
            ),
            candidate_from_argument(
                "ImageCraft",
                args.imagecraft_source,
                args.imagecraft_identity,
                "IMAGECRAFT-SOURCE-IDENTITY-V2",
                frozenset(
                    {
                        ".gitignore", ".github", "API", "CONTRIBUTING.md", "Evidence",
                        "Fixtures", "Integration", "LICENSE", "Package.swift", "README.md",
                        "ROADMAP.md", "SECURITY.md", "Sources", "Tests", "Tools", "docs",
                        "scripts",
                    }
                ),
                excluded_top_level,
                (
                    "Fixtures/ConsumerSmoke/.build",
                    "Fixtures/ConsumerSmoke/.swiftpm",
                ),
                excluded_anywhere,
            ),
        )
        if candidate is not None
    )
    if not candidates:
        parser.error("at least one component candidate source is required")

    env = os.environ.copy()
    try:
        identities: dict[str, dict[str, Any]] = {}
        for candidate in candidates:
            if not (candidate.source / "Package.swift").is_file():
                raise RuntimeError(
                    f"{candidate.package_identity} candidate is not a Swift package"
                )
            if (candidate.source / ".git").exists():
                raise RuntimeError(
                    f"{candidate.package_identity} candidate must be a materialized Git-free source copy"
                )
            identities[candidate.package_identity] = load_candidate_identity(candidate)

        if args.identity_only:
            summary = ", ".join(
                f"{candidate.package_identity}="
                f"{identities[candidate.package_identity]['sourceIdentitySHA256'][:12]}"
                for candidate in candidates
            )
            print("Component candidate identities passed: " + summary)
            return 0

        selection = run(
            [str(ROOT / "scripts/select-xcode.sh")],
            cwd=ROOT,
            env=env,
            timeout=30,
        )
        if selection.returncode != 0:
            raise RuntimeError("Xcode selection failed:\n" + selection.stdout)
        env["DEVELOPER_DIR"] = selection.stdout.strip()
        swift_lookup = run(
            ["xcrun", "--find", "swift"],
            cwd=ROOT,
            env=env,
            timeout=30,
        )
        if swift_lookup.returncode != 0:
            raise RuntimeError("Swift executable lookup failed:\n" + swift_lookup.stdout)
        swift = swift_lookup.stdout.strip()
        if not Path(swift).is_file():
            raise RuntimeError(f"Swift executable is missing: {swift!r}")

        host_home = Path.home().resolve()
        host_read_target = (ROOT / "Package.swift").resolve()
        outside_write_target = (
            ROOT / ".artifacts/external-components/sandbox-write-escape-probe"
        )
        with tempfile.TemporaryDirectory(prefix="fovea-component-candidate-copy-") as directory:
            temporary_root = Path(directory).resolve()
            snapshot_root = temporary_root / "Candidates"
            snapshot_root.mkdir()
            snapshots = tuple(
                materialize_candidate_snapshot(
                    candidate,
                    identities[candidate.package_identity],
                    snapshot_root / candidate.package_identity,
                )
                for candidate in candidates
            )

            copy = temporary_root / "Fovea"
            copy.mkdir()
            copy_source(copy)
            source_digest = file_digest(copy)
            immutable_source_digest_before = immutable_fovea_digest(copy)

            state_root = temporary_root / "State"
            state_root.mkdir()
            layout = SandboxLayout.create(
                temporary_root=temporary_root,
                fovea_source=copy,
                state_root=state_root,
                candidate_sources=[candidate.source for candidate in snapshots],
                host_home=host_home,
            )
            sandbox_env = prepare_state_environment(layout, env)
            state_options = swiftpm_state_options(layout)

            resolve = run(
                [
                    swift,
                    "package",
                    "--package-path",
                    str(copy),
                    *state_options,
                    "resolve",
                ],
                cwd=temporary_root,
                env=sandbox_env,
            )
            if resolve.returncode != 0:
                raise RuntimeError(
                    "candidate-copy trusted-pin dependency resolution failed:\n"
                    + resolve.stdout
                )

            (copy / "Packages").mkdir(exist_ok=True)
            profile_text = render_profile(layout)
            profile_path = state_root / "candidate-sandbox.sb"
            profile_path.write_text(profile_text)
            sandbox_probe_report = run_escape_probes(
                layout=layout,
                profile_path=profile_path,
                environment=sandbox_env,
                host_read_target=host_read_target,
                outside_write_target=outside_write_target,
            )
            SANDBOX_ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
            SANDBOX_ARTIFACT.write_text(
                json.dumps(sandbox_probe_report, indent=2, sort_keys=True) + "\n"
            )

            for candidate in snapshots:
                edit = run(
                    sandbox_command(
                        profile_path,
                        [
                            swift,
                            "package",
                            "--package-path",
                            str(copy),
                            *state_options,
                            "edit",
                            candidate.package_identity,
                            "--path",
                            str(candidate.source),
                        ],
                    ),
                    cwd=temporary_root,
                    env=sandbox_env,
                )
                if edit.returncode != 0:
                    raise RuntimeError(
                        f"candidate-copy sandboxed {candidate.package_identity} edit failed:\n"
                        + edit.stdout
                    )

            dependencies = run(
                sandbox_command(
                    profile_path,
                    [
                        swift,
                        "package",
                        "--package-path",
                        str(copy),
                        *state_options,
                        "show-dependencies",
                        "--format",
                        "json",
                    ],
                ),
                cwd=temporary_root,
                env=sandbox_env,
            )
            if dependencies.returncode != 0:
                raise RuntimeError(
                    "candidate-copy sandboxed dependency inspection failed:\n"
                    + dependencies.stdout
                )
            dependency_tree = json.loads(dependencies.stdout)
            for candidate in snapshots:
                dependency = find_dependency(dependency_tree, candidate.package_identity)
                observed_path = Path(str((dependency or {}).get("path", ""))).resolve()
                if dependency is None or observed_path != candidate.source:
                    raise RuntimeError(
                        f"candidate-copy did not resolve {candidate.package_identity} "
                        "to the supplied validated snapshot"
                    )

            test = run(
                sandbox_command(
                    profile_path,
                    [
                        swift,
                        "test",
                        "--package-path",
                        str(copy),
                        "--build-system",
                        BUILD_SYSTEM,
                        *state_options,
                        "--manifest-cache",
                        "local",
                    ],
                ),
                cwd=temporary_root,
                env=sandbox_env,
            )
            LOG.parent.mkdir(parents=True, exist_ok=True)
            LOG.write_text(test.stdout)
            if test.returncode != 0:
                raise RuntimeError(
                    "candidate-copy sandboxed tests failed; see "
                    + str(LOG.relative_to(ROOT))
                )
            owned_roots = tuple(
                str(copy / prefix) for prefix in ("Sources", "Tests", "Tools", "Examples")
            )
            owned_warnings = [
                line
                for line in test.stdout.splitlines()
                if "warning:" in line.lower() and line.startswith(owned_roots)
            ]
            if owned_warnings:
                raise RuntimeError(
                    "candidate-copy emitted Fovea-owned warnings: " + repr(owned_warnings)
                )
            counts = [int(value) for value in re.findall(r"Executed (\d+) tests", test.stdout)]
            count = max(counts, default=0)
            if count != args.expected_test_count:
                raise RuntimeError(
                    "candidate-copy sandboxed test count drifted: "
                    f"expected={args.expected_test_count} observed={count}"
                )

            immutable_source_digest_after = immutable_fovea_digest(copy)
            if immutable_source_digest_after != immutable_source_digest_before:
                raise RuntimeError(
                    "candidate-copy modified immutable Fovea source during sandboxed execution"
                )
            for candidate in snapshots:
                validate_identity_manifest(
                    candidate, identities[candidate.package_identity]
                )
            runtime_profile_sha256 = profile_digest(profile_text)
    except (
        OSError,
        ValueError,
        KeyError,
        json.JSONDecodeError,
        RuntimeError,
        subprocess.TimeoutExpired,
    ) as error:
        print(str(error))
        return 1

    report = {
        "schemaVersion": 4,
        "status": "passed",
        "testCount": args.expected_test_count,
        "foveaSourceDigest": source_digest,
        "foveaImmutableSourceDigest": immutable_source_digest_before,
        "foveaImmutableSourcePostDigest": immutable_source_digest_after,
        "componentCandidates": {
            candidate.package_identity: {
                "fileCount": identities[candidate.package_identity]["fileCount"],
                "identityID": identities[candidate.package_identity]["identityID"],
                "coverageMode": identities[candidate.package_identity]["coverage"]["mode"],
                "completeCoverageVerified": True,
                "identityEnvelopeBound": True,
                "candidateIdentityToolExecuted": False,
                "executableBitsBound": True,
                "nestedTopLevelExclusionsRejected": True,
                "excludedSubtrees": identities[candidate.package_identity]["coverage"][
                    "excludedSubtrees"
                ],
                "sourceIdentitySHA256": identities[candidate.package_identity][
                    "sourceIdentitySHA256"
                ],
                "identityDocumentSHA256": hashlib.sha256(
                    candidate.identity_document.read_bytes()
                ).hexdigest(),
                "gitMetadataPresent": False,
            }
            for candidate in candidates
        },
        "dependencyMode": "local-git-free-validated-snapshot-seatbelt",
        "candidateSnapshotMaterialized": True,
        "postBuildIdentityRevalidated": True,
        "swiftPackageEditSourceIsValidatedSnapshot": True,
        "candidateManifestExecutionBeforeSandbox": False,
        "preSandboxResolveScope": "trusted-public-exact-pins-only",
        "isolation": {
            "policyID": POLICY_ID,
            "osSandbox": "macOS-seatbelt",
            "osSandboxApplied": True,
            "buildSystem": BUILD_SYSTEM,
            "nativeBuildSystemDeprecated": True,
            "networkDenied": sandbox_probe_report["networkDenied"],
            "hostSourceReadDenied": sandbox_probe_report["hostSourceReadDenied"],
            "hostWriteEscapeDenied": sandbox_probe_report["hostWriteEscapeDenied"],
            "isolatedFoveaSourceWriteDenied": sandbox_probe_report[
                "isolatedFoveaSourceWriteDenied"
            ],
            "candidateSnapshotWritesDenied": sandbox_probe_report[
                "candidateSnapshotWritesDenied"
            ],
            "dedicatedStateWriteAllowed": sandbox_probe_report[
                "dedicatedStateWriteAllowed"
            ],
            "candidateCanReadIsolatedFoveaSource": True,
            "mutualConfidentialityClaim": False,
            "defaultSwiftBuildSandboxQualification": False,
        },
        "verificationMaterials": {
            "candidateVerifierSHA256": hashlib.sha256(
                Path(__file__).read_bytes()
            ).hexdigest(),
            "negativeVerifierSHA256": hashlib.sha256(
                (ROOT / "scripts/verify-component-candidate-identity-negatives.py").read_bytes()
            ).hexdigest(),
            "identitySpecificationSHA256": hashlib.sha256(
                (ROOT / "docs/specifications/component-candidate-identity.md").read_bytes()
            ).hexdigest(),
            "sandboxPolicyModuleSHA256": hashlib.sha256(
                (ROOT / "scripts/component_candidate_sandbox.py").read_bytes()
            ).hexdigest(),
            "runtimeSandboxProfileSHA256": runtime_profile_sha256,
            "sandboxProbeReportSHA256": hashlib.sha256(
                SANDBOX_ARTIFACT.read_bytes()
            ).hexdigest(),
        },
        "publicRevisionClaim": False,
        "trustedCIClaim": False,
    }
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    summary = ", ".join(
        f"{candidate.package_identity}="
        f"{identities[candidate.package_identity]['sourceIdentitySHA256'][:12]}"
        for candidate in candidates
    )
    print(
        "External component candidate copy passed: "
        f"tests={args.expected_test_count} {summary}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
