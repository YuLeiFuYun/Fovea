#!/usr/bin/env python3
from __future__ import annotations

import ast
import importlib.util
import os
import json
import re
import signal
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
errors: list[str] = []

for path in sorted((ROOT / "scripts").glob("*.py")):
    try:
        ast.parse(path.read_text(), filename=str(path))
    except (SyntaxError, UnicodeError) as error:
        errors.append(f"python syntax error in {path.relative_to(ROOT)}: {error}")

for path in sorted((ROOT / "scripts").glob("*.sh")):
    result = subprocess.run(
        ["/bin/sh", "-n", str(path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if result.returncode != 0:
        errors.append(
            f"shell syntax error in {path.relative_to(ROOT)}: {result.stdout.strip()}"
        )

mutation_runner = (ROOT / "scripts/run-critical-mutants.py").read_text()
for removed_prefix in (
    "Sources/ImageCraftCore/",
    "Sources/ImageCraftImageIO/",
    "Sources/AkashicCore/",
    "Sources/AkashicMemory/",
    "Sources/AkashicDisk/",
):
    if f'root / "{removed_prefix}' in mutation_runner:
        errors.append(f"mutation runner references removed embedded component path: {removed_prefix}")
    if re.search(rf'Mutant\([^\n]+"{re.escape(removed_prefix)}', mutation_runner):
        errors.append(f"mutation catalog records removed embedded component path: {removed_prefix}")
if "weak var encoded: OriginalEncodedStore?" in mutation_runner:
    errors.append("mutation runner still targets the retired OriginalEncodedStore type")
if '"--validate-applications"' not in mutation_runner:
    errors.append("mutation runner must expose the application-only freshness audit")
verify_script = (ROOT / "scripts/verify.sh").read_text()
if "python3 scripts/check-actions-budget-governance.py" not in verify_script:
    errors.append("verify.sh must enforce hosted Actions budget governance")
if "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES" in verify_script:
    errors.append(
        "verify.sh must not override external SwiftPM warning policy through a global Xcode setting"
    )
if "-collect-test-diagnostics never" not in verify_script:
    errors.append(
        "iOS package verification must disable Xcode sysdiagnose collection and rely on bounded logs"
    )

try:
    x86_runner_path = ROOT / "scripts/run-x86-identity-test.py"
    x86_spec = importlib.util.spec_from_file_location("fovea_x86_identity", x86_runner_path)
    if x86_spec is None or x86_spec.loader is None:
        raise RuntimeError("unable to load x86 identity runner")
    x86_runner = importlib.util.module_from_spec(x86_spec)
    x86_spec.loader.exec_module(x86_runner)
    command = x86_runner.xctest_command(
        Path("/toolchain/usr/bin/xctest"),
        Path("/tmp/FoveaTests.xctest"),
    )
    if command != [
        "/usr/bin/arch",
        "-x86_64",
        "/toolchain/usr/bin/xctest",
        "-XCTest",
        (
            "FoveaTests.IdentityTests/"
            "testPersistentIdentityGoldenVectorsAreArchitectureStable_CACHE_PT_017"
        ),
        "/tmp/FoveaTests.xctest",
    ]:
        errors.append("x86 identity runner must execute the exact XCTest selector under Rosetta")
    x86_source = x86_runner_path.read_text()
    for marker in (
        '"--build-tests"',
        'executable_architectures != ["x86_64"]',
        'environment["FOVEA_EXPECTED_TEST_ARCH"] = "x86_64"',
        '"DYLD_FRAMEWORK_PATH"',
        '"DYLD_LIBRARY_PATH"',
    ):
        if marker not in x86_source:
            errors.append(f"x86 identity runner is missing contract marker: {marker}")
except (OSError, RuntimeError, ValueError) as error:
    errors.append(f"x86 identity runner contract failed: {error}")

navigation_ui_source = (
    ROOT / "Examples/FoveaWorkbenchApp/FoveaWorkbenchUITests/"
    "FoveaWorkbenchNavigationUITests.swift"
).read_text()
ipad_ui_source = (
    ROOT / "Examples/FoveaWorkbenchApp/FoveaWorkbenchUITests/"
    "FoveaWorkbenchIPadUITests.swift"
).read_text()
if "addTeardownBlock { @MainActor in" not in navigation_ui_source:
    errors.append("compact Workbench UI launches must register main-actor app termination")
if navigation_ui_source.count("registerTermination(of: app)") < 3:
    errors.append("every compact Workbench UI launch helper must register app termination")
if "addTeardownBlock { @MainActor in" not in ipad_ui_source:
    errors.append("regular-width Workbench UI launches must register app termination")
if ipad_ui_source.count("registerTermination(of: app)") < 1:
    errors.append("regular-width Workbench UI launch helper must register app termination")
application_gate = "python3 scripts/run-critical-mutants.py --validate-applications"
full_gate = "python3 scripts/run-critical-mutants.py\n"
if application_gate not in verify_script:
    errors.append("verify.sh must run the mutation application audit before critical mutants")
elif full_gate not in verify_script or verify_script.index(application_gate) > verify_script.index(full_gate):
    errors.append("mutation application audit must precede the full critical mutation run")

try:
    swift_format = json.loads((ROOT / ".swift-format").read_text())
    if swift_format.get("indentation") != {"spaces": 4}:
        errors.append(".swift-format must enforce four-space indentation")
except (OSError, json.JSONDecodeError, UnicodeError) as error:
    errors.append(f"invalid .swift-format configuration: {error}")

try:
    verifier_path = ROOT / "scripts/verify-ios-example.py"
    spec = importlib.util.spec_from_file_location("fovea_verify_ios_example", verifier_path)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load iOS example verifier")
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    import ios_example_process as process_support
    import ios_example_visual as visual_support
    import ios_example_xcode as xcode_support

    extension_source = (
        ROOT / "Examples/FoveaWorkbenchApp/FoveaWorkbenchUITests/"
        "FoveaWorkbenchNavigationUITests.swift"
    )
    iphone_source = (
        ROOT / "Examples/FoveaWorkbenchApp/FoveaWorkbenchUITests/FoveaWorkbenchUITests.swift"
    )
    ipad_source = (
        ROOT / "Examples/FoveaWorkbenchApp/FoveaWorkbenchUITests/FoveaWorkbenchIPadUITests.swift"
    )
    iphone_timeout = verifier.ui_suite_timeout_seconds(iphone_source)
    ipad_timeout = verifier.ui_suite_timeout_seconds(ipad_source)
    if iphone_timeout < 3_600:
        errors.append("iPhone UI suite timeout must reserve build and diagnostic long-tail budget")
    if ipad_timeout < 1_800:
        errors.append("iPad UI suite timeout must reserve build and diagnostic long-tail budget")
    if verifier.VISUAL_AUDIT_TIMEOUT_SECONDS < 3_600:
        errors.append("strict visual matrix must reserve at least one hour of aggregate budget")
    if not 900 <= verifier.VISUAL_FAMILY_TIMEOUT_SECONDS <= 1_500:
        errors.append("each visual device family must have a bounded 15-25 minute outer watchdog")
    if verifier.VISUAL_CAPTURE_ATTEMPTS != 2:
        errors.append("strict visual capture must retry infrastructure failure exactly once")

    visual_test_source = (
        ROOT / "Examples/FoveaWorkbenchApp/FoveaWorkbenchUITests/"
        "FoveaWorkbenchVisualTests.swift"
    ).read_text()
    lifecycle_orientation = re.search(
        r"override func (?:setUp|tearDown)WithError\(\) throws \{[^}]*"
        r"XCUIDevice\.shared\.orientation",
        visual_test_source,
        re.DOTALL,
    )
    if lifecycle_orientation is not None:
        errors.append(
            "XCUIDevice orientation must be mutated inside a @MainActor test method, "
            "not XCTest lifecycle overrides"
        )

    required_callables = (
        "ensure_simulator_booted", "capture_visual_family", "restart_simulator",
        "recover_core_simulator_service", "verify_visual_assurance",
        "pin_simulator_environment", "run_xcode_sharded_phase", "prepare_visual_family",
        "compact_ui_smoke_phase", "regular_ui_smoke_phase",
        "terminate_visual_family_xcodebuild",
    )
    for name in required_callables:
        if not callable(getattr(verifier, name, None)):
            errors.append(f"iOS verifier must expose {name}")
    for marker in (
        "Failed to get matching snapshots: Error getting main window kAXErrorServerNotFound",
        "Failed: Timed out while synthesizing event.",
        "Failed to determine hittability: Activation point invalid and no suggested hit points based on element frame",
        "visual xcodebuild made no log progress for 240 seconds",
        "visual xcodebuild exceeded total timeout of 720 seconds",
    ):
        if not verifier.is_simulator_infrastructure_failure(marker):
            errors.append(f"iOS verifier does not classify simulator infrastructure marker: {marker}")

    verifier_source = verifier_path.read_text()
    process_source = (ROOT / "scripts/ios_example_process.py").read_text()
    xcode_source = (ROOT / "scripts/ios_example_xcode.py").read_text()
    visual_source = (ROOT / "scripts/ios_example_visual.py").read_text()
    visual_audit_source = (ROOT / "scripts/audit-workbench-visuals.py").read_text()
    documentation_source = (ROOT / "scripts/verify-documentation.py").read_text()
    combined_source = "\n".join(
        (
            verifier_source,
            process_source,
            xcode_source,
            visual_source,
            visual_audit_source,
            documentation_source,
        )
    )
    source_requirements = {
        '"w" if attempt == 0 else "a"': "xcode phase retry must preserve prior-attempt logs",
        '=== attempt {attempt + 1}/{attempts} simulator={destination} ===': "xcode phase logs must identify retry attempts and simulator",
        'family_env.pop(opposite, None)': "visual capture must remove the opposite simulator override",
        'env = pin_simulator_environment(env, include_ipad=not args.skip_ui)': "iOS verification must pin only required simulator families once per session",
        'timed_out = completed.returncode == -1': "visual watchdog timeout must be classified as infrastructure",
        'retryable = timed_out or is_simulator_infrastructure_failure(output)': "visual retry must combine timeout and explicit infrastructure markers",
        'ROOT / result["log"]': "UI shard aggregation must resolve project-relative logs through ROOT",
        '=== infrastructure stall: no log progress for ': "UI shard watchdog must leave an explicit infrastructure-stall marker",
        'tempfile.TemporaryFile(mode="w+t")': "subprocess capture must use a file-backed sink",
        'os.killpg(identifier, 0)': "timed-out process cleanup must detect orphaned process groups",
        'prepare_visual_family(family, identifier, family_env)': "every visual attempt must prepare its device family",
        'VISUAL_XCODE_INACTIVITY_TIMEOUT_SECONDS = 240': "visual xcodebuild must fail on bounded log inactivity",
        '"-collect-test-diagnostics", "never"': "visual xcodebuild must disable unbounded automatic diagnostics",
        'run_visual_xcode(': "visual xcodebuild must stream progress to its retained family log",
        'result_info = result / "Info.plist"': "visual attachment export must require a complete result bundle",
        'GENERATED_METADATA.write_bytes(original_metadata)': "visual capture must restore ephemeral build metadata",
        'phases = run_requested_phases(args, env)': "Workbench report generation must occur after phase execution",
        'clean_derived_data=not args.reuse_release_derived_data': "developer Workbench smoke must explicitly control Release cache reuse",
        'if not args.skip_release_build:': "Workbench verifier must make Release audit an explicit phase decision",
        'GENERATED_METADATA.unlink(missing_ok=True)': "Workbench verification must restore an originally absent metadata file",
        'DOC_BUILD_TOTAL_TIMEOUT_SECONDS = 900': "documentation build must have a bounded total timeout",
        'DOC_BUILD_INACTIVITY_TIMEOUT_SECONDS = 180': "documentation build must have a bounded inactivity timeout",
        'run_documentation_build(': "documentation xcodebuild must stream progress to its retained log",
        'start_new_session=True': "long-running Xcode commands must own isolated process groups",
        'signal_process_groups(groups, signal.SIGKILL)': "visual orphan cleanup must have a bounded force-kill fallback",
        'restart_simulator(simulator(env, "ipad"), env)': "navigation proof must start from a restarted iPad",
        '"com.apple.CoreSimulator.CoreSimulatorService"': "CoreSimulator recovery must target the exact service",
        'CoreSimulatorService did not recover within 60 seconds': "CoreSimulator recovery must have an explicit bound",
    }
    for fragment, message in source_requirements.items():
        if fragment not in combined_source:
            errors.append(message)
    if "resolve_relative(" in combined_source:
        errors.append("iOS verifier must not call an undefined resolve_relative helper")
    if re.search(
        r"completed = subprocess\.run\(\s*command,.*?documentation build failed",
        documentation_source,
        re.DOTALL,
    ):
        errors.append("documentation xcodebuild must not use an unbounded subprocess.run")
    if combined_source.count("inactivity_timeout_seconds=UI_TEST_INACTIVITY_TIMEOUT_SECONDS") != 5:
        errors.append("host and UI test entry points must enable the bounded inactivity watchdog")
    if combined_source.count(f"-only-testing:{{REGULAR_WIDTH_NAVIGATION_TEST}}") != 1:
        errors.append("iPad UI phase must include the navigation test exactly once")
    if combined_source.count("recover_core_simulator_service(env)") != 4:
        errors.append(
            "simulator discovery, boot retry, restart fallback, and visual preparation must each invoke service recovery"
        )

    expected_navigation_test = (
        "FoveaWorkbenchUITests/FoveaWorkbenchUITests/"
        "testEcologicalAtlasOpensLibraryCasesMapGlossaryAndMethodology_DEMO_PT_024"
    )
    if verifier.REGULAR_WIDTH_NAVIGATION_TEST != expected_navigation_test:
        errors.append("regular-width navigation test routing changed unexpectedly")
    expected_compact_smoke = (
        "FoveaWorkbenchUITests/FoveaWorkbenchUITests/"
        "testSingleImageLabPublishesExpectedActualEvidence"
    )
    expected_ipad_smoke = (
        "FoveaWorkbenchUITests/FoveaWorkbenchIPadUITests/"
        "testIPadLaunchShowsResponsiveEcologicalAtlas_DEMO_PT_027"
    )
    if verifier.COMPACT_SMOKE_TEST != expected_compact_smoke:
        errors.append("compact Workbench smoke routing changed unexpectedly")
    if verifier.IPAD_SMOKE_TEST != expected_ipad_smoke:
        errors.append("regular-width Workbench smoke routing changed unexpectedly")
    compact_methods = verifier.compact_ui_methods()
    if len(compact_methods) != 19 or expected_navigation_test.rsplit("/", 1)[-1] in compact_methods:
        errors.append("iPhone behavior matrix must contain exactly 19 non-navigation tests")
    regular_methods, ecological_methods = verifier.compact_ui_method_groups()
    if len(regular_methods) != 14 or len(ecological_methods) != 5:
        errors.append("iPhone behavior matrix must retain 14 regular and 5 isolated ecological tests")
    if set(regular_methods).intersection(ecological_methods):
        errors.append("regular and ecological UI test partitions must be disjoint")
    if set(regular_methods) | set(ecological_methods) != set(compact_methods):
        errors.append("iPhone UI partitions must preserve every compact-width test")
    regular_shards = verifier.balanced_shards(regular_methods, 3)
    if [len(shard) for shard in regular_shards] != [5, 5, 4]:
        errors.append("regular iPhone behavior matrix must use balanced 5/5/4 shards")
    ecological_shards = verifier.balanced_shards(
        ecological_methods, len(ecological_methods)
    )
    if [len(shard) for shard in ecological_shards] != [1, 1, 1, 1, 1]:
        errors.append("every ecological matrix test must run in its own simulator shard")
    if [method for shard in regular_shards for method in shard] != regular_methods:
        errors.append("regular iPhone UI sharding must preserve method order")
    if [method for shard in ecological_shards for method in shard] != ecological_methods:
        errors.append("ecological UI sharding must preserve method order")
    ipad_methods = verifier.ui_test_methods(ipad_source)
    ipad_shards = verifier.balanced_shards(ipad_methods, 2)
    if len(ipad_methods) != 4 or [len(shard) for shard in ipad_shards] != [2, 2]:
        errors.append("native iPad behavior matrix must use two balanced two-test shards")
    if not 180 <= verifier.UI_TEST_INACTIVITY_TIMEOUT_SECONDS <= 300:
        errors.append("UI inactivity watchdog must stay within a 3-5 minute bound")
    if verifier.inactivity_expired(100.0, 339.9, 240):
        errors.append("UI inactivity watchdog fires before its deadline")
    if not verifier.inactivity_expired(100.0, 340.0, 240):
        errors.append("UI inactivity watchdog must fire at its deadline")
    try:
        verifier.inactivity_expired(0.0, 1.0, 0)
    except ValueError:
        pass
    else:
        errors.append("UI inactivity watchdog must reject a non-positive timeout")

    inherited_output = verifier.run(
        ["/bin/sh", "-c", "sleep 3 & echo inherited-output"],
        env=os.environ.copy(), timeout=1,
    )
    if inherited_output.returncode != 0 or inherited_output.stdout.strip() != "inherited-output":
        errors.append("file-backed subprocess capture must not wait for descendant pipe closure")

    class _UnreapableTimedOutProcess:
        pid = 424242
        returncode = None

        def __init__(self) -> None:
            self.wait_calls: list[int | float | None] = []

        def wait(self, timeout: int | float | None = None) -> int:
            self.wait_calls.append(timeout)
            if len(self.wait_calls) == 1:
                raise subprocess.TimeoutExpired("unreapable", timeout)
            raise AssertionError("timed-out process must not be waited on without a bound")

        def poll(self) -> int | None:
            return None

    unreapable = _UnreapableTimedOutProcess()
    original_process_popen = process_support.subprocess.Popen
    original_process_terminate = process_support.terminate_process_group
    terminated_processes: list[object] = []
    process_support.subprocess.Popen = lambda *_args, **_kwargs: unreapable
    process_support.terminate_process_group = lambda process: terminated_processes.append(process)
    try:
        timed_out_result = process_support.run(["unreapable"], env={}, timeout=1)
    finally:
        process_support.subprocess.Popen = original_process_popen
        process_support.terminate_process_group = original_process_terminate
    if (
        timed_out_result.returncode != -1
        or unreapable.wait_calls != [1]
        or terminated_processes != [unreapable]
    ):
        errors.append("timed-out subprocess capture must return without an unbounded second wait")

    visual_audit_path = ROOT / "scripts/audit-workbench-visuals.py"
    visual_audit_spec = importlib.util.spec_from_file_location(
        "fovea_workbench_visual_audit", visual_audit_path
    )
    if visual_audit_spec is None or visual_audit_spec.loader is None:
        raise RuntimeError("unable to load Workbench visual audit")
    visual_audit = importlib.util.module_from_spec(visual_audit_spec)
    visual_audit_spec.loader.exec_module(visual_audit)
    with tempfile.TemporaryDirectory(prefix="fovea-visual-watchdog-") as directory:
        root = Path(directory)
        normal_log = root / "normal.log"
        normal_output = visual_audit.run_visual_xcode(
            ["/bin/sh", "-c", "echo visual-start; sleep 0.1; echo visual-done"],
            output=normal_log,
        )
        if "visual-start" not in normal_output or "visual-done" not in normal_output:
            errors.append("visual watchdog must retain successful streamed command output")
        original_inactivity = visual_audit.VISUAL_XCODE_INACTIVITY_TIMEOUT_SECONDS
        original_total = visual_audit.VISUAL_XCODE_TOTAL_TIMEOUT_SECONDS
        visual_audit.VISUAL_XCODE_INACTIVITY_TIMEOUT_SECONDS = 1
        visual_audit.VISUAL_XCODE_TOTAL_TIMEOUT_SECONDS = 5
        stalled_log = root / "stalled.log"
        try:
            visual_audit.run_visual_xcode(
                ["/bin/sh", "-c", "echo visual-start; sleep 10"],
                output=stalled_log,
            )
        except RuntimeError as error:
            stalled_message = str(error)
        else:
            stalled_message = ""
        finally:
            visual_audit.VISUAL_XCODE_INACTIVITY_TIMEOUT_SECONDS = original_inactivity
            visual_audit.VISUAL_XCODE_TOTAL_TIMEOUT_SECONDS = original_total
        if (
            "no log progress for 1 seconds" not in stalled_message
            or "=== visual xcodebuild made no log progress for 1 seconds ==="
            not in stalled_log.read_text()
        ):
            errors.append("visual watchdog must terminate and retain a bounded inactivity marker")

        original_artifact_root = visual_audit.ARTIFACT_ROOT
        original_ensure_booted = visual_audit.ensure_booted
        original_visual_runner = visual_audit.run_visual_xcode
        original_run = visual_audit.run
        visual_audit.ARTIFACT_ROOT = root / "artifacts"
        visual_audit.ensure_booted = lambda _identifier: None
        export_commands: list[list[str]] = []

        def failed_visual_runner(_command: list[str], *, output: Path) -> str:
            (visual_audit.ARTIFACT_ROOT / "iphone.xcresult").mkdir(
                parents=True, exist_ok=True
            )
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text("partial result")
            raise RuntimeError("visual xcodebuild made no log progress for 1 seconds")

        visual_audit.run_visual_xcode = failed_visual_runner
        visual_audit.run = lambda command, **_kwargs: export_commands.append(list(command)) or ""
        try:
            incomplete_failures = visual_audit.capture_visual_family("iphone", "test-device")
        finally:
            visual_audit.ARTIFACT_ROOT = original_artifact_root
            visual_audit.ensure_booted = original_ensure_booted
            visual_audit.run_visual_xcode = original_visual_runner
            visual_audit.run = original_run
        if (
            len(incomplete_failures) != 1
            or "visual test failed" not in incomplete_failures[0]
            or export_commands
        ):
            errors.append(
                "failed visual xcodebuild must preserve its primary error and skip attachment export"
            )

        original_artifact_root = visual_audit.ARTIFACT_ROOT
        original_metadata_path = visual_audit.GENERATED_METADATA
        original_run = visual_audit.run
        original_capture = visual_audit.capture_visual_family
        metadata = root / "WorkbenchBuildMetadata.generated.swift"
        metadata.write_text("original metadata")
        visual_audit.ARTIFACT_ROOT = root / "matrix-artifacts"
        visual_audit.GENERATED_METADATA = metadata

        def mutate_metadata(_command: list[str], **_kwargs: object) -> str:
            metadata.write_text("generated metadata")
            return ""

        visual_audit.run = mutate_metadata
        visual_audit.capture_visual_family = lambda _family, _identifier: []
        try:
            visual_audit.capture_visual_matrix("iphone", None)
        finally:
            visual_audit.ARTIFACT_ROOT = original_artifact_root
            visual_audit.GENERATED_METADATA = original_metadata_path
            visual_audit.run = original_run
            visual_audit.capture_visual_family = original_capture
        if metadata.read_text() != "original metadata":
            errors.append("visual matrix must restore ephemeral build metadata")

    documentation_path = ROOT / "scripts/verify-documentation.py"
    documentation_spec = importlib.util.spec_from_file_location(
        "fovea_verify_documentation", documentation_path
    )
    if documentation_spec is None or documentation_spec.loader is None:
        raise RuntimeError("unable to load documentation verifier")
    documentation = importlib.util.module_from_spec(documentation_spec)
    documentation_spec.loader.exec_module(documentation)
    with tempfile.TemporaryDirectory(prefix="fovea-documentation-watchdog-") as directory:
        root = Path(directory)
        normal_log = root / "normal.log"
        normal_code, normal_failure = documentation.run_documentation_build(
            ["/bin/sh", "-c", "echo doc-start; sleep 0.1; echo doc-done"],
            env=os.environ.copy(),
            platform_name="test-normal",
            log=normal_log,
        )
        normal_text = normal_log.read_text()
        if (
            normal_code != 0
            or normal_failure is not None
            or "doc-start" not in normal_text
            or "doc-done" not in normal_text
        ):
            errors.append("documentation watchdog must retain successful streamed command output")
        original_inactivity = documentation.DOC_BUILD_INACTIVITY_TIMEOUT_SECONDS
        original_total = documentation.DOC_BUILD_TOTAL_TIMEOUT_SECONDS
        documentation.DOC_BUILD_INACTIVITY_TIMEOUT_SECONDS = 1
        documentation.DOC_BUILD_TOTAL_TIMEOUT_SECONDS = 5
        stalled_log = root / "stalled.log"
        try:
            stalled_code, stalled_failure = documentation.run_documentation_build(
                ["/bin/sh", "-c", "echo doc-start; sleep 10"],
                env=os.environ.copy(),
                platform_name="test-stalled",
                log=stalled_log,
            )
        finally:
            documentation.DOC_BUILD_INACTIVITY_TIMEOUT_SECONDS = original_inactivity
            documentation.DOC_BUILD_TOTAL_TIMEOUT_SECONDS = original_total
        if (
            stalled_code != -1
            or stalled_failure is None
            or "no log progress for 1 seconds" not in stalled_failure
            or "=== test-stalled documentation build made no log progress for 1 seconds ==="
            not in stalled_log.read_text()
        ):
            errors.append(
                "documentation watchdog must terminate and retain a bounded inactivity marker"
            )

    snapshot = verifier.generated_project_snapshot()
    if len(snapshot) != 3:
        errors.append("generated project reproducibility must cover PBX, scheme, and workspace")
    project_text = verifier.PBXPROJ.read_text()
    verifier.validate_generated_project_text(project_text)
    for token in verifier.REQUIRED_GENERATED_REFERENCES:
        try:
            verifier.validate_generated_project_text(project_text.replace(token, ""))
        except RuntimeError:
            pass
        else:
            errors.append(f"generated project validator accepts missing source reference: {token}")
    for token in verifier.FORBIDDEN_GENERATED_REFERENCES:
        try:
            verifier.validate_generated_project_text(project_text + f"\n{token}\n")
        except RuntimeError:
            pass
        else:
            errors.append(f"generated project validator accepts forbidden reference: {token}")

    original_run = xcode_support.run
    readiness_calls: list[list[str]] = []
    already_booted_payload = json.dumps(
        {"devices": {"runtime": [{"udid": "already-booted-device", "state": "Booted"}]}}
    )
    def already_booted_run(command: list[str], **_kwargs):
        readiness_calls.append(command)
        return subprocess.CompletedProcess(command, 0, already_booted_payload, None)
    xcode_support.run = already_booted_run
    try:
        verifier.ensure_simulator_booted("already-booted-device", {})
    finally:
        xcode_support.run = original_run
    if len(readiness_calls) != 1 or readiness_calls[0][2:4] != ["list", "devices"]:
        errors.append("already-booted simulator must short-circuit from the device-state list")

    cold_boot_calls: list[list[str]] = []
    shutdown_payload = json.dumps(
        {"devices": {"runtime": [{"udid": "shutdown-device", "state": "Shutdown"}]}}
    )
    booted_payload = json.dumps(
        {"devices": {"runtime": [{"udid": "shutdown-device", "state": "Booted"}]}}
    )
    cold_boot_results = iter([
        subprocess.CompletedProcess(["simctl", "list"], 0, shutdown_payload, None),
        subprocess.CompletedProcess(["simctl", "boot"], 0, "", None),
        subprocess.CompletedProcess(["simctl", "bootstatus"], 0, "Finished", None),
    ])
    def cold_boot_run(command: list[str], **_kwargs):
        cold_boot_calls.append(command)
        return next(cold_boot_results)
    xcode_support.run = cold_boot_run
    try:
        verifier.ensure_simulator_booted("shutdown-device", {})
    finally:
        xcode_support.run = original_run
    if [command[2] for command in cold_boot_calls] != ["list", "boot", "bootstatus"]:
        errors.append("shutdown simulator readiness must be decided by bounded bootstatus")
    if cold_boot_calls[-1][3:] != ["shutdown-device", "-b", "-d"]:
        errors.append("simulator bootstatus must block for the selected device with diagnostics")

    failed_boot_calls: list[list[str]] = []
    failed_boot_results = iter([
        subprocess.CompletedProcess(["simctl", "list"], 0, shutdown_payload, None),
        subprocess.CompletedProcess(["simctl", "boot"], 0, "", None),
        subprocess.CompletedProcess(["simctl", "bootstatus"], -1, "migration pending", None),
        subprocess.CompletedProcess(["simctl", "list"], 0, "{invalid", None),
    ])
    def failed_boot_run(command: list[str], **_kwargs):
        failed_boot_calls.append(command)
        return next(failed_boot_results)
    xcode_support.run = failed_boot_run
    try:
        try:
            verifier.ensure_simulator_booted("shutdown-device", {})
        except RuntimeError as error:
            failed_boot_message = str(error)
        else:
            failed_boot_message = ""
    finally:
        xcode_support.run = original_run
    if (
        "did not complete bounded bootstatus" not in failed_boot_message
        or "migration pending" not in failed_boot_message
        or "last_state=unknown" not in failed_boot_message
        or [command[2] for command in failed_boot_calls]
        != ["list", "boot", "bootstatus", "list"]
    ):
        errors.append("failed simulator bootstatus must preserve progress and state diagnostics")

    original_verifier_simulator = verifier.simulator
    pin_calls: list[tuple[str, dict[str, str]]] = []

    def pin_stub(env: dict[str, str], family: str) -> str:
        pin_calls.append((family, dict(env)))
        return f"pinned-{family}"

    verifier.simulator = pin_stub
    original_environment = {"DEVELOPER_DIR": "test"}
    try:
        pinned_environment = verifier.pin_simulator_environment(
            original_environment, include_ipad=True
        )
        full_pin_calls = list(pin_calls)
        pin_calls.clear()
        unit_environment = {
            "DEVELOPER_DIR": "test",
            "FOVEA_IPAD_SIMULATOR_ID": "stale-ipad",
        }
        unit_pinned_environment = verifier.pin_simulator_environment(
            unit_environment, include_ipad=False
        )
        unit_pin_calls = list(pin_calls)
    finally:
        verifier.simulator = original_verifier_simulator
    if (
        original_environment != {"DEVELOPER_DIR": "test"}
        or pinned_environment.get("FOVEA_IPHONE_SIMULATOR_ID") != "pinned-iphone"
        or pinned_environment.get("FOVEA_IPAD_SIMULATOR_ID") != "pinned-ipad"
        or [family for family, _env in full_pin_calls] != ["iphone", "ipad"]
        or full_pin_calls[0][1].get("FOVEA_IPHONE_SIMULATOR_ID") is not None
        or full_pin_calls[1][1].get("FOVEA_IPHONE_SIMULATOR_ID") != "pinned-iphone"
    ):
        errors.append("UI verification must resolve and pin each simulator family exactly once")
    if (
        unit_environment.get("FOVEA_IPAD_SIMULATOR_ID") != "stale-ipad"
        or unit_pinned_environment.get("FOVEA_IPHONE_SIMULATOR_ID") != "pinned-iphone"
        or "FOVEA_IPAD_SIMULATOR_ID" in unit_pinned_environment
        or [family for family, _env in unit_pin_calls] != ["iphone"]
    ):
        errors.append("unit-only Workbench verification must not resolve or retain an iPad")

    original_subprocess_run = xcode_support.subprocess.run
    original_recovery = xcode_support.recover_core_simulator_service
    selector_calls: list[list[str]] = []
    recovery_calls: list[dict[str, str]] = []
    selector_results = iter(
        [
            subprocess.CompletedProcess(["selector"], 1, "", "discovery timed out"),
            subprocess.CompletedProcess(["selector"], 0, "recovered-device\n", ""),
        ]
    )

    def selector_run(command: list[str], **_kwargs):
        selector_calls.append(command)
        return next(selector_results)

    xcode_support.subprocess.run = selector_run
    xcode_support.recover_core_simulator_service = lambda env: recovery_calls.append(env)
    try:
        recovered = xcode_support.simulator({"DEVELOPER_DIR": "test"}, "iphone")
    finally:
        xcode_support.subprocess.run = original_subprocess_run
        xcode_support.recover_core_simulator_service = original_recovery
    if recovered != "recovered-device" or len(selector_calls) != 2 or len(recovery_calls) != 1:
        errors.append("simulator discovery must recover once and retry the exact selector")

    override_selector_calls: list[list[str]] = []
    override_recovery_calls: list[dict[str, str]] = []
    xcode_support.subprocess.run = lambda command, **_kwargs: override_selector_calls.append(command)
    xcode_support.recover_core_simulator_service = lambda env: override_recovery_calls.append(env)
    try:
        override = xcode_support.simulator(
            {"FOVEA_IPAD_SIMULATOR_ID": "explicit-ipad"}, "ipad"
        )
    finally:
        xcode_support.subprocess.run = original_subprocess_run
        xcode_support.recover_core_simulator_service = original_recovery
    if override != "explicit-ipad" or override_selector_calls or override_recovery_calls:
        errors.append("explicit simulator override must bypass discovery and recovery")

    failed_results = iter(
        [
            subprocess.CompletedProcess(["selector"], 1, "", "first failure"),
            subprocess.CompletedProcess(["selector"], 1, "", "second failure"),
        ]
    )
    failed_recoveries: list[dict[str, str]] = []
    xcode_support.subprocess.run = lambda _command, **_kwargs: next(failed_results)
    xcode_support.recover_core_simulator_service = lambda env: failed_recoveries.append(env)
    try:
        try:
            xcode_support.simulator({"DEVELOPER_DIR": "test"}, "iphone")
        except RuntimeError as error:
            failure_message = str(error)
        else:
            failure_message = ""
    finally:
        xcode_support.subprocess.run = original_subprocess_run
        xcode_support.recover_core_simulator_service = original_recovery
    if (
        len(failed_recoveries) != 1
        or "before and after CoreSimulatorService recovery" not in failure_message
        or "first failure" not in failure_message
        or "second failure" not in failure_message
    ):
        errors.append("simulator discovery must preserve both failures after bounded recovery")

    original_simulator = xcode_support.simulator
    original_ensure_booted = xcode_support.ensure_simulator_booted
    original_execute_attempt = xcode_support.execute_xcode_attempt
    original_successful_result = xcode_support.successful_phase_result
    original_recovery = xcode_support.recover_core_simulator_service
    boot_attempts = [0]
    boot_recoveries: list[dict[str, str]] = []
    executed_attempts: list[int] = []

    def boot_retry_ensure(_identifier: str, _env: dict[str, str]) -> None:
        boot_attempts[0] += 1
        if boot_attempts[0] == 1:
            raise RuntimeError("initial boot failure")

    def boot_retry_execute(
        _name: str,
        _actions: list[str],
        destination: str,
        _env: dict[str, str],
        attempt_index: int,
        _attempts: int,
        _timeout_seconds: int,
        _inactivity_timeout_seconds: int | None,
    ):
        executed_attempts.append(attempt_index)
        return xcode_support.PhaseAttempt(
            command=["xcodebuild"],
            destination=destination,
            log=ROOT / ".artifacts/ios-example/tooling-boot-retry.log",
            return_code=0,
            output="passed",
            timed_out=False,
            stalled=False,
        )

    xcode_support.simulator = lambda _env, _family: "boot-retry-device"
    xcode_support.ensure_simulator_booted = boot_retry_ensure
    xcode_support.recover_core_simulator_service = lambda env: boot_recoveries.append(env)
    xcode_support.execute_xcode_attempt = boot_retry_execute
    xcode_support.successful_phase_result = lambda *_args, **_kwargs: {"name": "boot-retry"}
    try:
        boot_retry_result = xcode_support.run_xcode_phase(
            "tooling-boot-retry",
            ["test"],
            env={"DEVELOPER_DIR": "test"},
        )
    finally:
        xcode_support.simulator = original_simulator
        xcode_support.ensure_simulator_booted = original_ensure_booted
        xcode_support.execute_xcode_attempt = original_execute_attempt
        xcode_support.successful_phase_result = original_successful_result
        xcode_support.recover_core_simulator_service = original_recovery
    if (
        boot_retry_result != {"name": "boot-retry"}
        or boot_attempts[0] != 2
        or len(boot_recoveries) != 1
        or executed_attempts != [1]
    ):
        errors.append("xcode phase must recover once before retrying a failed simulator boot")

    boot_failures = iter(
        [RuntimeError("first boot failure"), RuntimeError("second boot failure")]
    )
    failed_boot_recoveries: list[dict[str, str]] = []
    xcode_support.simulator = lambda _env, _family: "failed-boot-device"
    xcode_support.ensure_simulator_booted = lambda _identifier, _env: (_ for _ in ()).throw(next(boot_failures))
    xcode_support.recover_core_simulator_service = lambda env: failed_boot_recoveries.append(env)
    try:
        try:
            xcode_support.run_xcode_phase(
                "tooling-boot-failure",
                ["test"],
                env={"DEVELOPER_DIR": "test"},
            )
        except RuntimeError as error:
            boot_failure_message = str(error)
        else:
            boot_failure_message = ""
    finally:
        xcode_support.simulator = original_simulator
        xcode_support.ensure_simulator_booted = original_ensure_booted
        xcode_support.recover_core_simulator_service = original_recovery
    if (
        len(failed_boot_recoveries) != 1
        or "before and after CoreSimulatorService recovery" not in boot_failure_message
        or "first boot failure" not in boot_failure_message
        or "second boot failure" not in boot_failure_message
    ):
        errors.append("xcode phase must preserve both simulator boot failures after recovery")

    class _ExitedLeaderProcess:
        pid = 73

        def poll(self) -> int:
            return 0

        def wait(self, timeout: int | float | None = None) -> int:
            return 0

    original_process_killpg = process_support.os.killpg
    original_group_exists = process_support.process_group_exists
    original_monotonic = process_support.time.monotonic
    original_sleep = process_support.time.sleep
    group_signals: list[signal.Signals] = []
    monotonic_values = iter([0.0, 6.0])
    process_support.os.killpg = lambda _pid, signum: group_signals.append(signum)
    process_support.process_group_exists = lambda _identifier: True
    process_support.time.monotonic = lambda: next(monotonic_values)
    process_support.time.sleep = lambda _seconds: None
    try:
        process_support.terminate_process_group(_ExitedLeaderProcess())
    finally:
        process_support.os.killpg = original_process_killpg
        process_support.process_group_exists = original_group_exists
        process_support.time.monotonic = original_monotonic
        process_support.time.sleep = original_sleep
    if group_signals != [signal.SIGTERM, signal.SIGKILL]:
        errors.append(
            "process cleanup must terminate an orphaned group even after its leader has exited"
        )

    original_visual_run = visual_support.run
    visual_support.run = lambda *_args, **_kwargs: subprocess.CompletedProcess(
        [], 0,
        "123 900 xcodebuild " + visual_support.VISUAL_TEST_SELECTOR + " "
        + str(visual_support.ARTIFACTS / "visual-audit/iphone.xcresult"),
        None,
    )
    try:
        if visual_support.visual_process_groups("iphone", {}) != {900}:
            errors.append("visual cleanup must select only the exact family result-bundle process group")
    finally:
        visual_support.run = original_visual_run
except (OSError, RuntimeError, UnicodeError) as error:
    errors.append(f"invalid iOS example timeout policy: {error}")

try:
    selector_path = ROOT / "scripts/select-ios-simulator.py"
    selector_spec = importlib.util.spec_from_file_location(
        "fovea_select_ios_simulator", selector_path
    )
    if selector_spec is None or selector_spec.loader is None:
        raise RuntimeError("unable to load iOS simulator selector")
    selector = importlib.util.module_from_spec(selector_spec)
    selector_spec.loader.exec_module(selector)

    class _PermissionFallbackProcess:
        pid = 42
        stdout = None
        stderr = None

        def __init__(self) -> None:
            self.wait_count = 0
            self.terminated = False
            self.killed = False

        def terminate(self) -> None:
            self.terminated = True

        def kill(self) -> None:
            self.killed = True

        def wait(self, timeout: int | None = None) -> int:
            self.wait_count += 1
            if self.wait_count == 1:
                raise subprocess.TimeoutExpired("selector-cleanup", timeout)
            return 0

    fake = _PermissionFallbackProcess()
    original_killpg = selector.os.killpg
    selector.os.killpg = lambda _pid, _signal: (_ for _ in ()).throw(PermissionError())
    try:
        selector.terminate_process_group(fake)
    finally:
        selector.os.killpg = original_killpg
    if not fake.terminated or not fake.killed or fake.wait_count != 2:
        errors.append("simulator selector does not fall back after process-group permission errors")
except (OSError, RuntimeError, UnicodeError) as error:
    errors.append(f"invalid iOS simulator cleanup policy: {error}")

try:
    profile_path = ROOT / "scripts/run-verification-profile.py"
    profile_spec = importlib.util.spec_from_file_location(
        "fovea_verification_profiles", profile_path
    )
    if profile_spec is None or profile_spec.loader is None:
        raise RuntimeError("unable to load verification profile orchestrator")
    profile_module = importlib.util.module_from_spec(profile_spec)
    sys.modules[profile_spec.name] = profile_module
    profile_spec.loader.exec_module(profile_module)

    test_impact = profile_module.classify(
        ["Tests/FoveaTests/StagingAndStorageTests.swift"]
    )
    effective, test_phases, reasons = profile_module.phase_plan("smart", test_impact)
    test_phase_names = {phase.name for phase in test_phases}
    if (
        effective != "smart"
        or reasons
        or test_impact["testFilters"] != ["StagingAndStorageTests"]
        or "impacted-tests" not in test_phase_names
        or "root-tests" in test_phase_names
        or "qualification-certificate" in test_phase_names
    ):
        errors.append("smart test-only verification must run an exact impacted test filter")

    unknown_impact = profile_module.classify(["unclassified.verification-input"])
    unknown_effective, unknown_phases, unknown_reasons = profile_module.phase_plan(
        "smart", unknown_impact
    )
    if (
        unknown_effective != "premerge"
        or not unknown_reasons
        or "root-tests" not in {phase.name for phase in unknown_phases}
    ):
        errors.append("unknown verification inputs must fail closed by escalating to premerge")

    deleted_impact = profile_module.classify(
        ["Tests/FoveaTests/RemovedVerificationContractTests.swift"]
    )
    deleted_effective, deleted_phases, deleted_reasons = profile_module.phase_plan(
        "smart", deleted_impact
    )
    if (
        deleted_effective != "premerge"
        or "deleted" not in deleted_impact["categories"]
        or not any("deleted path" in reason for reason in deleted_reasons)
        or "root-tests" not in {phase.name for phase in deleted_phases}
    ):
        errors.append("deleted paths must fail closed by escalating smart verification to premerge")

    workbench_impact = profile_module.classify(
        ["Examples/FoveaWorkbenchApp/FoveaWorkbench/Views/WorkbenchRootView.swift"]
    )
    workbench_effective, workbench_phases, _ = profile_module.phase_plan(
        "smart", workbench_impact
    )
    workbench_names = {phase.name for phase in workbench_phases}
    if workbench_effective != "smart" or "workbench-unit" not in workbench_names:
        errors.append("Workbench application changes must select bounded host tests")

    verifier_impact = profile_module.classify(["scripts/verify-ios-example.py"])
    verifier_effective, verifier_phases, _ = profile_module.phase_plan(
        "smart", verifier_impact
    )
    verifier_names = {phase.name for phase in verifier_phases}
    if (
        verifier_effective != "smart"
        or "workbench-unit" in verifier_names
        or "workbench-smoke" in verifier_names
        or "workbench-tooling" not in verifier_impact["categories"]
    ):
        errors.append("Workbench verifier changes must rely on tooling contracts in smart mode")

    verify_profile_source = profile_path.read_text()
    verify_entry_source = (ROOT / "scripts/verify.sh").read_text()
    certificate_writer_source = (
        ROOT / "scripts/write-qualification-certificate.py"
    ).read_text()
    receipt_writer_source = (
        ROOT / "scripts/write-qualification-receipt.py"
    ).read_text()
    workflow_source = (ROOT / ".github/workflows/verify.yml").read_text()
    profile_contracts = {
        'PROFILE_CHOICES = ("smart", "premerge", "release", "workbench-smoke")':
            "verification profiles must expose bounded local gates",
        'effective = "premerge"':
            "unknown smart changes must escalate rather than skip",
        '"--no-renames"':
            "verification impact analysis must decompose renames into deletion and addition",
        '"--diff-filter=ACMRDT"':
            "verification impact analysis must include deleted and type-changed paths",
        'categories.add("deleted")':
            "deleted paths must be represented explicitly in verification impact",
        'reasons.append("deleted path escalated to premerge")':
            "deleted paths must conservatively escalate smart verification",
        '"qualification-certificate"':
            "release verification must require source-bound qualification evidence",
        '"--reuse-release-derived-data"':
            "bounded Workbench smoke must reuse local Release DerivedData",
        '"--skip-release-build"':
            "smart Workbench smoke must not repeat the Release binary audit",
        'terminate_process_group(process.pid)':
            "profile timeout cleanup must kill the complete process group",
        'terminate_active_process_groups()':
            "profile signal handling must clean every active child process group",
        'install_signal_handlers()':
            "verification profile entrypoint must install bounded cancellation handlers",
        'FOVEA_VERIFY_PROFILE=${FOVEA_VERIFY_PROFILE:-smart}':
            "verify.sh must default to the smart profile",
        'python3 scripts/write-qualification-certificate.py':
            "qualification must publish a source-bound certificate",
        'export FOVEA_QUALIFICATION_ACTIVE=1':
            "qualification must activate certificate publication explicitly",
        'qualification certificate writer may only run from the qualification profile':
            "certificate writer must reject standalone invocation",
        'assuranceReceiptSha256':
            "qualification certificates must bind per-stage receipt digests",
        'qualification receipt does not belong to this run/tree':
            "qualification certificate publication must reject stale stage receipts",
        'qualification receipt writer requires an active qualification run':
            "qualification stage receipts must reject inactive invocation",
        'FOVEA_VERIFY_PROFILE: "qualification"':
            "hosted qualification workflow must request the maximal profile explicitly",
    }
    combined_profile_source = (
        verify_profile_source
        + verify_entry_source
        + certificate_writer_source
        + receipt_writer_source
        + workflow_source
    )
    for fragment, message in profile_contracts.items():
        if fragment not in combined_profile_source:
            errors.append(message)
    if verify_entry_source.count("record_qualification_assurance ") != 9:
        errors.append("qualification must record exactly nine required assurance receipts")

    synthetic_run_id = "20000101T000000Z-999999"
    synthetic_session = (
        ROOT / ".artifacts/verification/qualification-runs" / synthetic_run_id
    )
    shutil.rmtree(synthetic_session, ignore_errors=True)
    synthetic_session.mkdir(parents=True)
    certificate_env = os.environ.copy()
    certificate_env.update(
        {
            "FOVEA_QUALIFICATION_ACTIVE": "1",
            "FOVEA_QUALIFICATION_RUN_ID": synthetic_run_id,
            "FOVEA_QUALIFICATION_STARTED_EPOCH": "946684800",
            "FOVEA_QUALIFICATION_SESSION_DIR": str(synthetic_session),
        }
    )
    synthetic_receipt = subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts/write-qualification-receipt.py"),
            "release-build",
        ],
        cwd=ROOT,
        env=certificate_env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    receipt_path = synthetic_session / "release-build.json"
    if synthetic_receipt.returncode != 0 or not receipt_path.is_file():
        errors.append("qualification receipt writer must emit an active-run receipt")
    else:
        receipt_payload = json.loads(receipt_path.read_text())
        if (
            receipt_payload.get("qualificationRunID") != synthetic_run_id
            or receipt_payload.get("assurance") != "release-build"
            or receipt_payload.get("status") != "passed"
        ):
            errors.append("qualification receipt writer emitted invalid run binding")

    missing_receipts = subprocess.run(
        [sys.executable, str(ROOT / "scripts/write-qualification-certificate.py")],
        cwd=ROOT,
        env=certificate_env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    shutil.rmtree(synthetic_session, ignore_errors=True)
    if missing_receipts.returncode == 0 or "qualification receipt is missing" not in missing_receipts.stdout:
        errors.append("qualification certificate writer must reject incomplete active runs")
except (OSError, RuntimeError, ValueError) as error:
    errors.append(f"invalid verification profile policy: {error}")

json_roots = [ROOT / "docs", ROOT / "evidence", ROOT / "Examples", ROOT / "Benchmarks"]
for json_root in json_roots:
    if not json_root.exists():
        continue
    for path in sorted(json_root.rglob("*.json")):
        relative_parts = path.relative_to(ROOT).parts
        if any(part in {".build", ".swiftpm", ".artifacts", "DerivedData"} for part in relative_parts):
            continue
        try:
            json.loads(path.read_text())
        except (json.JSONDecodeError, UnicodeError) as error:
            errors.append(f"JSON syntax error in {path.relative_to(ROOT)}: {error}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)

print("Tooling syntax check passed.")
