#!/usr/bin/env python3
"""Verify the reproducible FoveaWorkbench project and local evidence matrix."""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

from ios_example_process import (
    command_output,
    digest,
    inactivity_expired,
    run,
    terminate_process_group,
    workspace_tree,
)
from ios_example_reporting import verification_profile, write_verification_report
from ios_example_visual import (
    VISUAL_CAPTURE_ATTEMPTS,
    VISUAL_FAMILY_TIMEOUT_SECONDS,
    capture_visual_family,
    prepare_visual_family,
    terminate_visual_family_xcodebuild,
    verify_visual_assurance,
)
from ios_example_xcode import (
    UI_TEST_CASE_TIMEOUT_SECONDS,
    UI_TEST_INACTIVITY_TIMEOUT_SECONDS,
    UI_TEST_SUITE_BASE_TIMEOUT_SECONDS,
    balanced_shards,
    ensure_simulator_booted,
    is_simulator_infrastructure_failure,
    recover_core_simulator_service,
    restart_simulator,
    run_xcode_phase,
    run_xcode_sharded_phase,
    simulator,
    simulator_state,
    test_count,
    ui_suite_timeout_seconds,
    ui_test_case_count,
    ui_test_methods,
    ui_test_methods_in_files,
    verify_release_build,
    xcode_environment,
)

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "Examples/FoveaWorkbenchApp"
PROJECT = EXAMPLE / "FoveaWorkbench.xcodeproj"
PBXPROJ = PROJECT / "project.pbxproj"
XCODEGEN_VERSION_FILE = EXAMPLE / ".xcodegen-version"
ARTIFACTS = ROOT / ".artifacts/ios-example"
GENERATED_METADATA = (
    EXAMPLE / "FoveaWorkbench/App/WorkbenchBuildMetadata.generated.swift"
)
VISUAL_AUDIT_TIMEOUT_SECONDS = 5_400
REGULAR_WIDTH_NAVIGATION_TEST = (
    "FoveaWorkbenchUITests/FoveaWorkbenchUITests/"
    "testEcologicalAtlasOpensLibraryCasesMapGlossaryAndMethodology_DEMO_PT_024"
)
COMPACT_SMOKE_TEST = (
    "FoveaWorkbenchUITests/FoveaWorkbenchUITests/"
    "testSingleImageLabPublishesExpectedActualEvidence"
)
IPAD_SMOKE_TEST = (
    "FoveaWorkbenchUITests/FoveaWorkbenchIPadUITests/"
    "testIPadLaunchShowsResponsiveEcologicalAtlas_DEMO_PT_027"
)
COMPACT_UI_TEST_FILE = EXAMPLE / "FoveaWorkbenchUITests/FoveaWorkbenchUITests.swift"
GENERATED_PROJECT_FILES = (
    PBXPROJ,
    PROJECT / "xcshareddata/xcschemes/FoveaWorkbench.xcscheme",
    PROJECT / "project.xcworkspace/contents.xcworkspacedata",
)
REQUIRED_GENERATED_REFERENCES = (
    "WorkbenchDesignSystem.swift",
    "WorkbenchButtonStyles.swift",
    "WorkbenchImageSurface.swift",
    "WorkbenchVisualSystemTests.swift",
    "FoveaWorkbenchNavigationUITests.swift",
)
FORBIDDEN_GENERATED_REFERENCES = (
    "workbench-image-blue.png",
    "workbench-image-orange.png",
    "fovea-task",
)


def generated_project_snapshot() -> dict[str, str]:
    snapshot: dict[str, str] = {}
    for path in GENERATED_PROJECT_FILES:
        if not path.is_file():
            raise RuntimeError(
                f"generated FoveaWorkbench project file is missing: {path.relative_to(ROOT)}"
            )
        snapshot[str(path.relative_to(ROOT))] = digest(path)
    return snapshot


