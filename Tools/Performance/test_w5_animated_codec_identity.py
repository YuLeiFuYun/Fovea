#!/usr/bin/env python3
import hashlib
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def load_module(name: str, path: pathlib.Path):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


capture = load_module(
    "w5_animated_codec_capture_contract",
    ROOT / "Tools/Performance/capture_w5_animated_codec.py",
)
validator = load_module(
    "w5_animated_codec_validator_contract",
    ROOT / "Tools/Performance/validate_w5_animated_codec.py",
)


class W5AnimatedCodecIdentityTests(unittest.TestCase):
    def run_git(self, root: pathlib.Path, *arguments: str) -> str:
        completed = subprocess.run(
            ["git", *arguments],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        return completed.stdout.strip()

    def make_repository(self, root: pathlib.Path) -> None:
        self.run_git(root, "init", "-q")
        self.run_git(root, "config", "user.name", "Fovea Test")
        self.run_git(root, "config", "user.email", "fovea-test@example.invalid")
        self.run_git(root, "config", "core.filemode", "true")
        (root / "tracked.txt").write_text("baseline\n")
        script = root / "script.sh"
        script.write_text("#!/bin/sh\nexit 0\n")
        script.chmod(0o644)
        self.run_git(root, "add", "tracked.txt", "script.sh")
        self.run_git(root, "commit", "-q", "-m", "baseline")

    def test_working_tree_identity_covers_all_unignored_source_state(self) -> None:
        with tempfile.TemporaryDirectory(prefix="w5-source-identity-") as temporary:
            root = pathlib.Path(temporary)
            self.make_repository(root)
            baseline = capture.git_snapshot(root)
            self.assertFalse(baseline["dirty"])
            self.assertEqual(baseline["workingTree"], baseline["headTree"])

            (root / "tracked.txt").write_text("modified\n")
            modified = capture.git_snapshot(root)
            self.assertTrue(modified["dirty"])
            self.assertNotEqual(modified["workingTree"], baseline["workingTree"])

            self.run_git(root, "checkout", "--", "tracked.txt")
            (root / "untracked.swift").write_text("let value = 1\n")
            untracked = capture.git_snapshot(root)
            self.assertTrue(untracked["dirty"])
            self.assertNotEqual(untracked["workingTree"], baseline["workingTree"])

            (root / "untracked.swift").unlink()
            (root / "tracked.txt").unlink()
            deleted = capture.git_snapshot(root)
            self.assertTrue(deleted["dirty"])
            self.assertNotEqual(deleted["workingTree"], baseline["workingTree"])

            self.run_git(root, "checkout", "--", "tracked.txt")
            script = root / "script.sh"
            script.chmod(0o755)
            executable = capture.git_snapshot(root)
            self.assertTrue(executable["dirty"])
            self.assertNotEqual(executable["workingTree"], baseline["workingTree"])

    def test_snapshot_validator_rejects_inconsistent_dirty_state(self) -> None:
        snapshot = {
            "headCommit": "0" * 40,
            "headTree": "1" * 40,
            "workingTree": "2" * 40,
            "dirty": False,
            "statusShort": [],
            "identityAlgorithm": "git-temporary-index-add-all-write-tree-v1",
        }
        with self.assertRaises(SystemExit):
            validator.validate_source_snapshot("synthetic", snapshot)

    def test_output_must_be_empty_and_artifact_scoped(self) -> None:
        with tempfile.TemporaryDirectory(prefix="w5-output-contract-") as temporary:
            root = pathlib.Path(temporary)
            fovea = root / "Fovea"
            allowed = fovea / ".artifacts/performance/capture"
            allowed.mkdir(parents=True)
            capture.ensure_output_location(allowed, fovea)
            (allowed / "stale.json").write_text("{}\n")
            with self.assertRaises(SystemExit):
                capture.ensure_output_location(allowed, fovea)
            with self.assertRaises(SystemExit):
                capture.ensure_output_location(root / "outside", fovea)

    def test_validator_rejects_identity_pixel_and_source_tampering(self) -> None:
        with tempfile.TemporaryDirectory(prefix="w5-validator-contract-") as temporary:
            root = pathlib.Path(temporary).resolve()
            self.write_synthetic_capture(root)
            command = [
                sys.executable,
                str(ROOT / "Tools/Performance/validate_w5_animated_codec.py"),
                str(root),
                "--blocks",
                "1",
                "--samples-per-report",
                "1",
            ]
            subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            report = root / "block-00/gif-ImageCraft.json"
            self.expect_validator_failure(
                command,
                report,
                lambda payload: payload["comparator"].__setitem__("workingTree", "f" * 40),
                "comparator identity mismatch",
            )

            rgba = root / "block-00/gif-ImageCraft.rgba"
            original_rgba = rgba.read_bytes()
            try:
                altered = bytearray(original_rgba)
                altered[0] ^= 1
                rgba.write_bytes(altered)
                completed = subprocess.run(
                    command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
                )
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("RGBA digest mismatch", completed.stdout + completed.stderr)
            finally:
                rgba.write_bytes(original_rgba)

            manifest = root / "capture-manifest.json"
            self.expect_validator_failure(
                command,
                manifest,
                lambda payload: payload["sourceAfter"]["Fovea"].__setitem__(
                    "workingTree", "f" * 40
                ),
                "source before/after identity mismatch",
            )

    def expect_validator_failure(
        self,
        command: list[str],
        path: pathlib.Path,
        mutate,
        expected_message: str,
    ) -> None:
        original = path.read_bytes()
        try:
            payload = json.loads(original)
            mutate(payload)
            path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
            completed = subprocess.run(
                command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn(expected_message, completed.stdout + completed.stderr)
        finally:
            path.write_bytes(original)

    def write_synthetic_capture(self, root: pathlib.Path) -> None:
        comparators = tuple(validator.COMPARATOR_VERSIONS)

        def snapshot(
            head: str,
            head_tree: str,
            working_tree: str,
            dirty: bool,
            *,
            version: str | None = None,
        ) -> dict:
            result = {
                "root": "/unavailable",
                "headCommit": head,
                "headTree": head_tree,
                "workingTree": working_tree,
                "dirty": dirty,
                "statusShort": [" M synthetic"] if dirty else [],
                "identityAlgorithm": "git-temporary-index-add-all-write-tree-v1",
            }
            if version is not None:
                result["version"] = version
            return result

        source = {
            "Fovea": snapshot("0" * 40, "1" * 40, "2" * 40, True),
            "comparators": {
                "ImageCraft": snapshot(
                    "3" * 40,
                    "4" * 40,
                    "5" * 40,
                    True,
                    version=validator.COMPARATOR_VERSIONS["ImageCraft"],
                ),
                "SDWebImage": snapshot(
                    validator.EXPECTED_CLEAN_COMPARATOR_COMMITS["SDWebImage"],
                    "6" * 40,
                    "6" * 40,
                    False,
                    version=validator.COMPARATOR_VERSIONS["SDWebImage"],
                ),
                "PINRemoteImage": snapshot(
                    validator.EXPECTED_CLEAN_COMPARATOR_COMMITS["PINRemoteImage"],
                    "7" * 40,
                    "7" * 40,
                    False,
                    version=validator.COMPARATOR_VERSIONS["PINRemoteImage"],
                ),
            },
        }
        inputs = {
            "gif": {"path": "/unavailable/input.gif", "byteCount": 10, "sha256": "8" * 64},
            "apng": {"path": "/unavailable/input.apng", "byteCount": 11, "sha256": "9" * 64},
        }
        block_directory = root / "block-00"
        block_directory.mkdir(parents=True)
        commands = []
        for fmt in validator.FORMATS:
            for comparator in comparators:
                source_identity = source["comparators"][comparator]
                report_path = block_directory / f"{fmt}-{comparator}.json"
                rgba_path = block_directory / f"{fmt}-{comparator}.rgba"
                pixel = bytearray(256 * 256 * 4)
                if comparator == "SDWebImage":
                    pixel[0] = 1
                rgba_path.write_bytes(pixel)
                pixel_digest = hashlib.sha256(pixel).hexdigest()
                identity = {
                    "name": comparator,
                    "version": source_identity["version"],
                    "headCommit": source_identity["headCommit"],
                    "workingTree": source_identity["workingTree"],
                    "dirty": source_identity["dirty"],
                }
                timing = {
                    "medianNanoseconds": 1,
                    "p95Nanoseconds": 1,
                    "samplesNanoseconds": [1],
                }
                report = {
                    "schemaVersion": 2,
                    "comparator": identity,
                    "format": fmt,
                    "inputPath": inputs[fmt]["path"],
                    "inputByteCount": inputs[fmt]["byteCount"],
                    "inputSHA256": inputs[fmt]["sha256"],
                    "frameCount": 24,
                    "rawLoopCount": 3,
                    "normalizedAdditionalRepeatCount": 2,
                    "frameDurationsNanoseconds": [1_000_000] * 24,
                    "selectedFrameIndex": 12,
                    "selectedFrameWidth": 256,
                    "selectedFrameHeight": 256,
                    "selectedFramePixelSHA256": pixel_digest,
                    "selectedFrameRGBAPath": str(rgba_path),
                    "prepare": timing,
                    "selectedFrame": timing,
                    "sequentialAllFrames": timing,
                    "frameCachePolicy": "disabled-or-not-provided",
                    "sourceReusePolicy": "one-retained-provider-per-report",
                }
                report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
                commands.append(
                    [
                        "/unavailable/W5AnimatedCodecLab",
                        "--comparator",
                        comparator,
                        "--format",
                        fmt,
                        "--output",
                        str(report_path),
                        "--comparator-version",
                        source_identity["version"],
                        "--source-head",
                        source_identity["headCommit"],
                        "--source-tree",
                        source_identity["workingTree"],
                        "--source-dirty",
                        "true" if source_identity["dirty"] else "false",
                    ]
                )
        manifest = {
            "schemaVersion": 2,
            "formalClaimEligible": False,
            "blockCount": 1,
            "iterationsPerReport": 1,
            "warmupsPerReport": 0,
            "sourceBefore": source,
            "sourceAfter": source,
            "sourceUnchangedDuringCapture": True,
            "inputsBefore": inputs,
            "inputsAfter": inputs,
            "inputsUnchangedDuringCapture": True,
            "blocks": [
                {
                    "block": 0,
                    "formatOrder": ["gif", "apng"],
                    "comparatorOrder": list(comparators),
                    "commands": commands,
                }
            ],
        }
        (root / "capture-manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        )


if __name__ == "__main__":
    unittest.main()
