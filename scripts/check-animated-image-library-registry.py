#!/usr/bin/env python3
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "docs/research/animated-image-library-registry-2026-08.json"
PLAN = ROOT / "Benchmarks/ComparativeLab/animated-image-plan.json"
PLAYER_PLAN = ROOT / "Benchmarks/ComparativeLab/animated-player-mechanism-plan.json"
CHECKPOINT_PLAN = ROOT / "Benchmarks/ComparativeLab/apng-checkpoint-plan.json"
TILE_CHECKPOINT_PLAN = ROOT / "Benchmarks/ComparativeLab/apng-tile-checkpoint-plan.json"
COMPRESSED_CHECKPOINT_PLAN = ROOT / "Benchmarks/ComparativeLab/apng-compressed-checkpoint-plan.json"
OWNED_SWIFT_STUDY = ROOT / "docs/research/w5-apng-owned-swift-playback-2026-08.json"
PUBLIC_DECODER_STUDY = ROOT / "docs/research/w5-apng-public-decoder-playback-2026-08.json"
PUBLIC_DECODER_MAC_PERFORMANCE_STUDY = ROOT / "docs/research/w5-apng-public-decoder-mac-performance-2026-08.json"
IMAGEIO_CACHE_DIVERGENCE_STUDY = ROOT / "docs/research/w5-apng-imageio-cache-divergence-2026-08.json"
IMAGECRAFT_ADAPTER_STUDY = ROOT / "docs/research/w5-imagecraft-animation-adapter-qualification-2026-08.json"
SEMANTIC_REPLAY_STUDY = ROOT / "docs/research/w5-apng-semantic-replay-2026-08.json"
MECHANISM_MATRIX = ROOT / "docs/research/animated-image-mechanism-matrix-2026-08.json"
VALID_DECISIONS = {
    "experiment-next",
    "adopted-core-extend-by-evidence",
    "experiment-after-imagecraft-adapter",
    "defer-until-large-fixture-benefit",
    "experiment-with-device-energy-gate",
    "defer",
    "reject-current-scope",
    "reject-as-different-product",
}