def validate_generated_project_text(text: str) -> None:
    if "IPHONEOS_DEPLOYMENT_TARGET = 15.0;" not in text:
        raise RuntimeError("FoveaWorkbench deployment target is not iOS 15.0")
    if "name = Fovea; path = ../..;" not in text:
        raise RuntimeError("FoveaWorkbench package reference is not the canonical Fovea ../.. path")
    local_media_folder_reference = (
        "lastKnownFileType = folder; name = LocalMedia; "
        "path = FoveaWorkbench/Resources/LocalMedia; sourceTree = SOURCE_ROOT;"
    )
    if local_media_folder_reference not in text or "LocalMedia in Resources" not in text:
        raise RuntimeError(
            "FoveaWorkbench LocalMedia must be copied as one folder reference so encoded media "
            "bytes are not rewritten by per-file resource tools"
        )
    deterministic_png_references = (
        "local-000-a-view-of-the-taunus-mountain-range-during-fog-3-png-0cbecba781.png",
        "local-015-flaming-star-nebula-ic-405-png-11c3c5b390.png",
    )
    if any(name in text for name in deterministic_png_references):
        raise RuntimeError(
            "FoveaWorkbench deterministic PNG fixtures must not be individual PBX image resources"
        )
    missing = [name for name in REQUIRED_GENERATED_REFERENCES if name not in text]
    if missing:
        raise RuntimeError(f"generated FoveaWorkbench project omits required sources: {missing}")
    forbidden = [token for token in FORBIDDEN_GENERATED_REFERENCES if token in text]
    if forbidden:
        raise RuntimeError(f"generated FoveaWorkbench project contains forbidden references: {forbidden}")


def xcodegen_version(executable: str) -> str:
    output = subprocess.run(
        [executable, "--version"], text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, check=True,
    ).stdout.strip()
    return output.removeprefix("Version:").strip()


def regenerate_project(env: dict[str, str]) -> None:
    executable = shutil.which("xcodegen")
    if executable is None:
        raise RuntimeError("xcodegen is required to verify the iOS example")
    expected = XCODEGEN_VERSION_FILE.read_text().strip()
    actual = xcodegen_version(executable)
    if actual != expected:
        raise RuntimeError(f"xcodegen version mismatch: expected {expected}, found {actual}")
    before = generated_project_snapshot()
    completed = run([str(ROOT / "scripts/generate-ios-example.sh")], env=env, timeout=120)
    if completed.returncode != 0:
        raise RuntimeError(f"XcodeGen failed:\n{completed.stdout}")
    after = generated_project_snapshot()
    if after != before:
        changed = sorted(path for path in before.keys() | after.keys() if before.get(path) != after.get(path))
        raise RuntimeError(f"FoveaWorkbench.xcodeproj is not reproducible from project.yml: {changed}")
    validate_generated_project_text(PBXPROJ.read_text())


def pin_simulator_environment(
    env: dict[str, str], *, include_ipad: bool
) -> dict[str, str]:
    """Resolve only the device families required by this verification session."""
    pinned = dict(env)
    iphone = simulator(pinned, "iphone")
    pinned["FOVEA_IPHONE_SIMULATOR_ID"] = iphone
    if include_ipad:
        ipad = simulator(pinned, "ipad")
        pinned["FOVEA_IPAD_SIMULATOR_ID"] = ipad
        print(f"Pinned FoveaWorkbench simulators: iphone={iphone} ipad={ipad}")
    else:
        pinned.pop("FOVEA_IPAD_SIMULATOR_ID", None)
        print(f"Pinned FoveaWorkbench simulator: iphone={iphone}")
    return pinned


def base_phases(args: argparse.Namespace, env: dict[str, str]) -> list[dict[str, str]]:
    phases: list[dict[str, str]] = []
    if not args.skip_release_build:
        phases.append(
            verify_release_build(
                env, clean_derived_data=not args.reuse_release_derived_data
            )
        )
    phases.append(run_xcode_phase(
        "unit-tests", ["-only-testing:FoveaWorkbenchTests", "test"], env=env,
        inactivity_timeout_seconds=UI_TEST_INACTIVITY_TIMEOUT_SECONDS,
    ))
    if not args.skip_live_network:
        phases.append(run_xcode_phase(
            "live-network-tests",
            ["FOVEA_RUN_LIVE_NETWORK=1", "-only-testing:FoveaWorkbenchLiveTests", "test"],
            env={**env, "RUN_LIVE_NETWORK": "1"}, device_family="iphone",
            require_no_skips=True,
        ))
    return phases


