#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


@dataclass(frozen=True)
class Mutant:
    identifier: str
    description: str
    source_file: str
    test_filter: str
    apply: Callable[[Path], None]


def replace_exact(path: Path, old: str, new: str, expected_count: int = 1) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != expected_count:
        raise RuntimeError(
            f"{path}: expected {expected_count} occurrence(s), found {count} for mutation pattern"
        )
    path.write_text(text.replace(old, new))


def mutant_001(root: Path) -> None:
    replace_exact(
        root / "Sources/FoveaCore/Identity.swift",
        "    encoder.append(namespace.value)\n",
        "    // AIQA-MUT-001: namespace deliberately omitted.\n",
    )


def mutant_002(root: Path) -> None:
    replace_exact(
        root / "Sources/FoveaCore/FoveaPipeline.swift",
        """      credentialGeneration: credentialGeneration,
      revalidationFingerprint: revalidationFingerprint
""",
        """      credentialGeneration: nil,
      revalidationFingerprint: "variant-only"
""",
    )


def mutant_007(root: Path) -> None:
    replace_exact(
        root / "Sources/FoveaCore/FoveaPipeline.swift",
        "    if disposition != .noStore {\n",
        "    if true {\n",
    )


def mutant_008(root: Path) -> None:
    pipeline = root / "Sources/FoveaCore/FoveaPipeline.swift"
    replace_exact(
        pipeline,
        """    guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
      throw FoveaError.namespaceRevoked
    }
""",
        """    guard await namespaceRegistry.isActive(generation, for: request.namespace) || true else {
      throw FoveaError.namespaceRevoked
    }
""",
    )
    replace_exact(
        pipeline,
        """        guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
          throw FoveaError.namespaceRevoked
        }
""",
        """        guard await namespaceRegistry.isActive(generation, for: request.namespace) || true else {
          throw FoveaError.namespaceRevoked
        }
""",
    )


def mutant_009(root: Path) -> None:
    replace_exact(
        root / "Sources/ImageCraftCore/ImageTypes.swift",
        "    guard width > 0, height > 0 else { throw ImageCraftError.invalidTarget }\n",
        "    guard width >= 0, height >= 0 else { throw ImageCraftError.invalidTarget }\n",
    )


def mutant_015(root: Path) -> None:
    replace_exact(
        root / "Sources/FoveaCore/FoveaPipeline.swift",
        "    let probe = try decoder.probe(data: data, limits: configuration.decodeLimits)\n",
        """    let probe: ImageProbe
    do {
      probe = try decoder.probe(data: data, limits: configuration.decodeLimits)
    } catch {
      let contentID = ContentID(data: data)
      _ = try? await encodedStore.commit(
        data: data,
        contentID: contentID.description,
        namespace: request.namespace.value
      )
      try? await recordStore.put(
        RepresentationRecord(
          variantKeyDigest: keyDigest,
          statusCode: 200,
          requestTime: Date(),
          responseTime: Date(),
          expiresAt: nil,
          etag: nil,
          lastModified: nil,
          disposition: .reusable,
          contentID: contentID.description,
          payloadLength: data.count,
          contentType: nil
        )
      )
      throw error
    }
""",
    )


MUTANTS = [
    Mutant(
        "AIQA-MUT-001",
        "Remove SecurityNamespaceID from persistent request identity.",
        "Sources/FoveaCore/Identity.swift",
        "IdentityTests/testNamespaceChangesVariantIdentity_CACHE_PT_003",
        mutant_001,
    ),
    Mutant(
        "AIQA-MUT-002",
        "Collapse exact fetch execution identity to variant-only dimensions.",
        "Sources/FoveaCore/FoveaPipeline.swift",
        "IdentityTests/testImageRequestExecutionKeyIncludesCredentialAndRevalidation",
        mutant_002,
    ),
    Mutant(
        "AIQA-MUT-007",
        "Allow Cache-Control no-store responses into reusable caches.",
        "Sources/FoveaCore/FoveaPipeline.swift",
        "PipelineTests/testNoStoreNeverSatisfiesNewRequest_CACHE_PT_026",
        mutant_007,
    ),
    Mutant(
        "AIQA-MUT-008",
        "Allow commit after namespace generation revocation.",
        "Sources/FoveaCore/FoveaPipeline.swift",
        "PipelineTests/testRevokedGenerationCannotCommit_CACHE_PT_015_AIQA_MUT_008",
        mutant_008,
    ),
    Mutant(
        "AIQA-MUT-009",
        "Accept an unknown or zero target and permit original-size decode entry.",
        "Sources/ImageCraftCore/ImageTypes.swift",
        "IdentityTests/testZeroTargetIsRejected_GEO_PT_002",
        mutant_009,
    ),
    Mutant(
        "AIQA-MUT-015",
        "Publish OriginalEncoded metadata after probe rejection.",
        "Sources/FoveaCore/FoveaPipeline.swift",
        "PipelineTests/testProbeFailureDoesNotPublishRecord_CACHE_PT_029_AIQA_MUT_015",
        mutant_015,
    ),
]