def main() -> int:
    errors: list[str] = []
    registry = json.loads(REGISTRY.read_text())
    plan = json.loads(PLAN.read_text())
    player_plan = json.loads(PLAYER_PLAN.read_text())
    checkpoint_plan = json.loads(CHECKPOINT_PLAN.read_text())
    tile_checkpoint_plan = json.loads(TILE_CHECKPOINT_PLAN.read_text())
    compressed_checkpoint_plan = json.loads(COMPRESSED_CHECKPOINT_PLAN.read_text())
    owned_swift_study = json.loads(OWNED_SWIFT_STUDY.read_text())
    public_decoder_study = json.loads(PUBLIC_DECODER_STUDY.read_text())
    public_decoder_mac_performance_study = json.loads(
        PUBLIC_DECODER_MAC_PERFORMANCE_STUDY.read_text()
    )
    imageio_cache_divergence_study = json.loads(
        IMAGEIO_CACHE_DIVERGENCE_STUDY.read_text()
    )
    imagecraft_adapter_study = json.loads(IMAGECRAFT_ADAPTER_STUDY.read_text())
    semantic_replay_study = json.loads(SEMANTIC_REPLAY_STUDY.read_text())
    mechanism_matrix = json.loads(MECHANISM_MATRIX.read_text())
    libraries = registry.get("libraries") or []
    features = registry.get("featureCandidates") or []
    w5_test_locations: dict[str, list[str]] = {}
    w5_pattern = re.compile(r"\bfunc\s+[A-Za-z0-9_]*(W5_PT_\d+)\s*\(")
    for test_path in sorted((ROOT / "Tests").rglob("*.swift")):
        for match in w5_pattern.finditer(test_path.read_text()):
            w5_test_locations.setdefault(match.group(1), []).append(
                str(test_path.relative_to(ROOT))
            )
    for test_id, locations in sorted(w5_test_locations.items()):
        if len(locations) != 1:
            errors.append(f"{test_id}: duplicate W5 test definitions {locations}")
    ids = [item.get("id") for item in libraries]
    if len(ids) != len(set(ids)) or not all(isinstance(item, str) and item for item in ids):
        errors.append("library IDs must be unique non-empty strings")
    for item in libraries:
        commit = item.get("exactCommit")
        if commit is not None and re.fullmatch(r"[0-9a-f]{40}", str(commit)) is None:
            errors.append(f"{item.get('id')}: exactCommit must be 40 lowercase hex characters")
        if not item.get("roles") or not item.get("mechanisms"):
            errors.append(f"{item.get('id')}: roles and mechanisms are required")
        if item.get("dependencyDecision") not in {
            "comparator-only", "source-audit-and-comparator-adapter-only", "source-audit-first",
            "source-oracle-only", "source-audit-only-unless-it-falsifies-current-lifecycle",
            "transport-only-comparator", "platform-oracle",
        }:
            errors.append(f"{item.get('id')}: invalid dependencyDecision")
    for item in features:
        for test_id in item.get("tests") or []:
            if str(test_id).startswith("W5_PT_") and test_id not in w5_test_locations:
                errors.append(f"{item.get('id')}: unknown W5 test {test_id}")
    feature_ids = [item.get("id") for item in features]
    if len(feature_ids) != len(set(feature_ids)):
        errors.append("feature IDs must be unique")
    for item in features:
        for key in ("benefit", "complexity", "evidence"):
            value = item.get(key)
            if not isinstance(value, int) or not 1 <= value <= 5:
                errors.append(f"{item.get('id')}: {key} must be within 1...5")
        if item.get("decision") not in VALID_DECISIONS:
            errors.append(f"{item.get('id')}: invalid decision")
        if str(item.get("decision", "")).startswith("experiment"):
            if item.get("benefit", 0) < 3 or not item.get("acceptance"):
                errors.append(f"{item.get('id')}: experiments need material benefit and acceptance")
    plan_ids = {item.get("id") for item in plan.get("comparators") or []}
    required = {"CMP-GIFU", "CMP-FLANIMATEDIMAGE", "CMP-APNGKIT"}
    if not required <= plan_ids:
        errors.append("animated-image plan must include all P0 specialized comparators")
    unknown = plan_ids - set(ids)
    if unknown:
        errors.append(f"plan comparator IDs missing from registry: {sorted(unknown)}")
    if registry.get("selectionPolicy", {}).get("aggregateWinnerScore") is not False:
        errors.append("aggregate winner scoring must remain disabled")
    registered_names = {item.get("name") for item in libraries}
    registered_names.update({"Fovea", "ImageCraft"})
    for role in player_plan.get("roles") or []:
        comparators = set(role.get("comparators") or [])
        missing = comparators - registered_names
        if missing:
            errors.append(f"{role.get('id')}: unregistered comparators {sorted(missing)}")
        if not role.get("metrics"):
            errors.append(f"{role.get('id')}: metrics are required")
    if len(player_plan.get("adoptionGates") or []) < 4:
        errors.append("player mechanism plan requires four bounded adoption gates")
    if not any("aggregate winner" in item.lower() for item in player_plan.get("forbiddenInterpretations") or []):
        errors.append("player plan must explicitly forbid aggregate winner claims")
    if checkpoint_plan.get("schemaVersion") != 1:
        errors.append("APNG checkpoint plan schema must remain version 1")
    if checkpoint_plan.get("planID") != "FOVEA-W5-APNG-CHECKPOINT-MODEL-V1":
        errors.append("APNG checkpoint plan identity changed")
    checkpoint_fixtures = checkpoint_plan.get("sourceFixtures") or []
    checkpoint_fixture_ids = [item.get("id") for item in checkpoint_fixtures]
    if (
        len(checkpoint_fixture_ids) != len(set(checkpoint_fixture_ids))
        or not all(isinstance(item, str) and item for item in checkpoint_fixture_ids)
    ):
        errors.append("APNG checkpoint fixture IDs must be unique non-empty strings")
    for item in checkpoint_fixtures:
        relative = item.get("relativePath")
        if (
            not isinstance(relative, str)
            or not relative
            or Path(relative).is_absolute()
            or ".." in Path(relative).parts
            or not item.get("role")
        ):
            errors.append(f"{item.get('id')}: invalid checkpoint fixture contract")
    checkpoint_scenarios = checkpoint_plan.get("syntheticScenarios") or []
    checkpoint_scenario_ids = [item.get("id") for item in checkpoint_scenarios]
    if len(checkpoint_scenario_ids) != len(set(checkpoint_scenario_ids)):
        errors.append("APNG checkpoint scenario IDs must be unique")
    for item in checkpoint_scenarios:
        if item.get("patternFixture") not in checkpoint_fixture_ids:
            errors.append(f"{item.get('id')}: unknown checkpoint pattern fixture")
        if item.get("patternMode") not in {
            "repeat-scaled-area-ratios",
            "first-full-then-one-pixel",
        }:
            errors.append(f"{item.get('id')}: invalid checkpoint pattern mode")
        for field in ("frameCount", "canvasWidth", "canvasHeight", "encodedSourceBytes"):
            value = item.get(field)
            if not isinstance(value, int) or value <= 0:
                errors.append(f"{item.get('id')}: {field} must be positive")
    budgets = checkpoint_plan.get("retainedBudgetMiB") or []
    replay_limits = checkpoint_plan.get("maximumReplayFrames") or []
    if budgets != sorted(set(budgets)) or 32 not in budgets:
        errors.append("APNG checkpoint budgets must be unique, sorted, and include 32 MiB")
    if replay_limits != sorted(set(replay_limits)) or 8 not in replay_limits:
        errors.append("APNG checkpoint replay limits must be unique, sorted, and include 8")
    if checkpoint_plan.get("referencePolicyPoint") != {
        "retainedBudgetMiB": 32,
        "maximumReplayFrames": 8,
    }:
        errors.append("APNG checkpoint reference policy must remain 32 MiB / 8 frames")
    strategy_ids = {
        item.get("id") for item in checkpoint_plan.get("retentionStrategies") or []
    }
    if strategy_ids != {"raw-subrect-retained", "encoded-source-retained"}:
        errors.append("APNG checkpoint retention strategy set changed")
    access_ids = {item.get("id") for item in checkpoint_plan.get("accessProfiles") or []}
    if access_ids != {"uniform", "tail-hot"}:
        errors.append("APNG checkpoint access profile set changed")
    expected_policies = {
        "imageCraftMaximumEncodedBytes": 64 * 1024 * 1024,
        "imageCraftMaximumTimelineDecodedBytes": 512 * 1024 * 1024,
        "imageCraftMaximumFrameDecodeWindow": 8,
        "foveaAnimationFrameMemoryHardCap": 32 * 1024 * 1024,
    }
    if checkpoint_plan.get("boundImplementationPolicies") != expected_policies:
        errors.append("APNG checkpoint bound implementation policies changed")
    checkpoint_boundaries = [
        str(item).lower() for item in checkpoint_plan.get("modelBoundary") or []
    ]
    if not any("implicit transparent canvas" in item for item in checkpoint_boundaries):
        errors.append("APNG checkpoint plan must bind the implicit initial canvas")
    if not any("not a product" in item for item in checkpoint_boundaries):
        errors.append("APNG checkpoint plan must forbid product claims")

    if tile_checkpoint_plan.get("schemaVersion") != 1:
        errors.append("APNG tile checkpoint plan schema must remain version 1")
    if tile_checkpoint_plan.get("planID") != (
        "FOVEA-W5-APNG-TILE-CHECKPOINT-CANDIDATE-V1"
    ):
        errors.append("APNG tile checkpoint plan identity changed")
    if tile_checkpoint_plan.get("basePlan") != (
        "Benchmarks/ComparativeLab/apng-checkpoint-plan.json"
    ):
        errors.append("APNG tile checkpoint base plan changed")
    if tile_checkpoint_plan.get("tileSizes") != [32, 64, 128, 256]:
        errors.append("APNG tile checkpoint size grid changed")
    if tile_checkpoint_plan.get("retainedBudgetMiB") != [
        8, 16, 32, 64, 128, 256, 512
    ]:
        errors.append("APNG tile checkpoint budget grid changed")
    if tile_checkpoint_plan.get("maximumReplayFrames") != [4, 8, 16]:
        errors.append("APNG tile checkpoint replay grid changed")
    if tile_checkpoint_plan.get("referencePolicyPoint") != {
        "retainedBudgetMiB": 32,
        "maximumReplayFrames": 8,
    }:
        errors.append("APNG tile checkpoint reference policy changed")
    tile_root = tile_checkpoint_plan.get("rootRepresentation") or {}
    if tile_root != {
        "entryBytesPerTile": 8,
        "frameZeroRoot": "implicit-transparent-not-retained",
        "headerBytesPerRetainedRoot": 64,
        "sharing": "unchanged immutable tile versions are shared across checkpoint roots",
    }:
        errors.append("APNG tile checkpoint root representation changed")
    sparse_motion = tile_checkpoint_plan.get("sparseMotion") or {}
    if sparse_motion.get("mode") != "deterministic-coprime-translation":
        errors.append("APNG tile sparse motion must remain deterministic")
    tile_boundaries = [
        str(item).lower() for item in tile_checkpoint_plan.get("modelBoundary") or []
    ]
    for token, message in (
        ("not a proof of global", "must not claim global optimality"),
        ("previous-disposal", "must bind previous-disposal semantics"),
        ("flat table", "must bind conservative root accounting"),
        ("not a product", "must forbid product claims"),
    ):
        if not any(token in item for item in tile_boundaries):
            errors.append(f"APNG tile checkpoint plan {message}")

    if compressed_checkpoint_plan.get("schemaVersion") != 1:
        errors.append("APNG compressed checkpoint plan schema must remain version 1")
    if compressed_checkpoint_plan.get("planID") != (
        "FOVEA-W5-APNG-COMPRESSED-CHECKPOINT-MODEL-V1"
    ):
        errors.append("APNG compressed checkpoint plan identity changed")
    if compressed_checkpoint_plan.get("basePlan") != (
        "Benchmarks/ComparativeLab/apng-checkpoint-plan.json"
    ):
        errors.append("APNG compressed checkpoint base plan changed")
    compression_model = compressed_checkpoint_plan.get("compressionModel") or {}
    if compression_model.get("id") != "straight-alpha-zlib-level-9-checksummed-v1":
        errors.append("APNG compressed checkpoint codec identity changed")
    if compression_model.get("level") != 9:
        errors.append("APNG compressed checkpoint zlib level changed")
    if compression_model.get("headerBytes") != 28 or compression_model.get("minimumBlobBytes") != 36:
        errors.append("APNG compressed checkpoint blob framing changed")
    if compression_model.get("decompressorWorkspaceBytes") != 256 * 1024:
        errors.append("APNG compressed checkpoint workspace bound changed")
    compressed_ratios = compressed_checkpoint_plan.get("checkpointBlobRatioPPM") or []
    if compressed_ratios != [
        2500, 5000, 10000, 20000, 50000, 100000, 250000, 500000, 750000, 1000000
    ]:
        errors.append("APNG compressed checkpoint ratio grid changed")
    if compressed_checkpoint_plan.get("referencePolicyPoint") != {
        "retainedBudgetMiB": 32,
        "maximumReplayFrames": 8,
        "modeledPeakHardCapMiB": 32,
    }:
        errors.append("APNG compressed checkpoint reference policy changed")
    compressed_reporting = compressed_checkpoint_plan.get("reportingPolicy") or {}
    if compressed_reporting.get("globalOptimalityClaim") is not False:
        errors.append("APNG compressed checkpoint plan must forbid global optimality claims")
    compressed_boundaries = [
        str(item).lower() for item in compressed_checkpoint_plan.get("modelBoundary") or []
    ]
    if not any("explicit sensitivity" in item for item in compressed_boundaries):
        errors.append("APNG compressed checkpoint plan must bind ratio sensitivity inputs")
    if not any("not evidence" in item for item in compressed_boundaries):
        errors.append("APNG compressed checkpoint plan must forbid ratio product claims")


    if owned_swift_study.get("schemaVersion") != 1:
        errors.append("owned Swift APNG playback study schema must remain version 1")
    if owned_swift_study.get("studyID") != (
        "FOVEA-W5-APNG-OWNED-SWIFT-PLAYBACK-ORACLE-2026-08"
    ):
        errors.append("owned Swift APNG playback study identity changed")
    owned_results = owned_swift_study.get("results") or {}
    if (
        owned_results.get("fixtureCount") != 7
        or owned_results.get("frameCount") != 24
        or owned_results.get("swiftPythonExactFrames") != 24
        or owned_results.get("swiftAppleExactFramesWhereAvailable") != 21
        or owned_results.get("separateDefaultSwiftPythonExactFrames") != 3
        or owned_results.get("allSwiftPythonExact") is not True
        or owned_results.get("allSwiftAppleExactWhereAvailable") is not True
        or owned_results.get("separateDefaultTimelineExact") is not True
    ):
        errors.append("owned Swift APNG playback exactness contract changed")
    owned_checkpoint = owned_results.get("checkpointExecutionCoverage") or {}
    if (
        owned_checkpoint.get("realOracleFixtureCheckpointCount") != 0
        or owned_checkpoint.get("syntheticTest") != "IMG_ANIM_PT_044"
        or owned_checkpoint.get("syntheticFrameCount") != 10
        or owned_checkpoint.get("syntheticRetainedCheckpointCount") != 1
    ):
        errors.append("owned Swift APNG checkpoint coverage boundary changed")
    owned_implementation = owned_swift_study.get("implementation") or {}
    owned_policy = owned_implementation.get("defaultPolicy") or {}
    if (
        owned_implementation.get("publicDecoderIntegrated") is not True
        or owned_implementation.get("captureRoutePublicDecoder") is not False
        or owned_implementation.get("publicDecoderStudy")
        != "docs/research/w5-apng-public-decoder-playback-2026-08.json"
        or owned_implementation.get("publicAPI") is not False
        or owned_implementation.get("foveaDependencyPinChanged") is not False
        or owned_policy.get("maximumCanvasDimension") != 1024
        or owned_policy.get("maximumRetainedBytes") != 32 * 1024 * 1024
        or owned_policy.get("maximumReplayFrames") != 8
        or owned_policy.get("decompressorWorkspaceBytes") != 256 * 1024
    ):
        errors.append("owned Swift APNG integration or policy boundary changed")
    owned_qualification = owned_results.get("qualification") or {}
    if (
        owned_qualification.get("imageCraftImageIOTests") != 111
        or owned_qualification.get("imageCraftCoreTests") != 16
        or owned_qualification.get("totalTests") != 127
        or owned_qualification.get("failures") != 0
        or owned_qualification.get("warningsAsErrorsReleaseBuildPassed") is not True
    ):
        errors.append("owned Swift APNG qualification contract changed")
    swift_prototype = (player_plan.get("checkpointEvidence") or {}).get("swiftPrototype") or {}
    if swift_prototype.get("sourceBoundPlaybackStudy") != (
        "docs/research/w5-apng-owned-swift-playback-2026-08.json"
    ):
        errors.append("player mechanism plan must bind the owned Swift playback study")
    composition = player_plan.get("compositionEvidence") or {}
    if (
        composition.get("ownedSwiftPythonExactFrames") != 24
        or composition.get("ownedSwiftAppleExactFramesWhereAvailable") != 21
        or composition.get("ownedSwiftSeparateDefaultExactFrames") != 3
    ):
        errors.append("player mechanism plan owned Swift exactness changed")


    if public_decoder_study.get("schemaVersion") != 1:
        errors.append("public ImageCraft APNG decoder study schema must remain version 1")
    if public_decoder_study.get("studyID") != (
        "FOVEA-W5-APNG-PUBLIC-IMAGECRAFT-DECODER-PLAYBACK-2026-08"
    ):
        errors.append("public ImageCraft APNG decoder study identity changed")
    public_results = public_decoder_study.get("results") or {}
    if (
        public_results.get("fixtureCount") != 7
        or public_results.get("frameCount") != 24
        or public_results.get("publicPythonExactFrames") != 24
        or public_results.get("publicAppleExactFramesWhereAvailable") != 21
        or public_results.get("separateDefaultPublicPythonExactFrames") != 3
        or public_results.get("allPublicPythonExact") is not True
        or public_results.get("allPublicAppleExactWhereAvailable") is not True
        or public_results.get("allReverseRandomAccessExact") is not True
        or public_results.get("allCancellationFenced") is not True
        or public_results.get("separateDefaultTimelineExact") is not True
    ):
        errors.append("public ImageCraft APNG decoder exactness/lifecycle contract changed")
    if (
        public_results.get("allBackingsOwnedAPNG") is not True
        or public_results.get("allRealFixtureCheckpointCountsZero") is not True
        or public_results.get("allOwnedRetainedWithin32MiB") is not True
        or public_results.get("realFixtureRetainedCheckpointCount") != 0
        or public_results.get("maximumObservedRetainedBytes") != 23796
        or public_results.get("maximumObservedModeledPeakBytesUpperBound") != 981940
    ):
        errors.append("public ImageCraft APNG backing/accounting aggregate changed")
    public_diagnostics = public_results.get("preparationDiagnostics") or {}
    if set(public_diagnostics) != {
        "APNG-OVER-BACKGROUND",
        "APNG-OVER-NONE",
        "APNG-OVER-PREVIOUS",
        "APNG-SEPARATE-DEFAULT",
        "APNG-SUBRECT-BACKGROUND",
        "APNG-SUBRECT-NONE",
        "APNG-SUBRECT-PREVIOUS-SOURCE",
    }:
        errors.append("public ImageCraft APNG diagnostics fixture set changed")
    for identifier, diagnostics in public_diagnostics.items():
        if (
            diagnostics.get("backingKind") != "ownedAPNG"
            or diagnostics.get("ownedRetainedCheckpointCount") != 0
            or diagnostics.get("ownedRetainedCheckpointBytes") != 0
            or diagnostics.get("ownedMaximumReplayFrames") != 8
            or diagnostics.get("ownedDecompressorWorkspaceBytes") != 256 * 1024
            or not isinstance(diagnostics.get("ownedRetainedBytes"), int)
            or diagnostics["ownedRetainedBytes"] <= 0
            or diagnostics["ownedRetainedBytes"] > 32 * 1024 * 1024
            or not isinstance(diagnostics.get("ownedModeledPeakBytesUpperBound"), int)
            or diagnostics["ownedModeledPeakBytesUpperBound"]
            <= diagnostics["ownedRetainedBytes"]
        ):
            errors.append(f"{identifier}: public APNG backing diagnostics changed")
        expected_alignment = identifier != "APNG-SEPARATE-DEFAULT"
        if diagnostics.get("imageIOSourceIndicesMatchTimeline") is not expected_alignment:
            errors.append(f"{identifier}: public APNG source-index alignment changed")

    public_implementation = public_decoder_study.get("implementation") or {}
    public_policy = public_implementation.get("ownedAdmissionPolicy") or {}
    public_fallback = public_implementation.get("fallbackPolicy") or {}
    if (
        public_implementation.get("codecFingerprint")
        != "dev.fovea.imageio.animation#impl=2#contract=2"
        or public_implementation.get("publicDecoderIntegrated") is not True
        or public_implementation.get("publicAPIAdded") is not False
        or public_implementation.get("foveaDependencyPinChanged") is not False
        or public_policy.get("maximumCanvasDimension") != 1024
        or public_policy.get("maximumRetainedBytes") != 32 * 1024 * 1024
        or public_policy.get("maximumReplayFrames") != 8
        or public_policy.get("decompressorWorkspaceBytes") != 256 * 1024
        or "fallback to Apple ImageIO" not in str(
            public_fallback.get("alignedUnsupportedAPNG")
        )
        or "fail closed" not in str(public_fallback.get("unalignedUnsupportedAPNG"))
    ):
        errors.append("public ImageCraft APNG admission/fallback boundary changed")
    public_qualification = public_results.get("qualification") or {}
    if (
        public_qualification.get("imageCraftImageIOTests") != 111
        or public_qualification.get("imageCraftCoreTests") != 16
        or public_qualification.get("totalTests") != 127
        or public_qualification.get("failures") != 0
        or public_qualification.get("warningsAsErrorsReleaseBuildPassed") is not True
    ):
        errors.append("public ImageCraft APNG qualification contract changed")
    public_tests = public_results.get("integrationTests") or {}
    if set(public_tests.values()) != {
        "IMG_ANIM_PT_045",
        "IMG_ANIM_PT_046",
        "IMG_ANIM_PT_047",
        "IMG_ANIM_PT_048",
        "IMG_ANIM_PT_049",
        "IMG_ANIM_PT_050",
        "IMG_ANIM_PT_051",
        "IMG_ANIM_PT_052",
    }:
        errors.append("public ImageCraft APNG integration test set changed")
    public_prototype = (player_plan.get("checkpointEvidence") or {}).get(
        "swiftPrototype"
    ) or {}
    if (
        public_prototype.get("publicDecoderStudy")
        != "docs/research/w5-apng-public-decoder-playback-2026-08.json"
        or public_prototype.get("codecFingerprint")
        != "dev.fovea.imageio.animation#impl=2#contract=2"
    ):
        errors.append("player mechanism plan must bind the public decoder study")
    public_composition = player_plan.get("compositionEvidence") or {}
    if (
        public_composition.get("publicDecoderPythonExactFrames") != 24
        or public_composition.get("publicDecoderAppleExactFramesWhereAvailable") != 21
        or public_composition.get("publicDecoderSeparateDefaultExactFrames") != 3
        or public_composition.get("publicDecoderReverseRandomAccessExact") is not True
        or public_composition.get("publicDecoderCancellationFenced") is not True
        or public_composition.get("publicDecoderBackingDiagnostics")
        != "all-seven-retained-fixtures-ownedAPNG"
        or public_composition.get("publicDecoderRealFixtureCheckpointCount") != 0
        or public_composition.get("publicDecoderMaximumObservedRetainedBytes") != 23796
        or public_composition.get("publicDecoderMaximumObservedModeledPeakBytesUpperBound")
        != 981940
    ):
        errors.append("player mechanism plan public decoder evidence changed")


    if public_decoder_mac_performance_study.get("schemaVersion") != 1:
        errors.append("public APNG Mac performance study schema must remain version 1")
    if public_decoder_mac_performance_study.get("studyID") != (
        "FOVEA-W5-APNG-PUBLIC-DECODER-MAC-MECHANISM-PERFORMANCE-2026-08"
    ):
        errors.append("public APNG Mac performance study identity changed")
    mac_system = public_decoder_mac_performance_study.get("system") or {}
    mac_results = public_decoder_mac_performance_study.get("results") or {}
    mac_scenarios = public_decoder_mac_performance_study.get("scenarios") or {}
    if (
        mac_system.get("hostRole")
        != "physical-mac-directional-mechanism-endpoint"
        or mac_system.get("physicalIOSDeviceUsed") is not False
        or mac_system.get("physicalIOSDeviceOnlineCount") != 0
        or mac_results.get("ownedReverseRandomAccessMismatchCount") != 0
        or mac_results.get("fallbackReverseRandomAccessMismatchCount") != 0
        or mac_results.get("bothSelectedFramePixelComparisonsExact") is not True
        or mac_results.get("bothCancellationFenced") is not True
    ):
        errors.append("public APNG Mac host/correctness boundary changed")
    mac_qualification = mac_results.get("qualification") or {}
    if (
        mac_qualification.get("imageCraftImageIOTests") != 111
        or mac_qualification.get("imageCraftCoreTests") != 16
        or mac_qualification.get("totalTests") != 127
        or mac_qualification.get("failures") != 0
        or mac_qualification.get("warningsAsErrorsReleaseBuildPassed") is not True
    ):
        errors.append("public APNG Mac performance qualification changed")
    owned_mac = mac_scenarios.get("OWNED-PIA-6") or {}
    fallback_mac = mac_scenarios.get("ALIGNED-FALLBACK-PEOPLE-24") or {}
    if (
        (owned_mac.get("backingDiagnostics") or {}).get("backingKind")
        != "ownedAPNG"
        or owned_mac.get("allReverseRandomAccessExact") is not True
        or owned_mac.get("reverseRandomAccessMismatchCount") != 0
        or owned_mac.get("selectedFramePixelsExact") is not True
        or (fallback_mac.get("backingDiagnostics") or {}).get("backingKind")
        != "imageIOEncoded"
        or fallback_mac.get("allReverseRandomAccessExact") is not True
        or fallback_mac.get("reverseRandomAccessMismatchCount") != 0
        or fallback_mac.get("selectedFramePixelsExact") is not True
    ):
        errors.append("public APNG Mac scenario role/correctness changed")
    ratio_ranges = {
        "ownedPrepareMedianOverDirectLowerBound": (0.5, 4.0),
        "ownedSelectedMedianOverDirectRetained": (3.0, 20.0),
        "ownedSequentialMedianOverDirectRetained": (1.0, 5.0),
        "fallbackPrepareMedianOverDirectLowerBound": (5.0, 60.0),
        "fallbackSelectedMedianOverDirectRetained": (0.5, 3.0),
        "fallbackSequentialMedianOverDirectRetained": (1.0, 4.0),
    }
    for name, (lower, upper) in ratio_ranges.items():
        value = mac_results.get(name)
        if not isinstance(value, (int, float)) or not lower <= value <= upper:
            errors.append(f"public APNG Mac ratio outside preregistered envelope: {name}")

    if imageio_cache_divergence_study.get("schemaVersion") != 1:
        errors.append("APNG ImageIO cache divergence study schema must remain version 1")
    if imageio_cache_divergence_study.get("studyID") != (
        "FOVEA-W5-APNG-IMAGEIO-FALLBACK-CACHE-DIVERGENCE-2026-08"
    ):
        errors.append("APNG ImageIO cache divergence study identity changed")
    cache_counterexample = imageio_cache_divergence_study.get("counterexample") or {}
    cache_fix = imageio_cache_divergence_study.get("currentFix") or {}
    if (
        cache_counterexample.get("backingKind") != "imageIOEncoded"
        or cache_counterexample.get("frameCount") != 24
        or cache_counterexample.get("reverseRandomAccessMismatchCount") != 23
        or len(cache_counterexample.get("reverseRandomAccessMismatchIndices") or [])
        != 23
        or cache_counterexample.get("cancellationFenced") is not True
        or cache_fix.get("regressionTest") != "IMG_ANIM_PT_052"
        or cache_fix.get("currentFallbackReverseRandomAccessMismatchCount") != 0
    ):
        errors.append("APNG ImageIO cache divergence/fix contract changed")

    if imagecraft_adapter_study.get("schemaVersion") != 1:
        errors.append("ImageCraft animation adapter study schema must remain version 1")
    if imagecraft_adapter_study.get("studyID") != (
        "FOVEA-W5-IMAGECRAFT-ANIMATION-ADAPTER-OVERLAY-QUALIFICATION-2026-08"
    ):
        errors.append("ImageCraft animation adapter study identity changed")
    adapter_source = imagecraft_adapter_study.get("sourceIdentity") or {}
    adapter_results = imagecraft_adapter_study.get("results") or {}
    adapter_implementation = imagecraft_adapter_study.get("implementation") or {}
    adapter_evidence = imagecraft_adapter_study.get("evidence") or {}
    if (
        adapter_source.get("imageCraftWorkingTree")
        != "d3fc33648a0aaf1bd26ecaa586c127c4653dab4c"
        or adapter_source.get("sourcesUnchangedDuringRun") is not True
        or adapter_source.get("foveaImplementationFileCount") != 20
        or adapter_source.get("foveaImplementationUnchangedDuringRun") is not True
    ):
        errors.append("ImageCraft animation adapter source identity changed")
    if (
        adapter_results.get("qualificationTest") != "W5_ADAPTER_PT_001"
        or adapter_results.get("timelineQualificationTest") != "W5_ADAPTER_PT_002"
        or adapter_results.get("gifQualificationTest") != "W5_ADAPTER_PT_003"
        or adapter_results.get("invalidTimingQualificationTest") != "W5_ADAPTER_PT_004"
        or adapter_results.get("passed") is not True
        or adapter_results.get("directImageCraftContainer") != "apng"
        or adapter_results.get("directImageCraftFrameCount") != 3
        or adapter_results.get("fullTimelineFrameCount") != 3
        or adapter_results.get("firstThreeVisibleFrameIndices") != [0, 1, 2]
        or adapter_results.get("allThreeTimelineFramesStandardSRGBPremultipliedRGBAExactVsDirectImageCraft")
        is not True
        or adapter_results.get("directImageCraftAdditionalRepeatCount") != 0
        or adapter_results.get("normalPlaybackTimelineCompleted") is not True
        or adapter_results.get("driverCountAfterTimelineCancellation") != 0
        or adapter_results.get("gifContainer") != "gif"
        or adapter_results.get("gifFrameCount") != 2
        or adapter_results.get("gifSourceFrameDurationsAreZero") is not True
        or adapter_results.get("gifPlaybackMode") != "playOnce"
        or adapter_results.get("gifFirstTwoVisibleFrameIndices") != [0, 1]
        or adapter_results.get("gifAllFramesStandardSRGBPremultipliedRGBAExactVsDirectImageCraft")
        is not True
        or adapter_results.get("gifZeroDurationReplacementNanoseconds") != 10_000_000
        or adapter_results.get("gifObservedSleepDeadlinesNanoseconds")
        != [10_000_000, 20_000_000]
        or adapter_results.get("driverCountAfterGIFCancellation") != 0
        or adapter_results.get("invalidZeroDurationReplacementRejected") is not True
        or adapter_results.get("invalidTimingError") != "invalidZeroDurationReplacement"
        or adapter_results.get("postPrepareTimelineFailureFailsClosed") is not True
        or adapter_results.get("driverCountAfterInvalidTimingFailure") != 0
        or adapter_results.get("foveaAuthorizedPipelineUsed") is not True
        or adapter_results.get("firstFrameStandardSRGBPremultipliedRGBAExactVsDirectImageCraft")
        is not True
        or adapter_results.get("driverCountAfterCancellation") != 0
        or adapter_results.get("strictSwiftFormatPassed") is not True
        or adapter_results.get("warningsAsErrorsOverlayExecutablePassed") is not True
        or adapter_results.get("oldProductionPinWarningsAsErrorsIOS15BuildPassed") is not True
        or adapter_results.get("currentImageCraftOverlayWarningsAsErrorsBuildPassed") is not True
        or adapter_results.get("productionPackageModified") is not False
        or adapter_results.get("productionImageCraftPinChanged") is not False
    ):
        errors.append("ImageCraft animation adapter qualification result changed")
    if (
        adapter_implementation.get("candidateSource")
        != "Tools/AnimationAdapterQualification/ImageCraftAnimationPlaybackPreparer.swift.fixture"
        or adapter_implementation.get("preparerProtocol")
        != "EncodedAnimationPlaybackPreparing"
        or adapter_implementation.get("productionImageCraftPinChanged") is not False
        or adapter_implementation.get("publicFoveaAPIAdded") is not False
        or (adapter_implementation.get("timelineMapping") or {}).get(
            "zeroDurationReplacement"
        )
        != "explicit caller input"
        or (adapter_implementation.get("timelineMapping") or {}).get(
            "timingPolicyVersion"
        )
        != "explicit caller input"
    ):
        errors.append("ImageCraft animation adapter implementation boundary changed")
    if (
        adapter_evidence.get("captureReport")
        != ".artifacts/qualification/w5-imagecraft-animation-adapter-v1/report.json"
        or adapter_evidence.get("captureRunner")
        != "Tools/AnimationAdapterQualification/qualify_imagecraft_animation_adapter.py"
        or adapter_evidence.get("validator")
        != "Tools/AnimationAdapterQualification/validate_imagecraft_animation_adapter_qualification.py"
        or adapter_evidence.get("tamperContract")
        != "Tools/AnimationAdapterQualification/test_imagecraft_animation_adapter_qualification.py"
    ):
        errors.append("ImageCraft animation adapter evidence paths changed")
    adapter_plan = (player_plan.get("checkpointEvidence") or {}).get("swiftPrototype") or {}
    adapter_plan_result = adapter_plan.get("foveaAdapterQualification") or {}
    if (
        adapter_plan.get("foveaAdapterQualificationStudy")
        != "docs/research/w5-imagecraft-animation-adapter-qualification-2026-08.json"
        or adapter_plan_result.get("status")
        != "isolated-source-overlay-passed-production-pin-unchanged"
        or adapter_plan_result.get("test") != "W5_ADAPTER_PT_001"
        or adapter_plan_result.get("timelineTest") != "W5_ADAPTER_PT_002"
        or adapter_plan_result.get("tests")
        != [
            "W5_ADAPTER_PT_001",
            "W5_ADAPTER_PT_002",
            "W5_ADAPTER_PT_003",
            "W5_ADAPTER_PT_004",
        ]
        or adapter_plan_result.get("gifTest") != "W5_ADAPTER_PT_003"
        or adapter_plan_result.get("invalidTimingTest") != "W5_ADAPTER_PT_004"
        or adapter_plan_result.get("invalidZeroDurationReplacementRejected") is not True
        or adapter_plan_result.get("postPrepareTimelineFailureFailsClosed") is not True
        or adapter_plan_result.get("driverCountAfterInvalidTimingFailure") != 0
        or adapter_plan_result.get("gifFrameCount") != 2
        or adapter_plan_result.get("gifFullTimelinePixelExactVsDirectImageCraft") is not True
        or adapter_plan_result.get("gifSourceFrameDurationsAreZero") is not True
        or adapter_plan_result.get("gifZeroDurationReplacementDeadlinesNanoseconds")
        != [10_000_000, 20_000_000]
        or adapter_plan_result.get("driverCountAfterGIFCancellation") != 0
        or adapter_plan_result.get("fullTimelinePixelExactVsDirectImageCraft") is not True
        or adapter_plan_result.get("firstThreeVisibleFrameIndices") != [0, 1, 2]
        or adapter_plan_result.get("directAdditionalRepeatCount") != 0
        or adapter_plan_result.get("driverCountAfterTimelineCancellation") != 0
        or adapter_plan_result.get("imageCraftWorkingTree")
        != "5c07f313cf57495b6ffc7f578be8acbdd3e64c13"
        or adapter_plan_result.get("authorizedFoveaSystemPipeline") is not True
        or adapter_plan_result.get("separateDefaultFrameCount") != 3
        or adapter_plan_result.get("firstFramePixelExactVsDirectImageCraft") is not True
        or adapter_plan_result.get("driverCountAfterCancellation") != 0
        or adapter_plan_result.get("warningsAsErrorsPassed") is not True
        or adapter_plan_result.get("productionImageCraftPinChanged") is not False
    ):
        errors.append("player mechanism plan ImageCraft adapter qualification changed")
    # Source-bound semantic replay evidence must remain narrow and tamper-evident.
    semantic_source = semantic_replay_study.get("sourceIdentity") or {}
    semantic_analytical = semantic_replay_study.get("analyticalEvidence") or {}
    semantic_results = semantic_replay_study.get("results") or {}
    semantic_runtime = semantic_replay_study.get("imageCraftRuntimeCandidate") or {}
    semantic_runtime_tests = semantic_runtime.get("tests") or {}
    if (
        semantic_replay_study.get("schemaVersion") != 1
        or semantic_replay_study.get("studyID")
        != "FOVEA-W5-APNG-SEMANTIC-REPLAY-2026-08"
        or semantic_source.get("commit")
        != "42ba209608cb332887a33ebcae1bde50c52b151d"
        or semantic_source.get("sourceFileSHA256")
        != "acdc7da4aa8cbc5c5902ed0220c9ce1abb1aa476100dd941a89d52b0b4798456"
        or semantic_analytical.get("reportFileSHA256")
        != "67bf131256fa7ae400834b9c64260ce267ca96759fee987390355b204ff74095"
        or semantic_analytical.get("reportCanonicalSHA256")
        != "1504983de00db7d958c94ba069ad3effef42aa30c77dd56ebc2907c1da229f8c"
        or semantic_analytical.get("modelTestsPassed") != 13
        or semantic_analytical.get("sourceOracleTestsPassed") != 4
        or semantic_results.get("allRealFixturesNonRegressingAtSameRetainedAndPeakBytes")
        is not True
        or semantic_results.get("realFixturesWithStrictReplayImprovement")
        != ["APNG-OVER-BACKGROUND"]
        or semantic_runtime.get("workingTree")
        != "5c07f313cf57495b6ffc7f578be8acbdd3e64c13"
        or semantic_runtime_tests.get("imageIOTestsPassed") != 115
        or semantic_runtime_tests.get("coreTestsPassed") != 16
        or semantic_runtime_tests.get("warningsAsErrorsReleaseBuildPassed") is not True
    ):
        errors.append("APNG semantic replay source/runtime evidence changed")
    yy = next((item for item in libraries if item.get("id") == "CMP-YYIMAGE"), {})
    apngkit = next((item for item in libraries if item.get("id") == "CMP-APNGKIT"), {})
    if (
        yy.get("w5SourceOracleStatus")
        != "semantic-replay-source-oracle-completed-runtime-candidate-derived-no-player-ranking"
        or "docs/research/w5-apng-semantic-replay-2026-08.json"
        not in (yy.get("w5Evidence") or [])
    ):
        errors.append("YYImage semantic replay registry binding changed")
    if (
        apngkit.get("w5AdapterStatus")
        != "apng-variable-delay-structural-calibrated-ios15-plus-current-digest-bound"
        or ".artifacts/w5-player-timing/simulator/20260807T084837Z/manifest.json"
        not in (apngkit.get("w5Evidence") or [])
    ):
        errors.append("APNGKit W5 adapter registry binding changed")

    matrix_systems = set(mechanism_matrix.get("systems") or [])
    if not {"Fovea", "ImageCraft"} <= matrix_systems:
        errors.append("mechanism matrix must include Fovea and ImageCraft")
    allowed_status = set(mechanism_matrix.get("statusVocabulary") or [])
    if len(mechanism_matrix.get("mechanisms") or []) < 8:
        errors.append("mechanism matrix requires at least eight material mechanisms")
    for item in mechanism_matrix.get("mechanisms") or []:
        coverage = item.get("coverage") or {}
        if set(coverage) != matrix_systems:
            errors.append(f"{item.get('id')}: coverage must include every registered matrix system")
        invalid = set(coverage.values()) - allowed_status
        if invalid:
            errors.append(f"{item.get('id')}: invalid matrix status {sorted(invalid)}")
        if not item.get("importance") or not item.get("foveaDecision") or not item.get("note"):
            errors.append(f"{item.get('id')}: importance, decision, and note are required")
    if errors:
        print("Animated image library registry invalid:")
        for error in errors:
            print(f"- {error}")
        return 1
    print(
        f"Animated image library registry: libraries={len(libraries)} "
        f"features={len(features)} checkpointScenarios={len(checkpoint_scenarios)} "
        f"tileSizes={len(tile_checkpoint_plan.get('tileSizes') or [])} "
        f"compressedRatios={len(compressed_ratios)} ownedSwiftFrames={owned_results.get('frameCount')} publicDecoderFrames={public_results.get('frameCount')} errors=0"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
