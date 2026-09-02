#!/usr/bin/env python3
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "Tools/Performance/validate_w5_apng_composition_oracle.py"
FIXTURES = (
    "APNG-OVER-NONE",
    "APNG-OVER-BACKGROUND",
    "APNG-OVER-PREVIOUS",
    "APNG-SUBRECT-NONE",
    "APNG-SUBRECT-BACKGROUND",
    "APNG-SUBRECT-PREVIOUS-SOURCE",
)


class W5APNGCompositionOracleTests(unittest.TestCase):
    def validator_command(self, root: pathlib.Path) -> list[str]:
        return [sys.executable, str(VALIDATOR), str(root)]

    def run_validator(self, root: pathlib.Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            self.validator_command(root),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_valid_synthetic_capture_passes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="w5-apng-oracle-valid-") as temporary:
            root = pathlib.Path(temporary).resolve()
            self.write_capture(root)
            completed = self.run_validator(root)
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            aggregate = json.loads((root / "aggregate.json").read_text())
            self.assertTrue(aggregate["allFixturesTimelineEligible"])
            expected_artifact_count = sum(
                1 + 3 * aggregate["fixtureResults"][fixture]["frameCount"]
                for fixture in FIXTURES
            )
            self.assertEqual(len(aggregate["artifactInventory"]), expected_artifact_count)
            self.assertTrue(aggregate["allFixturesPairExact"]["ImageCraftAPNGKit"])
            self.assertTrue(aggregate["allFixturesPairExact"]["ImageCraftAppleImageIO"])
            self.assertTrue(aggregate["allFixturesPairExact"]["APNGKitAppleImageIO"])
            for result in aggregate["fixtureResults"].values():
                self.assertTrue(
                    result["imageCraftResourceObservation"][
                        "allDecodedFramesAreFullCanvas"
                    ]
                )
                self.assertGreater(
                    result["imageCraftResourceObservation"][
                        "decodedOverMetadataSubrectByteRatio"
                    ],
                    1.0,
                )

    def test_validator_rejects_identity_pixel_source_and_path_tampering(self) -> None:
        with tempfile.TemporaryDirectory(prefix="w5-apng-oracle-tamper-") as temporary:
            root = pathlib.Path(temporary).resolve()
            self.write_capture(root)

            report = root / "APNG-OVER-NONE.json"
            self.expect_json_failure(
                root,
                report,
                lambda payload: payload.__setitem__("sourceIdentitySHA256", "f" * 64),
                "source identity digest mismatch",
            )

            rgba = root / "APNG-OVER-NONE-frame-00-ImageCraft.rgba"
            original_rgba = rgba.read_bytes()
            try:
                altered = bytearray(original_rgba)
                altered[0] ^= 1
                rgba.write_bytes(altered)
                completed = self.run_validator(root)
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("ImageCraft RGBA digest mismatch", completed.stdout + completed.stderr)
            finally:
                rgba.write_bytes(original_rgba)

            manifest = root / "capture-manifest.json"
            self.expect_json_failure(
                root,
                manifest,
                lambda payload: payload["sourceAfter"]["Fovea"].__setitem__(
                    "workingTree", "f" * 40
                ),
                "source before/after mismatch",
            )

            outside = root.parent / "outside-apng-oracle.rgba"
            outside.write_bytes(bytes(150 * 150 * 4))
            try:
                self.expect_json_failure(
                    root,
                    report,
                    lambda payload: payload["frames"][0].__setitem__(
                        "imageCraftRGBAPath", str(outside)
                    ),
                    "path escapes capture directory",
                )
            finally:
                outside.unlink(missing_ok=True)

    def expect_json_failure(
        self,
        root: pathlib.Path,
        path: pathlib.Path,
        mutation,
        expected: str,
    ) -> None:
        original = path.read_bytes()
        try:
            payload = json.loads(original)
            mutation(payload)
            path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
            completed = self.run_validator(root)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn(expected, completed.stdout + completed.stderr)
        finally:
            path.write_bytes(original)

    def write_capture(self, root: pathlib.Path) -> None:
        root.mkdir(parents=True, exist_ok=True)

        def snapshot(
            head: str,
            head_tree: str,
            working_tree: str,
            dirty: bool,
            version: str | None = None,
        ) -> dict[str, object]:
            result: dict[str, object] = {
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

        sources = {
            "Fovea": snapshot("0" * 40, "1" * 40, "2" * 40, True),
            "ImageCraft": snapshot(
                "3" * 40, "4" * 40, "5" * 40, True, "local-animation-contract-v1"
            ),
            "APNGKit": snapshot(
                "341383f61000e8d2e55d45db0f0756b239d0a2f1",
                "6" * 40,
                "6" * 40,
                False,
                "2.3.0-source-audit-candidate",
            ),
            "Delegate": snapshot(
                "ec3014ca2621c717f758d8718ec90e84b6e774b3",
                "7" * 40,
                "7" * 40,
                False,
                "1.3.0",
            ),
        }
        inputs = {
            fixture: {
                "path": f"/unavailable/{fixture}.apng",
                "byteCount": 100 + index,
                "sha256": format(8 + index, "x") * 64,
            }
            for index, fixture in enumerate(FIXTURES)
        }
        fixture_shapes = {
            "APNG-OVER-NONE": (3, 150, 150),
            "APNG-OVER-BACKGROUND": (3, 150, 150),
            "APNG-OVER-PREVIOUS": (3, 150, 150),
            "APNG-SUBRECT-NONE": (3, 128, 64),
            "APNG-SUBRECT-BACKGROUND": (3, 128, 64),
            "APNG-SUBRECT-PREVIOUS-SOURCE": (6, 220, 220),
        }
        fixture_contract = {
            fixture: {
                "fileName": f"{fixture}.apng",
                "expectedFrameCount": fixture_shapes[fixture][0],
                "expectedCanvasWidth": fixture_shapes[fixture][1],
                "expectedCanvasHeight": fixture_shapes[fixture][2],
                "role": fixture.lower(),
            }
            for fixture in FIXTURES
        }
        system_comparators = {
            "AppleImageIO": {
                "name": "AppleImageIO",
                "frameworkIdentifier": "com.apple.ImageIO",
                "frameworkShortVersion": "3.3.0",
                "frameworkBundleVersion": "2847",
                "frameworkPlatformBuild": "synthetic-platform-build",
                "frameworkSDKBuild": "synthetic-sdk-build",
                "infoPlist": {
                    "path": "/System/Library/Frameworks/ImageIO.framework/Resources/Info.plist",
                    "byteCount": 100,
                    "sha256": "a" * 64,
                },
                "operatingSystem": {
                    "productName": "macOS",
                    "productVersion": "27.0",
                    "buildVersion": "synthetic-os-build",
                },
                "xcode": ["Xcode synthetic", "Build version synthetic"],
                "swift": ["Swift version synthetic"],
                "binaryIdentityBoundary": "synthetic dyld shared cache boundary",
            }
        }
        mechanism_audit = {
            "schemaVersion": 1,
            "files": {
                name: {
                    "path": f"/unavailable/{name}.swift",
                    "byteCount": 100 + index,
                    "sha256": format(index + 1, "x") * 64,
                }
                for index, name in enumerate(
                    (
                        "animatedImageTypes",
                        "containerInspector",
                        "apngInspector",
                        "animatedDecoder",
                        "frameProvider",
                        "frameRenderer",
                    )
                )
            },
            "observations": {
                "decodedAnimationFrameDocumentedAsCompleteComposedFrame": True,
                "providerDecodesSingleRequestedIndexDirectly": True,
                "providerWindowMapsEveryRequestedIndex": True,
                "rendererUsesImageIORequestedIndexMaterialization": True,
                "apngInspectorPublishesSubrectDisposalAndBlendMetadata": True,
                "separateDefaultMultiFrameRequiresAlignedImageIOIndices": True,
                "explicitCheckpointStateObservedInProviderOrRenderer": False,
            },
            "interpretationBoundary": "synthetic source audit",
        }
        identity = {
            "schemaVersion": 3,
            "formalClaimEligible": False,
            "identityAlgorithm": "git-temporary-index-add-all-write-tree-v1",
            "sources": sources,
            "systemComparators": system_comparators,
            "imageCraftMechanismAudit": mechanism_audit,
            "inputs": inputs,
            "fixtureContract": fixture_contract,
            "claimBoundary": ["synthetic correctness-only contract"],
        }
        identity_path = root / "source-identity.json"
        identity_path.write_text(json.dumps(identity, indent=2, sort_keys=True) + "\n")
        identity_data = identity_path.read_bytes()
        identity_digest = hashlib.sha256(identity_data).hexdigest()

        reports: list[str] = []
        commands: list[list[str]] = []
        for fixture_index, fixture in enumerate(FIXTURES):
            frames = []
            frame_count, canvas_width, canvas_height = fixture_shapes[fixture]
            for frame_index in range(frame_count):
                pixel = bytes([fixture_index, frame_index, 0, 255]) * (
                    canvas_width * canvas_height
                )
                imagecraft_path = root / f"{fixture}-frame-{frame_index:02d}-ImageCraft.rgba"
                apngkit_path = root / f"{fixture}-frame-{frame_index:02d}-APNGKit.rgba"
                apple_path = root / f"{fixture}-frame-{frame_index:02d}-AppleImageIO.rgba"
                imagecraft_path.write_bytes(pixel)
                apngkit_path.write_bytes(pixel)
                apple_path.write_bytes(pixel)
                digest = hashlib.sha256(pixel).hexdigest()
                no_difference = {
                    "sameLength": True,
                    "differentPixelCount": 0,
                    "differentPixelFraction": 0.0,
                    "maximumChannelDifference": 0,
                    "meanAbsoluteChannelDifference": 0.0,
                }
                frames.append(
                    {
                        "index": frame_index,
                        "imageCraftDescriptorRect": {
                            "x": 0 if frame_index == 0 else 25,
                            "y": 0 if frame_index == 0 else 25,
                            "width": canvas_width if frame_index == 0 else max(1, canvas_width // 2),
                            "height": canvas_height if frame_index == 0 else max(1, canvas_height // 2),
                        },
                        "imageCraftDisposal": (
                            "none"
                            if "NONE" in fixture
                            else "background"
                            if "BACKGROUND" in fixture
                            else "previous"
                        ),
                        "imageCraftBlend": "over",
                        "imageCraftSubrectRGBAByteCount": (
                            canvas_width * canvas_height * 4
                            if frame_index == 0
                            else max(1, canvas_width // 2) * max(1, canvas_height // 2) * 4
                        ),
                        "imageCraftDecodedRGBAByteCount": canvas_width * canvas_height * 4,
                        "imageCraftDecodedIsFullCanvas": True,
                        "imageCraftWidth": canvas_width,
                        "imageCraftHeight": canvas_height,
                        "apngKitWidth": canvas_width,
                        "apngKitHeight": canvas_height,
                        "appleImageIOWidth": canvas_width,
                        "appleImageIOHeight": canvas_height,
                        "imageCraftPixelSHA256": digest,
                        "apngKitPixelSHA256": digest,
                        "appleImageIOPixelSHA256": digest,
                        "imageCraftRGBAPath": str(imagecraft_path),
                        "apngKitRGBAPath": str(apngkit_path),
                        "appleImageIORGBAPath": str(apple_path),
                        "imageCraftVersusAPNGKit": no_difference,
                        "imageCraftVersusAppleImageIO": no_difference,
                        "apngKitVersusAppleImageIO": no_difference,
                    }
                )
            report_path = root / f"{fixture}.json"
            report = {
                "schemaVersion": 3,
                "fixtureID": fixture,
                "inputPath": inputs[fixture]["path"],
                "inputByteCount": inputs[fixture]["byteCount"],
                "inputSHA256": inputs[fixture]["sha256"],
                "sourceIdentityPath": str(identity_path),
                "sourceIdentityByteCount": len(identity_data),
                "sourceIdentitySHA256": identity_digest,
                "imageCraft": {
                    "frameCount": frame_count,
                    "normalizedAdditionalRepeatCount": None,
                    "frameDurationsNanoseconds": [1_000_000_000] * frame_count,
                    "decodePolicy": "synthetic ImageCraft",
                },
                "apngKit": {
                    "frameCount": frame_count,
                    "normalizedAdditionalRepeatCount": None,
                    "frameDurationsNanoseconds": [1_000_000_000] * frame_count,
                    "decodePolicy": "synthetic APNGKit",
                },
                "appleImageIO": {
                    "frameCount": frame_count,
                    "decodePolicy": "synthetic Apple ImageIO",
                },
                "timelineToleranceNanoseconds": 1_000,
                "timelineEligible": True,
                "imageCraftAPNGKitAllFramesExact": True,
                "imageCraftAppleImageIOAllFramesExact": True,
                "apngKitAppleImageIOAllFramesExact": True,
                "frames": frames,
                "claimBoundary": ["synthetic correctness-only contract"],
            }
            report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
            reports.append(str(report_path))
            commands.append(
                [
                    "/unavailable/W5APNGCompositionOracleLab",
                    "--fixture-id",
                    fixture,
                    "--input",
                    inputs[fixture]["path"],
                    "--output",
                    str(report_path),
                    "--source-identity",
                    str(identity_path),
                ]
            )

        manifest = {
            "schemaVersion": 3,
            "formalClaimEligible": False,
            "sourceBefore": sources,
            "sourceAfter": sources,
            "sourceUnchangedDuringCapture": True,
            "systemComparatorsBefore": system_comparators,
            "systemComparatorsAfter": system_comparators,
            "systemComparatorsUnchangedDuringCapture": True,
            "imageCraftMechanismAuditBefore": mechanism_audit,
            "imageCraftMechanismAuditAfter": mechanism_audit,
            "imageCraftMechanismAuditUnchangedDuringCapture": True,
            "inputsBefore": inputs,
            "inputsAfter": inputs,
            "inputsUnchangedDuringCapture": True,
            "sourceIdentity": {
                "path": str(identity_path),
                "byteCount": len(identity_data),
                "sha256": identity_digest,
            },
            "commands": commands,
            "reports": reports,
        }
        (root / "capture-manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        )


if __name__ == "__main__":
    unittest.main()
