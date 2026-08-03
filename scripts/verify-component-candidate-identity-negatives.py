#!/usr/bin/env python3
"""Retain negative probes for component source-identity completeness and execution safety."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "scripts/verify-component-candidate-clean-copy.py"
ARTIFACT = ROOT / ".artifacts/external-components/candidate-identity-negatives.json"


def run(command: list[str], *, cwd: Path, timeout: int = 120) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
        timeout=timeout,
    )


def canonical_digest(document: dict[str, object]) -> str:
    payload = json.dumps(
        {
            "schemaVersion": document["schemaVersion"],
            "identityID": document["identityID"],
            "coverage": document["coverage"],
            "files": document["files"],
        },
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(payload).hexdigest()


def materialize(
    component: str,
    source: Path,
    destination: Path,
    identity_path: Path,
) -> dict[str, object]:
    capture = source / "Tools/Identity/capture_source_identity.py"
    materializer = source / "Tools/Identity/materialize_clean_copy.py"
    captured = run(
        [sys.executable, str(capture), "--output", str(identity_path)],
        cwd=source,
    )
    if captured.returncode != 0:
        raise RuntimeError(f"{component} identity capture failed:\n{captured.stdout}")
    copied = run(
        [
            sys.executable,
            str(materializer),
            "--source-root",
            str(source),
            "--identity",
            str(identity_path),
            "--destination",
            str(destination),
        ],
        cwd=source,
    )
    if copied.returncode != 0:
        raise RuntimeError(f"{component} materialization failed:\n{copied.stdout}")
    return json.loads(identity_path.read_text())


def expect_rejection(
    *,
    name: str,
    expected_fragments: tuple[str, ...],
    akashic: tuple[Path, Path] | None = None,
    imagecraft: tuple[Path, Path] | None = None,
) -> dict[str, object]:
    command = [sys.executable, str(GATE), "--identity-only"]
    if akashic is not None:
        command.extend(
            [
                "--akashic-source",
                str(akashic[0]),
                "--akashic-identity",
                str(akashic[1]),
            ]
        )
    if imagecraft is not None:
        command.extend(
            [
                "--imagecraft-source",
                str(imagecraft[0]),
                "--imagecraft-identity",
                str(imagecraft[1]),
            ]
        )
    completed = run(command, cwd=ROOT)
    if completed.returncode == 0:
        raise RuntimeError(f"negative case {name!r} was accepted")
    missing = [value for value in expected_fragments if value not in completed.stdout]
    if missing:
        raise RuntimeError(
            f"negative case {name!r} failed for the wrong reason; "
            f"missing={missing!r} output={completed.stdout!r}"
        )
    return {
        "name": name,
        "status": "rejected-before-build",
        "expectedFragments": list(expected_fragments),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--akashic-source", type=Path, required=True)
    parser.add_argument("--imagecraft-source", type=Path, required=True)
    args = parser.parse_args()

    akashic_source = args.akashic_source.expanduser().resolve()
    imagecraft_source = args.imagecraft_source.expanduser().resolve()
    try:
        with tempfile.TemporaryDirectory(prefix="fovea-component-identity-negatives-") as directory:
            temporary = Path(directory)
            akashic_baseline = temporary / "Akashic"
            imagecraft_baseline = temporary / "ImageCraft"
            akashic_identity_path = temporary / "akashic-identity.json"
            imagecraft_identity_path = temporary / "imagecraft-identity.json"
            identities = {
                "Akashic": materialize(
                    "Akashic",
                    akashic_source,
                    akashic_baseline,
                    akashic_identity_path,
                ),
                "ImageCraft": materialize(
                    "ImageCraft",
                    imagecraft_source,
                    imagecraft_baseline,
                    imagecraft_identity_path,
                ),
            }

            cases: list[dict[str, object]] = []

            unbound = temporary / "ImageCraft-unbound"
            shutil.copytree(imagecraft_baseline, unbound)
            (unbound / "UNBOUND.txt").write_text("not covered\n")
            cases.append(
                expect_rejection(
                    name="unbound-top-level-entry",
                    expected_fragments=("unbound top-level entries", "UNBOUND.txt"),
                    imagecraft=(unbound, imagecraft_identity_path),
                )
            )

            omission = temporary / "ImageCraft-omission"
            shutil.copytree(imagecraft_baseline, omission)
            omitted_path = "Sources/ImageCraftCore/ImageCodecContract.swift"
            if not (omission / omitted_path).is_file():
                raise FileNotFoundError(omission / omitted_path)
            forged_identity = json.loads(imagecraft_identity_path.read_text())
            forged_identity["files"] = [
                entry
                for entry in forged_identity["files"]
                if entry["path"] != omitted_path
            ]
            forged_identity["fileCount"] = len(forged_identity["files"])
            forged_identity["sourceIdentitySHA256"] = canonical_digest(forged_identity)
            forged_identity_path = temporary / "imagecraft-omission-identity.json"
            forged_identity_path.write_text(
                json.dumps(forged_identity, indent=2, sort_keys=True) + "\n"
            )
            cases.append(
                expect_rejection(
                    name="manifest-omits-existing-source",
                    expected_fragments=("coverage is incomplete", omitted_path),
                    imagecraft=(omission, forged_identity_path),
                )
            )

            nested_reserved = temporary / "Akashic-nested-reserved"
            shutil.copytree(akashic_baseline, nested_reserved)
            smuggled = nested_reserved / "Sources/AkashicCore/.build/smuggled.swift"
            smuggled.parent.mkdir(parents=True)
            smuggled.write_text("public let smuggled = true\n")
            cases.append(
                expect_rejection(
                    name="undeclared-nested-build-subtree",
                    expected_fragments=("nested top-level exclusion name", ".build"),
                    akashic=(nested_reserved, akashic_identity_path),
                )
            )

            symlink = temporary / "ImageCraft-symlink"
            shutil.copytree(imagecraft_baseline, symlink)
            link = symlink / "Sources/ImageCraftCore/PackageAlias.swift"
            link.symlink_to("../../Package.swift")
            cases.append(
                expect_rejection(
                    name="symbolic-link-entry",
                    expected_fragments=("rejects symbolic links", "PackageAlias.swift"),
                    imagecraft=(symlink, imagecraft_identity_path),
                )
            )

            executable_tool = temporary / "Akashic-executable-tool"
            shutil.copytree(akashic_baseline, executable_tool)
            sentinel = temporary / "candidate-tool-executed.txt"
            tool = executable_tool / "Tools/Identity/capture_source_identity.py"
            tool.write_text(
                "from pathlib import Path\n"
                f"Path({str(sentinel)!r}).write_text('executed')\n"
            )
            cases.append(
                expect_rejection(
                    name="candidate-identity-tool-is-data-not-code",
                    expected_fragments=(
                        "byte count drifted",
                        "Tools/Identity/capture_source_identity.py",
                    ),
                    akashic=(executable_tool, akashic_identity_path),
                )
            )
            if sentinel.exists():
                raise RuntimeError("candidate identity tool was executed")

            executable_drift = temporary / "ImageCraft-executable-drift"
            shutil.copytree(imagecraft_baseline, executable_drift)
            executable_file = executable_drift / "README.md"
            executable_file.chmod(0o755)
            cases.append(
                expect_rejection(
                    name="executable-bit-drift",
                    expected_fragments=("executable flag drifted", "README.md"),
                    imagecraft=(executable_drift, imagecraft_identity_path),
                )
            )
    except (
        OSError,
        TypeError,
        ValueError,
        RuntimeError,
        subprocess.TimeoutExpired,
    ) as error:
        print(str(error))
        return 1

    report = {
        "schemaVersion": 2,
        "status": "passed",
        "caseCount": len(cases),
        "cases": cases,
        "componentBaselines": {
            component: {
                "identityID": identity["identityID"],
                "sourceIdentitySHA256": identity["sourceIdentitySHA256"],
                "fileCount": identity["fileCount"],
            }
            for component, identity in identities.items()
        },
        "buildAttempted": False,
        "candidateIdentityToolExecuted": False,
    }
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "Component candidate identity negatives passed: "
        f"cases={len(cases)} buildAttempted=false candidateToolExecuted=false"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
