#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

from comparative_simulator_support import XCODEBUILD_RESOLVED_PACKAGE_FLAGS

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_ROOT = ROOT / ".artifacts/comparators"
CORE_PACKAGE = "Benchmarks/ComparativeLab"


@dataclass(frozen=True)
class AdapterSpec:
    name: str
    package_path: str
    scheme: str
    source_marker: str
    strict_upstream: bool


ADAPTERS = [
    AdapterSpec(
        "Apple URLSession + URLCache + ImageIO",
        "Benchmarks/ComparativeLab/Adapters/AppleNativeAdapterPackage",
        "FoveaAppleNativeComparator",
        "Benchmarks/ComparativeLab/Adapters/AppleNativeAdapterPackage/Sources",
        True,
    ),
    AdapterSpec(
        "Fovea",
        "Benchmarks/ComparativeLab/Adapters/FoveaAdapterPackage",
        "FoveaComparatorAdapterPackage",
        "Benchmarks/ComparativeLab/Adapters/FoveaAdapterPackage/Sources",
        True,
    ),
    AdapterSpec(
        "Nuke",
        "Benchmarks/ComparativeLab/Adapters/NukeAdapterPackage",
        "FoveaNukeComparator",
        "Benchmarks/ComparativeLab/Adapters/NukeAdapterPackage/Sources",
        True,
    ),
    AdapterSpec(
        "Kingfisher",
        "Benchmarks/ComparativeLab/Adapters/KingfisherAdapterPackage",
        "FoveaKingfisherComparator",
        "Benchmarks/ComparativeLab/Adapters/KingfisherAdapterPackage/Sources",
        False,
    ),
    AdapterSpec(
        "SDWebImage",
        "Benchmarks/ComparativeLab/Adapters/SDWebImageAdapterPackage",
        "FoveaSDWebImageComparator",
        "Benchmarks/ComparativeLab/Adapters/SDWebImageAdapterPackage/Sources",
        False,
    ),
    AdapterSpec(
        "AlamofireImage",
        "Benchmarks/ComparativeLab/Adapters/AlamofireImageAdapterPackage",
        "FoveaAlamofireImageComparator",
        "Benchmarks/ComparativeLab/Adapters/AlamofireImageAdapterPackage/Sources",
        False,
    ),
    AdapterSpec(
        "PINRemoteImage",
        "Benchmarks/ComparativeLab/Adapters/PINRemoteImageAdapterPackage",
        "FoveaPINRemoteImageComparator",
        "Benchmarks/ComparativeLab/Adapters/PINRemoteImageAdapterPackage/Sources",
        False,
    ),
]


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def selected_xcode_environment() -> dict[str, str]:
    environment = os.environ.copy()
    if not environment.get("DEVELOPER_DIR"):
        selector = subprocess.run(
            [str(ROOT / "scripts/select-xcode.sh")],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        environment["DEVELOPER_DIR"] = selector.stdout.strip()
    return environment


def invoke(
    command: list[str],
    *,
    capture: bool = False,
    timeout: int | None = None,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            cwd=ROOT,
            check=False,
            capture_output=capture,
            text=True,
            env=selected_xcode_environment(),
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        fail(f"command timed out: {' '.join(command[:6])}: {error}")


def require_success(result: subprocess.CompletedProcess[str], label: str) -> None:
    if result.returncode == 0:
        return
    if result.stdout:
        print(result.stdout[-20000:], file=sys.stderr)
    if result.stderr:
        print(result.stderr[-20000:], file=sys.stderr)
    fail(f"{label} failed with exit code {result.returncode}")


def warning_lines(combined: str) -> list[str]:
    return [line for line in combined.splitlines() if "warning:" in line]


def local_warning_lines(combined: str, source_marker: str) -> list[str]:
    absolute = str(ROOT / source_marker)
    return [line for line in warning_lines(combined) if source_marker in line or absolute in line]


def verify_adapter_sources() -> list[dict[str, str]]:
    lock = json.loads((ROOT / "docs/research/comparator-lock.json").read_text())
    records: list[dict[str, str]] = []
    required = [item for item in lock["comparators"] if item["phase0bRole"] == "required"]
    expected = ["Nuke", "Kingfisher", "SDWebImage", "PINRemoteImage", "AlamofireImage"]
    if [item["name"] for item in required] != expected:
        fail("comparator lock must contain four A-tier Git adapters and AlamofireImage as B-tier retained")
    tiers = {item["name"]: item.get("researchTier") for item in required}
    if tiers != {
        "Nuke": "A", "Kingfisher": "A", "SDWebImage": "A",
        "PINRemoteImage": "A", "AlamofireImage": "B",
    }:
        fail("comparator research tiers differ from the accepted A/B matrix")
    for item in required:
        path = ROOT / ".artifacts/comparators/sources" / item["name"]
        if not path.is_dir():
            fail(f"missing {item['name']} checkout; run scripts/prepare-comparator-sources.py")
        head = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        if head != item["exactCommit"]:
            fail(f"{item['name']} checkout does not match comparator lock")
        dirty = subprocess.run(
            ["git", "-C", str(path), "status", "--porcelain"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        if dirty:
            fail(f"{item['name']} comparator checkout is dirty")
        records.append({"name": item["name"], "tag": item["tag"], "exactCommit": head})
    return records


def verify_fovea_visible_latency_contract() -> None:
    source_path = ROOT / (
        "Benchmarks/ComparativeLab/Adapters/FoveaAdapterPackage/Sources/"
        "FoveaComparatorAdapter/FoveaComparatorAdapter.swift"
    )
    source = source_path.read_text()
    required = {
        "progressive event consumption": "system.pipeline.events(for: imageRequest)",
        "full-quality preview gate": "quality == UInt16.max",
        "preview timestamp": "firstFullQualityLatency",
        "terminal drain": "case .final(let finalImage)",
    }
    missing = [label for label, marker in required.items() if marker not in source]
    if missing:
        fail(
            "Fovea comparator must measure the first full-quality preview while draining "
            f"the stream to final; missing: {', '.join(missing)}"
        )
    if "system.pipeline.image(for: imageRequest)" in source:
        fail(
            "Fovea comparator must not charge durable final publication to visible latency"
        )


def verify_runtime_configuration_attestation_contract() -> None:
    core = (ROOT / "Benchmarks/ComparativeLab/Sources/ComparativeLabCore/ComparativeLabCore.swift").read_text()
    models = (ROOT / "Benchmarks/ComparativeLab/Apps/Shared/BenchmarkModels.swift").read_text()
    runtime = (ROOT / "Benchmarks/ComparativeLab/Apps/Shared/BenchmarkRuntime.swift").read_text()
    if "public struct ComparatorRuntimeConfiguration" not in core:
        fail("ComparativeLab core must define the comparator runtime configuration attestation")
    if "let comparatorRuntimeConfiguration: ComparatorRuntimeConfiguration?" not in models:
        fail("BenchmarkRunEnvelope must carry comparator runtime configuration attestation")
    if "self.schemaVersion = 5" not in models:
        fail("BenchmarkRunEnvelope schema must be v5 after runtime configuration attestation")
    if "comparatorRuntimeConfiguration: adapter.runtimeConfiguration" not in runtime:
        fail("benchmark runtime must write the adapter runtime configuration into every run envelope")
    if "arguments.workload == .w7ThousandConcurrent ? 8 : 6" not in runtime:
        fail("shared session connection concurrency must be explicitly frozen by workload")

    adapters = [
        "AppleNativeAdapterPackage/Sources/AppleNativeComparatorAdapter/AppleNativeComparatorAdapter.swift",
        "FoveaAdapterPackage/Sources/FoveaComparatorAdapter/FoveaComparatorAdapter.swift",
        "NukeAdapterPackage/Sources/NukeComparatorAdapter/NukeComparatorAdapter.swift",
        "KingfisherAdapterPackage/Sources/KingfisherComparatorAdapter/KingfisherComparatorAdapter.swift",
        "SDWebImageAdapterPackage/Sources/SDWebImageComparatorAdapter/SDWebImageComparatorAdapter.swift",
        "PINRemoteImageAdapterPackage/Sources/PINRemoteImageComparatorAdapter/PINRemoteImageComparatorAdapter.swift",
    ]
    missing = []
    for relative in adapters:
        source = (ROOT / "Benchmarks/ComparativeLab/Adapters" / relative).read_text()
        if "runtimeConfiguration" not in source or "ComparatorRuntimeConfiguration(" not in source:
            missing.append(relative)
    if missing:
        fail("headless comparator runtime attestation is missing from: " + ", ".join(missing))

    for relative in (
        "scripts/run-comparative-simulator-lab.py",
        "scripts/run-comparative-device-lab.py",
        "scripts/run-w7-concurrency-lab.py",
    ):
        source = (ROOT / relative).read_text()
        if 'data.get("schemaVersion") != 5' not in source:
            fail(f"{relative} must require BenchmarkRunEnvelope schema v5")
        if 'data.get("comparatorRuntimeConfiguration")' not in source:
            fail(f"{relative} must reject missing comparator runtime configuration attestation")


def verify_sdwebimage_fixed_cache_and_downloader_contract() -> None:
    adapter_path = ROOT / (
        "Benchmarks/ComparativeLab/Adapters/SDWebImageAdapterPackage/Sources/"
        "SDWebImageComparatorAdapter/SDWebImageComparatorAdapter.swift"
    )
    adapter = adapter_path.read_text()
    required = {
        "evaluator-owned cache root": "diskCacheDirectory: cacheDirectory.path",
        "runtime disk-root containment": "cache.diskCachePath",
        "fixed memory budget": "cacheConfig.maxMemoryCost = UInt(boundedMemoryCost)",
        "fixed disk budget": "cacheConfig.maxDiskSize = 256 * 1_024 * 1_024",
        "runtime expiration attestation": '"cache.diskExpirationSeconds"',
        "runtime expire-type attestation": '"cache.diskExpireTypeRaw"',
        "runtime atomic-write attestation": '"cache.diskWritingOptionsRaw"',
        "runtime downloader timeout": '"downloader.timeoutSeconds"',
        "runtime downloader order": '"downloader.executionOrderRaw"',
        "URLCache disabled": "session.urlCache = nil",
    }
    missing = [label for label, marker in required.items() if marker not in adapter]
    if missing:
        fail("SDWebImage cache/downloader contract drifted; missing: " + ", ".join(missing))


def verify_kingfisher_fixed_cache_budget() -> None:
    adapter_path = ROOT / (
        "Benchmarks/ComparativeLab/Adapters/KingfisherAdapterPackage/Sources/"
        "KingfisherComparatorAdapter/KingfisherComparatorAdapter.swift"
    )
    adapter = adapter_path.read_text()
    required = {
        "evaluator-owned cache root": "cacheDirectoryURL: cacheDirectory",
        "fixed memory budget": "memoryCostLimit: Int = 128 * 1_024 * 1_024",
        "fixed disk budget": "diskSizeLimit: UInt = 256 * 1_024 * 1_024",
        "memory cost assignment": "cache.memoryStorage.config.totalCostLimit = boundedMemoryCost",
        "memory expiration": "cache.memoryStorage.config.expiration = .seconds(300)",
        "memory cleanup interval": "cache.memoryStorage.config.cleanInterval = 120",
        "disk size assignment": "cache.diskStorage.config.sizeLimit = boundedDiskSize",
        "disk expiration": "cache.diskStorage.config.expiration = .days(7)",
        "runtime root attestation": '"cache.rootPolicy": "evaluator-owned"',
        "runtime memory budget": '"cache.memoryTotalCostLimitBytes"',
        "runtime disk budget": '"cache.diskSizeLimitBytes"',
    }
    missing = [label for label, marker in required.items() if marker not in adapter]
    if missing:
        fail("Kingfisher fixed cache budget contract drifted; missing: " + ", ".join(missing))
    forbidden = {
        "device-derived default memory budget": "ProcessInfo.processInfo.physicalMemory",
        "unbounded disk size assignment": "config.sizeLimit = 0",
        "unfrozen cache limits marker": '"cache.limits": "pinned-library-defaults"',
    }
    present = [label for label, marker in forbidden.items() if marker in adapter]
    if present:
        fail("Kingfisher comparator reintroduced unstable cache defaults: " + ", ".join(present))


def verify_pinremoteimage_cache_isolation_and_dependency_pins() -> None:
    package_root = ROOT / "Benchmarks/ComparativeLab/Adapters/PINRemoteImageAdapterPackage"
    resolved_path = package_root / "Package.resolved"
    if not resolved_path.is_file():
        fail("PINRemoteImage comparator must commit Package.resolved for PINCache/PINOperation")
    resolved = json.loads(resolved_path.read_text())
    pins = {
        item.get("identity"): item.get("state", {})
        for item in resolved.get("pins", [])
        if isinstance(item, dict)
    }
    expected = {
        "pincache": (
            "3.0.4",
            "2fb85948463292c2e824148cf17dc62a4c217a94",
        ),
        "pinoperation": (
            "1.2.3",
            "a74f978733bdaf982758bfa23d70a189f4b4c1b6",
        ),
    }
    for identity, (version, revision) in expected.items():
        state = pins.get(identity)
        if not isinstance(state, dict) or state.get("version") != version or state.get(
            "revision"
        ) != revision:
            fail(f"PINRemoteImage comparator dependency pin drifted for {identity}")

    package_source = (package_root / "Package.swift").read_text()
    if 'exact: "3.0.4"' not in package_source or 'product(name: "PINCache"' not in package_source:
        fail("PINRemoteImage comparator must depend directly on exact PINCache 3.0.4")

    adapter = (
        package_root
        / "Sources/PINRemoteImageComparatorAdapter/PINRemoteImageComparatorAdapter.swift"
    ).read_text()
    forbidden = "PINRemoteImageManager.defaultImageTtlCache()"
    if forbidden in adapter:
        fail("PINRemoteImage comparator must not use the process-global default cache root")
    required = {
        "direct PINCache import": "import PINCache",
        "evaluator-owned root": "makeIsolatedPINRemoteImageCache(root: cacheDirectory)",
        "root containment check": "diskPath.hasPrefix(rootPath + \"/\")",
        "TTL cache": "ttlCache: true",
        "resume-aware serializer": "pinResumeCacheKeyPrefix = \"R-\"",
        "dependency attestation": '"dependency.PINCache"',
    }
    missing = [label for label, marker in required.items() if marker not in adapter]
    if missing:
        fail("PINRemoteImage cache isolation contract drifted; missing: " + ", ".join(missing))


def verify_apple_native_urlcache_contract() -> None:
    factory_path = ROOT / (
        "Benchmarks/ComparativeLab/Apps/AppleNative/BenchmarkAdapterFactory.swift"
    )
    adapter_path = ROOT / (
        "Benchmarks/ComparativeLab/Adapters/AppleNativeAdapterPackage/Sources/"
        "AppleNativeComparatorAdapter/AppleNativeComparatorAdapter.swift"
    )
    test_path = ROOT / (
        "Benchmarks/ComparativeLab/Adapters/AppleNativeAdapterPackage/Tests/"
        "AppleNativeComparatorAdapterTests/AppleNativeComparatorAdapterTests.swift"
    )
    runtime_path = ROOT / "Benchmarks/ComparativeLab/Apps/Shared/BenchmarkRuntime.swift"
    origin_path = ROOT / (
        "Benchmarks/ComparativeLab/Apps/Shared/LoopbackBenchmarkOriginServer.swift"
    )
    factory = factory_path.read_text()
    adapter = adapter_path.read_text()
    test = test_path.read_text()
    runtime = runtime_path.read_text()
    origin = origin_path.read_text()
    expected_name = "Apple URLSession + URLCache + ImageIO"
    if f'static let comparatorName = "{expected_name}"' not in factory:
        fail("Apple native comparator identity must explicitly name URLCache")
    required_adapter = {
        "dedicated URLCache": "let urlCache = URLCache(",
        "disk-only HTTP cache tier": "memoryCapacity: 0",
        "session cache injection": "configuration.urlCache = urlCache",
        "protocol cache policy": ".useProtocolCachePolicy",
        "task metrics collection": "didFinishCollecting metrics: URLSessionTaskMetrics",
        "resource fetch classification": "resourceFetchType",
        "local cache mapping": "case .localCache:",
        "cache purge": "urlCache.removeAllCachedResponses()",
        "ImageIO target decode": "CGImageSourceCreateThumbnailAtIndex(",
    }
    missing = [
        label for label, marker in required_adapter.items() if marker not in adapter
    ]
    if missing:
        fail(
            "Apple URLSession + URLCache + ImageIO comparator contract drifted; missing: "
            + ", ".join(missing)
        )
    forbidden = {
        "manual cache lookup": "cachedResponse(for:",
        "manual cache publication": "storeCachedResponse(",
        "cache bypass policy": ".reloadIgnoringLocalCacheData",
    }
    present = [label for label, marker in forbidden.items() if marker in adapter]
    if present:
        fail(
            "Apple native comparator must use URL Loading System protocol caching; forbidden: "
            + ", ".join(present)
        )
    if "testProtocolCachePolicyUsesURLCacheWithoutSecondOriginRequest" not in test:
        fail("Apple native URLCache behavior test is missing")
    if "XCTAssertEqual(origin.requestCount, 1)" not in test:
        fail("Apple native URLCache test must prove the second load avoids the origin")
    if "LoopbackBenchmarkOriginServer" not in runtime or "NWListener" not in origin:
        fail("W2 headless comparison must use the shared real loopback HTTP origin")
    if 'Cache-Control: public, max-age=3600' not in origin:
        fail("shared loopback origin must publish an explicitly cacheable response")



def verify_simulator_runner_resilience() -> None:
    runner_paths = [
        ROOT / "scripts/run-comparative-simulator-lab.py",
        ROOT / "scripts/run-asyncimage-simulator-lab.py",
    ]
    support_path = ROOT / "scripts/comparative_simulator_support.py"
    support = support_path.read_text()
    required_support = {
        "stable simulator runtime": 'SIMULATOR_RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-4"',
        "exact runtime build": 'SIMULATOR_RUNTIME_BUILD = "23E254a"',
        "dedicated simulator": 'SIMULATOR_NAME = "Fovea Comparative iPhone 17e R26"',
        "dedicated device type": 'SIMULATOR_DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17e"',
        "exact runtime bundle creation": 'runtime["runtimeBundlePath"]',
        "live runtime path verification": "def _verify_live_device_runtime(",
        "runtime mismatch shutdown": '"simctl", "shutdown", udid',
        "live runtime build evidence": '"lastLiveRuntimeBuilds"',
        "runtime registry": "comparative-simulator-device.json",
        "bounded first boot": "FIRST_BOOT_TIMEOUT_SECONDS = 900",
        "first boot failure evidence": 'registry["lastFirstBootFailureAt"]',
        "incomplete device reuse rejection": "recorded incomplete first boot",
        "boot migration diagnostics": '"bootstatus", udid, "-b", "-d"',
        "install readiness contract": "def _wait_for_install_readiness(",
        "terminal boot readiness": 'readiness_mode = "terminal-boot"',
        "install service readiness": 'readiness_mode = "install-critical-services"',
        "CoreSimulator health gate": "def assert_coresimulator_healthy(",
        "CoreSimulator health evidence": "comparative-coresimulator-health.json",
        "uninterruptible process rejection": "blocked-uninterruptible-processes",
        "host quiescence evidence": "comparative-host-preflight.json",
        "initialization host evidence": "comparative-initialization-host-preflight.json",
        "initialization host gate": "def assert_initialization_host_quiet(",
        "initialization gate before creation": "assert_initialization_host_quiet(root=root)",
        "CPU idle threshold": "MINIMUM_CPU_IDLE_PERCENT = 65.0",
        "disk throughput threshold": "MAXIMUM_DISK_MEGABYTES_PER_SECOND = 12.0",
        "competing process rejection": "competing build or simulator processes",
        "install timeout recovery": "def recover_dedicated_simulator_user_services(",
        "recovery artifact": "comparative-simulator-recovery.json",
    }
    missing = [
        label for label, marker in required_support.items() if marker not in support
    ]
    if missing:
        fail(
            "simulator support contract drifted; missing: " + ", ".join(missing)
        )
    for path in runner_paths:
        source = path.read_text()
        required = {
            "shared simulator support import": "from comparative_simulator_support import (",
            "dedicated simulator symbol": "ensure_dedicated_simulator,",
            "host gate symbol": "assert_measurement_host_quiet,",
            "shared simulator support call": "ensure_dedicated_simulator(",
            "isolated process group": "start_new_session=True",
            "bounded process-group termination": "os.killpg(process.pid, signal.SIGKILL)",
            "two-phase build mode": '"--build-only"',
            "measurement host gate": "assert_measurement_host_quiet(",
            "simulator profile injection": "SIMCTL_CHILD_FOVEA_SIMULATOR_PROFILE_ID",
            "simulator version injection": "SIMCTL_CHILD_FOVEA_SIMULATOR_OS_VERSION",
            "simulator build injection": "SIMCTL_CHILD_FOVEA_SIMULATOR_OS_BUILD",
            "simulator channel injection": "SIMCTL_CHILD_FOVEA_SIMULATOR_OS_CHANNEL",
        }
        required.update(
            {
                "simulator-only initialization": '"--initialize-simulator-only"',
                "prebuilt app installation": '"--install-only"',
            }
        )
        if path.name == "run-comparative-simulator-lab.py":
            required.update(
                {
                    "true build-only function": "def build_apps(env: dict[str, str], selected: list[str])",
                    "build-only no installation report": "installations=0 measurements=0",
                }
            )
            if "def build_install(" in source:
                fail("headless --build-only must not retain build-and-install coupling")
        if path.name == "run-asyncimage-simulator-lab.py":
            required.update(
                {
                    "true SwiftUI build-only function": "def build_apps(env: dict[str, str], selected: list[str])",
                    "SwiftUI build-only no installation report": "installations=0 measurements=0",
                    "post-resource app signing": '"post-resource-ad-hoc-codesign"',
                    "strict staged signature verification": '"--verify", "--deep", "--strict"',
                    "extended attribute removal": '"xattr", "-cr"',
                    "install-only overlay path": "def install_staged_app(",
                }
            )
        missing = [label for label, marker in required.items() if marker not in source]
        if missing:
            fail(
                f"simulator runner resilience contract drifted in {path.name}; missing: "
                + ", ".join(missing)
            )
    benchmark_models = (
        ROOT / "Benchmarks/ComparativeLab/Apps/Shared/BenchmarkModels.swift"
    ).read_text()
    required_profile = {
        "injected simulator profile": 'injected["FOVEA_SIMULATOR_PROFILE_ID"]',
        "injected simulator version": 'injected["FOVEA_SIMULATOR_OS_VERSION"]',
        "injected simulator build": 'injected["FOVEA_SIMULATOR_OS_BUILD"]',
        "injected simulator channel": 'injected["FOVEA_SIMULATOR_OS_CHANNEL"]',
        "runtime version verification": "versionMatchesCurrentSimulator",
        "fail-closed simulator identity": 'invalidResource("simulator-environment-identity")',
    }
    missing_profile = [
        label for label, marker in required_profile.items() if marker not in benchmark_models
    ]
    if missing_profile:
        fail("simulator app profile drifted; missing: " + ", ".join(missing_profile))

        if 'item.get("name") == "iPhone 17e"' in source:
            fail(f"{path.name} must not reuse the generic shared iPhone 17e simulator")
    selector = (ROOT / "scripts/select-xcode.sh").read_text()
    if '["xcode-select", "-p"]' not in selector or "timeout=5" not in selector:
        fail("Xcode selector must prefer and bound-check the active developer directory")


def lint_comparative_sources() -> None:
    targets = [
        "Benchmarks/ComparativeLab/Package.swift",
        "Benchmarks/ComparativeLab/Sources",
        "Benchmarks/ComparativeLab/Tests",
        "Benchmarks/ComparativeLab/Apps/Shared",
        "Benchmarks/ComparativeLab/Apps/AsyncImage",
    ]
    for spec in ADAPTERS:
        targets.extend([f"{spec.package_path}/Package.swift", f"{spec.package_path}/Sources"])
        if spec.name == "Apple URLSession + URLCache + ImageIO":
            targets.append(f"{spec.package_path}/Tests")
    for target in targets:
        path = ROOT / target
        command = [
            "xcrun",
            "swift-format",
            "lint",
            "--configuration",
            ".swift-format",
            "--strict",
        ]
        if path.is_dir():
            command.append("-r")
        command.append(target)
        require_success(invoke(command, capture=True, timeout=180), f"swift-format {target}")


def clean_package(path: str) -> None:
    require_success(
        invoke(["xcrun", "swift", "package", "--package-path", path, "clean"], capture=True, timeout=180),
        f"clean {path}",
    )


def build_adapter(spec: AdapterSpec) -> tuple[int, str]:
    clean_package(spec.package_path)
    operation = (
        "test" if spec.name == "Apple URLSession + URLCache + ImageIO" else "build"
    )
    command = ["xcrun", "swift", operation, "--package-path", spec.package_path]
    # External package warning policy is not overridden. The log audit below
    # still fails on warnings emitted by the adapter-owned source marker.
    result = invoke(command, capture=True, timeout=600)
    require_success(result, f"{spec.name} comparator adapter")
    combined = f"{result.stdout}\n{result.stderr}"
    local = local_warning_lines(combined, spec.source_marker)
    if local:
        print("\n".join(local), file=sys.stderr)
        fail(f"{spec.name} local adapter source emitted warnings")
    return len(warning_lines(combined)), combined


def ios_simulator_build(spec: AdapterSpec) -> tuple[int, str]:
    derived_data = ARTIFACT_ROOT / "DerivedData" / spec.scheme
    shutil.rmtree(derived_data, ignore_errors=True)
    command = [
        "xcodebuild",
        *XCODEBUILD_RESOLVED_PACKAGE_FLAGS,
        "-scheme",
        spec.scheme,
        "-destination",
        "generic/platform=iOS Simulator",
        "-derivedDataPath",
        str(derived_data),
    ]
    # Do not apply SWIFT_TREAT_WARNINGS_AS_ERRORS globally: SwiftPM marks
    # external dependencies with -suppress-warnings. Adapter-owned warnings
    # are rejected from the completed build log below.
    command.append("build")
    with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8") as log:
        process = subprocess.Popen(
            command,
            cwd=ROOT / spec.package_path,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
            env=selected_xcode_environment(),
        )
        while process.poll() is None:
            print(f"{spec.name} iOS adapter: build still running", flush=True)
            time.sleep(15)
        log.flush()
        log.seek(0)
        combined = log.read()
    if process.returncode != 0:
        print(combined[-20000:], file=sys.stderr)
        fail(f"{spec.name} iOS comparator adapter failed")
    local = local_warning_lines(combined, spec.source_marker)
    if local:
        print("\n".join(local), file=sys.stderr)
        fail(f"{spec.name} iOS local adapter source emitted warnings")
    return len(warning_lines(combined)), combined


def main() -> int:
    ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
    require_success(
        invoke(
            ["python3", "scripts/prepare-comparator-sources.py", "--include-reference"],
            capture=True,
            timeout=900,
        ),
        "challenge source preparation",
    )
    gates = [
        ("phase entry gate", ["python3", "scripts/check-phase0b-entry.py"]),
        ("device capture tests", ["python3", "scripts/test-phase0b-entry.py"]),
        ("dataset selection", ["python3", "scripts/prepare-comparative-dataset.py"]),
        ("comparison governance", ["python3", "scripts/check-comparison-governance.py"]),
        ("experiment plan", ["python3", "scripts/check-comparative-plan.py"]),
        ("AsyncImage plan", ["python3", "scripts/check-asyncimage-lab-plan.py"]),
        (
            "simulator support tests",
            ["python3", "-m", "unittest", "-v", "scripts.tests.test_comparative_simulator_support"],
        ),
        ("challenge suite", ["python3", "scripts/check-comparative-challenge-suite.py"]),
    ]
    for label, command in gates:
        require_success(invoke(command, capture=True, timeout=300), label)
    verify_fovea_visible_latency_contract()
    verify_apple_native_urlcache_contract()
    verify_runtime_configuration_attestation_contract()
    verify_sdwebimage_fixed_cache_and_downloader_contract()
    verify_kingfisher_fixed_cache_budget()
    verify_pinremoteimage_cache_isolation_and_dependency_pins()
    verify_simulator_runner_resilience()
    lint_comparative_sources()
    require_success(
        invoke(
            [
                "xcrun", "swift", "test", "--package-path", CORE_PACKAGE,
                "-Xswiftc", "-warnings-as-errors",
            ],
            capture=True,
            timeout=600,
        ),
        "comparative lab core tests",
    )

    external_requested = os.environ.get("RUN_COMPARATOR_ADAPTERS") == "1"
    ios_requested = os.environ.get("RUN_COMPARATOR_IOS") == "1"
    if ios_requested and not external_requested:
        fail("RUN_COMPARATOR_IOS=1 requires RUN_COMPARATOR_ADAPTERS=1")

    adapter_records: list[dict[str, object]] = []
    external_sources: list[dict[str, str]] = []
    specs = ADAPTERS if external_requested else [
        spec for spec in ADAPTERS if spec.name in {"Apple URLSession + URLCache + ImageIO", "Fovea"}
    ]
    if external_requested:
        external_sources = verify_adapter_sources()

    for spec in specs:
        warning_count, combined = build_adapter(spec)
        log_name = f"{spec.name.lower()}-macos-build.log"
        (ARTIFACT_ROOT / log_name).write_text(combined)
        record: dict[str, object] = {
            "name": spec.name,
            "source": (
                "current-workspace" if spec.name == "Fovea"
                else "platform-sdk" if spec.name == "Apple URLSession + URLCache + ImageIO"
                else "exact-detached-checkout"
            ),
            "macOSBuild": "passed",
            "macOSUpstreamWarningLines": warning_count,
            "localAdapterWarningLines": 0,
        }
        if spec.name == "Fovea":
            record["identityMode"] = "runner-injected-commit-tree-dirty-state"
        if spec.name == "Apple URLSession + URLCache + ImageIO":
            record["nativeURLCacheBehaviorTest"] = "passed"
            record["networkPath"] = "real-loopback-http"
        adapter_records.append(record)

    if ios_requested:
        by_name = {record["name"]: record for record in adapter_records}
        for spec in specs:
            warning_count, combined = ios_simulator_build(spec)
            (ARTIFACT_ROOT / f"{spec.name.lower()}-ios-build.log").write_text(combined)
            by_name[spec.name]["iOSSimulatorBuild"] = "passed"
            by_name[spec.name]["iOSUpstreamWarningLines"] = warning_count

        require_success(
            invoke(
                [
                    "xcodegen", "generate", "--spec",
                    "Benchmarks/ComparativeLab/Apps/project.yml",
                ],
                capture=True,
                timeout=180,
            ),
            "comparative app generation",
        )
        for scheme, label, log_name in (
            ("AsyncImageComparatorBench", "Apple AsyncImage", "apple-asyncimage-ios-build.log"),
            ("FoveaSwiftUIComparatorBench", "Fovea SwiftUI", "fovea-swiftui-ios-build.log"),
        ):
            surface_build = invoke(
                [
                    "xcodebuild",
                    *XCODEBUILD_RESOLVED_PACKAGE_FLAGS,
                    "-project",
                    "Benchmarks/ComparativeLab/Apps/FoveaComparativeApps.xcodeproj",
                    "-scheme", scheme,
                    "-destination", "generic/platform=iOS Simulator",
                    "-derivedDataPath", str(ARTIFACT_ROOT / "DerivedData" / scheme),
                    "CODE_SIGNING_ALLOWED=NO", "build",
                ],
                capture=True,
                timeout=900,
            )
            require_success(surface_build, f"{label} iOS benchmark app")
            (ARTIFACT_ROOT / log_name).write_text(
                f"{surface_build.stdout}\n{surface_build.stderr}"
            )

    report = {
        "schemaVersion": 2,
        "status": "passed",
        "externalAdaptersBuilt": external_requested,
        "iosAdapterBuilds": ios_requested,
        "adapters": adapter_records,
        "externalSources": external_sources,
        "coreContractTests": "passed",
        "foveaVisibleLatencyContract": "first-full-quality-preview-drain-to-final",
        "simulatorRunnerContract": (
            "exact-runtime-build-dedicated-device-resolved-only-two-phase-bounded-"
            "process-groups-critical-service-health-and-host-quiescence-gated"
        ),
        "simulatorSupportTests": "passed-17-tests",
        "challengeSuite": "passed",
        "experimentPlan": "passed",
        "asyncImagePlan": "passed",
        "aTierMatrix": [
            "Apple URLSession + URLCache + ImageIO", "Apple AsyncImage", "Nuke", "Kingfisher",
            "SDWebImage", "PINRemoteImage", "Fovea",
        ],
        "bTierRetained": ["AlamofireImage"],
        "phase1DeclarationAllowed": False,
        "phase1PreparationAllowed": True,
        "productionDependencyGraphModified": False,
    }
    complete_report = external_requested and ios_requested
    if complete_report:
        artifact_name = "verification.json"
        report_scope = "complete-external-and-ios"
    elif external_requested:
        artifact_name = "verification-external-macos.json"
        report_scope = "external-macos-only"
    else:
        artifact_name = "verification-local.json"
        report_scope = "local-core-only"
    report["reportScope"] = report_scope
    report["canonicalArtifactWritten"] = complete_report
    artifact_path = ARTIFACT_ROOT / artifact_name
    artifact_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "Comparative lab verification passed: "
        f"adapters={len(adapter_records)} external={external_requested} ios={ios_requested}"
    )
    print(f"Artifact: {artifact_path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