def run(command: list[str], cwd: Path, env: dict[str, str], timeout: int) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )


def command_output(command: list[str], cwd: Path, env: dict[str, str]) -> str:
    completed = run(command, cwd, env, timeout=60)
    if completed.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(command)}\n{completed.stdout}")
    return completed.stdout.strip()


def classify(return_code: int, output: str) -> str:
    test_executed = "Test Case '" in output and " started." in output
    if return_code == 0:
        return "survived"
    if test_executed:
        return "killed"
    return "invalid"


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Fovea Phase 0a curated critical mutants.")
    parser.add_argument(
        "--output-dir",
        default=".artifacts/mutation",
        help="Directory for logs and the machine-readable report.",
    )
    parser.add_argument("--timeout", type=int, default=240, help="Per-mutant timeout in seconds.")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    output_dir = (root / args.output_dir).resolve()
    logs_dir = output_dir / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    if not env.get("DEVELOPER_DIR"):
        selector = root / "scripts/select-xcode.sh"
        env["DEVELOPER_DIR"] = command_output([str(selector)], root, env)

    head = command_output(["git", "rev-parse", "HEAD"], root, env)
    xcode_version = command_output(["xcodebuild", "-version"], root, env).replace("\n", " | ")
    swift_version = command_output(["xcrun", "swift", "--version"], root, env).splitlines()[0]

    temporary_root = Path(tempfile.mkdtemp(prefix="fovea-critical-mutants-"))
    worktree = temporary_root / "worktree"
    results: list[dict[str, object]] = []
    try:
        added = run(
            ["git", "worktree", "add", "--detach", str(worktree), head],
            root,
            env,
            timeout=120,
        )
        if added.returncode != 0:
            raise RuntimeError(f"unable to create mutation worktree\n{added.stdout}")

        for mutant in MUTANTS:
            subprocess.run(
                ["git", "reset", "--hard", head],
                cwd=worktree,
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=True,
            )
            subprocess.run(
                ["git", "clean", "-fdx"],
                cwd=worktree,
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=True,
            )

            mutant.apply(worktree)
            scratch = temporary_root / f"scratch-{mutant.identifier.lower()}"
            command = [
                "xcrun",
                "swift",
                "test",
                "--package-path",
                str(worktree),
                "--scratch-path",
                str(scratch),
                "--filter",
                mutant.test_filter,
            ]
            timed_out = False
            try:
                completed = run(command, root, env, timeout=args.timeout)
                output = completed.stdout
                return_code = completed.returncode
            except subprocess.TimeoutExpired as error:
                timed_out = True
                output = (error.stdout or "") + "\nMUTANT TIMED OUT\n"
                return_code = 124

            status = "invalid" if timed_out else classify(return_code, output)
            log_path = logs_dir / f"{mutant.identifier}.log"
            log_path.write_text(output)
            log_digest = hashlib.sha256(log_path.read_bytes()).hexdigest()
            results.append(
                {
                    "id": mutant.identifier,
                    "description": mutant.description,
                    "sourceFile": mutant.source_file,
                    "testFilter": mutant.test_filter,
                    "status": status,
                    "exitCode": return_code,
                    "logPath": str(log_path.relative_to(root)),
                    "logSha256": log_digest,
                }
            )
            print(f"{mutant.identifier}: {status} ({mutant.test_filter})")
    finally:
        if worktree.exists():
            subprocess.run(
                ["git", "worktree", "remove", "--force", str(worktree)],
                cwd=root,
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        subprocess.run(
            ["git", "worktree", "prune"],
            cwd=root,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        shutil.rmtree(temporary_root, ignore_errors=True)

    killed = sum(result["status"] == "killed" for result in results)
    report = {
        "schemaVersion": 1,
        "verifiedCommit": head,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "producer": os.environ.get("FOVEA_EVIDENCE_PRODUCER", "agent-declared"),
        "xcodeVersion": xcode_version,
        "swiftVersion": swift_version,
        "requiredMutants": [mutant.identifier for mutant in MUTANTS],
        "summary": {
            "required": len(MUTANTS),
            "killed": killed,
            "survived": sum(result["status"] == "survived" for result in results),
            "invalid": sum(result["status"] == "invalid" for result in results),
        },
        "mutants": results,
    }
    report_path = output_dir / "critical-mutants.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    report_digest = hashlib.sha256(report_path.read_bytes()).hexdigest()
    print(f"Mutation report: {report_path.relative_to(root)} sha256:{report_digest}")

    if killed != len(MUTANTS):
        print("Critical mutation gate failed", file=sys.stderr)
        return 1
    print("Critical mutation gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