ECOLOGICAL_MATRIX_PREFIX = (
    "testEveryEcologicalStoryBuildsItsDeclaredMediaSurface"
)
FAST_FASHION_REGRESSION_TEST = "testFastFashionMediaSurfaceRetainsFiveIdentities"


def compact_ui_methods() -> list[str]:
    navigation = REGULAR_WIDTH_NAVIGATION_TEST.rsplit("/", 1)[-1]
    methods = [
        method for method in ui_test_methods(COMPACT_UI_TEST_FILE)
        if method != navigation
    ]
    if len(methods) != 19:
        raise RuntimeError(f"unexpected compact-width UI test count: {len(methods)}")
    return methods


def compact_ui_method_groups() -> tuple[list[str], list[str]]:
    methods = compact_ui_methods()
    ecological = [
        method for method in methods
        if method.startswith(ECOLOGICAL_MATRIX_PREFIX)
        or method == FAST_FASHION_REGRESSION_TEST
    ]
    regular = [method for method in methods if method not in ecological]
    if len(regular) != 14 or len(ecological) != 5:
        raise RuntimeError(
            "unexpected compact UI partition: "
            f"regular={len(regular)} ecological={len(ecological)}"
        )
    return regular, ecological


def combine_compact_ui_phases(
    regular: dict[str, str], ecological: dict[str, str]
) -> dict[str, str]:
    log = ARTIFACTS / "ui-tests.log"
    log.write_text(
        (ROOT / regular["log"]).read_text(errors="replace")
        + "\n=== isolated ecological story matrix ===\n"
        + (ROOT / ecological["log"]).read_text(errors="replace")
    )
    return {
        **regular,
        "name": "ui-tests",
        "log": str(log.relative_to(ROOT)),
        "logSha256": digest(log),
        "testCount": int(regular["testCount"]) + int(ecological["testCount"]),
    }


def compact_ui_phase(env: dict[str, str]) -> dict[str, str]:
    regular_methods, ecological_methods = compact_ui_method_groups()
    regular = run_xcode_sharded_phase(
        "ui-tests-core", "FoveaWorkbenchUITests/FoveaWorkbenchUITests",
        regular_methods, shard_count=3, env=env, device_family="iphone",
    )
    restart_simulator(simulator(env, "iphone"), env)
    ecological = run_xcode_sharded_phase(
        "ui-tests-ecology-matrix", "FoveaWorkbenchUITests/FoveaWorkbenchUITests",
        ecological_methods, shard_count=len(ecological_methods),
        env=env, device_family="iphone",
    )
    return combine_compact_ui_phases(regular, ecological)


def native_ipad_methods() -> list[str]:
    source = EXAMPLE / "FoveaWorkbenchUITests/FoveaWorkbenchIPadUITests.swift"
    methods = ui_test_methods(source)
    if len(methods) != 4:
        raise RuntimeError(f"unexpected native regular-width UI test count: {len(methods)}")
    return methods


def navigation_phase(env: dict[str, str]) -> dict[str, str]:
    restart_simulator(simulator(env, "ipad"), env)
    result = run_xcode_phase(
        "ipad-ui-tests-navigation",
        [f"-only-testing:{REGULAR_WIDTH_NAVIGATION_TEST}", "test"],
        env=env, device_family="ipad",
        timeout_seconds=UI_TEST_SUITE_BASE_TIMEOUT_SECONDS + UI_TEST_CASE_TIMEOUT_SECONDS,
        inactivity_timeout_seconds=UI_TEST_INACTIVITY_TIMEOUT_SECONDS,
    )
    if int(result["testCount"]) != 1:
        raise RuntimeError("regular-width navigation shard did not execute exactly one test")
    return result


def combine_ipad_phases(
    native: dict[str, str], navigation: dict[str, str]
) -> dict[str, str]:
    log = ARTIFACTS / "ipad-ui-tests.log"
    log.write_text(
        (ROOT / native["log"]).read_text(errors="replace")
        + "\n=== regular-width navigation shard ===\n"
        + (ROOT / navigation["log"]).read_text(errors="replace")
    )
    return {
        **native,
        "log": str(log.relative_to(ROOT)),
        "logSha256": digest(log),
        "testCount": int(native["testCount"]) + 1,
    }


def regular_ui_phase(env: dict[str, str]) -> dict[str, str]:
    native = run_xcode_sharded_phase(
        "ipad-ui-tests", "FoveaWorkbenchUITests/FoveaWorkbenchIPadUITests",
        native_ipad_methods(), shard_count=2, env=env, device_family="ipad",
    )
    return combine_ipad_phases(native, navigation_phase(env))


def compact_ui_smoke_phase(env: dict[str, str]) -> dict[str, str]:
    result = run_xcode_phase(
        "ui-smoke", [f"-only-testing:{COMPACT_SMOKE_TEST}", "test"],
        env=env, device_family="iphone",
        timeout_seconds=UI_TEST_SUITE_BASE_TIMEOUT_SECONDS + UI_TEST_CASE_TIMEOUT_SECONDS,
        inactivity_timeout_seconds=UI_TEST_INACTIVITY_TIMEOUT_SECONDS,
    )
    if int(result["testCount"]) != 1:
        raise RuntimeError("compact Workbench smoke did not execute exactly one test")
    return result


def regular_ui_smoke_phase(env: dict[str, str]) -> dict[str, str]:
    result = run_xcode_phase(
        "ipad-ui-smoke", [f"-only-testing:{IPAD_SMOKE_TEST}", "test"],
        env=env, device_family="ipad",
        timeout_seconds=UI_TEST_SUITE_BASE_TIMEOUT_SECONDS + UI_TEST_CASE_TIMEOUT_SECONDS,
        inactivity_timeout_seconds=UI_TEST_INACTIVITY_TIMEOUT_SECONDS,
    )
    if int(result["testCount"]) != 1:
        raise RuntimeError("regular-width Workbench smoke did not execute exactly one test")
    return result


def run_requested_phases(
    args: argparse.Namespace, env: dict[str, str]
) -> list[dict[str, str]]:
    phases = base_phases(args, env)
    if args.skip_ui:
        return phases
    if args.ui_smoke:
        phases.extend([compact_ui_smoke_phase(env), regular_ui_smoke_phase(env)])
        return phases
    phases.extend([compact_ui_phase(env), regular_ui_phase(env)])
    return phases


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verify the iOS 15+ FoveaWorkbench example app.")
    parser.add_argument("--skip-ui", action="store_true")
    parser.add_argument(
        "--ui-smoke", action="store_true",
        help="run one bounded representative UI test per device family",
    )
    parser.add_argument("--skip-live-network", action="store_true")
    parser.add_argument(
        "--skip-release-build", action="store_true",
        help="skip Release binary audit; only bounded smart smoke may use this",
    )
    parser.add_argument(
        "--reuse-release-derived-data", action="store_true",
        help="reuse the bounded local Release DerivedData cache for developer/premerge gates",
    )
    parser.add_argument(
        "--skip-visual", action="store_true",
        help="skip the strict iPhone/iPad screenshot, geometry, and accessibility matrix",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    if args.skip_ui and args.ui_smoke:
        print("--skip-ui and --ui-smoke are mutually exclusive", file=sys.stderr)
        return 2
    original_metadata = GENERATED_METADATA.read_bytes() if GENERATED_METADATA.is_file() else None
    try:
        env = xcode_environment()
        regenerate_project(env)
        env = pin_simulator_environment(env, include_ipad=not args.skip_ui)
        if not args.skip_ui and not args.skip_visual:
            verify_visual_assurance(env)
        phases = run_requested_phases(args, env)
        if original_metadata is None:
            GENERATED_METADATA.unlink(missing_ok=True)
        else:
            GENERATED_METADATA.write_bytes(original_metadata)
        report_path = write_verification_report(phases, env)
        print(
            "FoveaWorkbench verification passed: "
            f"{report_path.relative_to(ROOT)} sha256:{digest(report_path)}"
        )
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    finally:
        if original_metadata is None:
            GENERATED_METADATA.unlink(missing_ok=True)
        else:
            GENERATED_METADATA.write_bytes(original_metadata)


if __name__ == "__main__":
    raise SystemExit(main())
