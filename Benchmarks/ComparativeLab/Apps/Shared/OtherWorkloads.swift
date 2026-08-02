import ComparativeLabCore
import CryptoKit
import UIKit

@MainActor
final class HeroBenchmarkViewController: UIViewController {
    let imageView = UIImageView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        view.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

@MainActor
enum WorkloadRunner {
    static func runW2Correctness(
        adapter: any ComparatorAdapter,
        catalog: ResourceCatalog,
        runIndex: Int
    ) async throws -> [BenchmarkCheck] {
        let orientation = try catalog.correctnessProbe(identifier: "orientation-6-quadrants")
        let color = try catalog.correctnessProbe(identifier: "color-reference-srgb")
        let orientationViolations = try await probeViolationCount(
            orientation,
            adapter: adapter,
            runIndex: runIndex
        )
        let colorViolations = try await probeViolationCount(
            color,
            adapter: adapter,
            runIndex: runIndex
        )
        return [
            BenchmarkCheck(
                identifier: "orientation-correct",
                passed: orientationViolations == 0,
                value: orientationViolations
            ),
            BenchmarkCheck(
                identifier: "color-reference-accepted",
                passed: colorViolations == 0,
                value: colorViolations
            ),
        ]
    }

    static func runW2Performance(
        adapter: any ComparatorAdapter,
        catalog: ResourceCatalog,
        controller: HeroBenchmarkViewController,
        runIndex: Int
    ) async throws -> WorkloadResult {
        let accumulator = ObservationAccumulator()
        let started = DispatchTime.now().uptimeNanoseconds
        var targetViolations = 0
        let targets = [
            try ComparatorPixelTarget(width: 390, height: 260),
            try ComparatorPixelTarget(width: 780, height: 520),
            try ComparatorPixelTarget(width: 1_170, height: 780),
        ]
        let heroes = [
            "hero-12mp-4000x3000.jpg",
            "hero-24mp-6000x4000.jpg",
            "hero-48mp-8000x6000.jpg",
        ]
        for name in heroes {
            for target in targets {
                let resourceID = "hero|\(name)|\(target.width)x\(target.height)"
                let requestID = "w2-\(runIndex)-\(resourceID)"
                let request = try ComparatorRequest(
                    resourceID: resourceID,
                    url: BenchmarkCoordinator.benchmarkURL(path: "/hero/\(name)"),
                    target: target,
                    contentMode: .aspectFit,
                    priority: .immediate,
                    headers: ["X-Benchmark-Request-ID": requestID]
                )
                let output = try await adapter.makeLoad(request).result()
                await accumulator.append(resourceID: resourceID, target: target, output: output)
                if output.measurement.outcome == .completed {
                    guard let image = output.image else {
                        throw BenchmarkAppError.adapterDidNotRender
                    }
                    if image.cgImage.width > target.width || image.cgImage.height > target.height {
                        targetViolations += 1
                    }
                    controller.imageView.image = UIImage(cgImage: image.cgImage)
                    await Task.yield()
                }
            }
        }
        let snapshot = await accumulator.snapshot()
        return WorkloadResult(
            observations: snapshot.observations,
            checks: [
                BenchmarkCheck(
                    identifier: "target-pixel-invariant",
                    passed: targetViolations == 0,
                    value: targetViolations
                )
            ],
            durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- started,
            decodedMegapixels: snapshot.decodedMegapixels,
            completedLoads: snapshot.completed,
            cancelledLoads: snapshot.cancelled,
            failedLoads: snapshot.failed
        )
    }

    private static func probeViolationCount(
        _ probe: CorrectnessProbe,
        adapter: any ComparatorAdapter,
        runIndex: Int
    ) async throws -> Int {
        let target = try ComparatorPixelTarget(
            width: probe.expectedPixelWidth,
            height: probe.expectedPixelHeight
        )
        let request = try ComparatorRequest(
            resourceID: "correctness-probe|\(probe.identifier)",
            url: BenchmarkCoordinator.benchmarkURL(path: "/probe/\(probe.identifier)"),
            target: target,
            contentMode: .aspectFit,
            priority: .immediate,
            headers: [
                "X-Benchmark-Request-ID": "w2-\(runIndex)-probe-\(probe.identifier)"
            ]
        )
        let output = try await adapter.makeLoad(request).result()
        guard output.measurement.outcome == .completed, let image = output.image else {
            return probe.samples.count + 1
        }
        var violations = 0
        if image.cgImage.width != probe.expectedPixelWidth
            || image.cgImage.height != probe.expectedPixelHeight
        {
            violations += 1
        }
        violations += pixelMismatchCount(image.cgImage, probe: probe)
        return violations
    }

    private static func pixelMismatchCount(
        _ image: CGImage,
        probe: CorrectnessProbe
    ) -> Int {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return probe.samples.count }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard
                let context = CGContext(
                    data: bytes.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.interpolationQuality = .none
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return probe.samples.count }

        var mismatches = 0
        for sample in probe.samples {
            let x = min(width - 1, max(0, Int(sample.x * Double(width))))
            let topOriginY = min(height - 1, max(0, Int(sample.y * Double(height))))
            let bitmapRow = height - 1 - topOriginY
            let offset = bitmapRow * bytesPerRow + x * 4
            let actual = [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])]
            let maximumError = zip(actual, sample.rgb).map { abs($0 - $1) }.max() ?? Int.max
            if maximumError > probe.maxChannelError { mismatches += 1 }
        }
        return mismatches
    }

    static func runW3(
        adapter: any ComparatorAdapter,
        runIndex: Int
    ) async throws -> WorkloadResult {
        let accumulator = ObservationAccumulator()
        let started = DispatchTime.now().uptimeNanoseconds
        let target = try ComparatorPixelTarget(width: 32, height: 32)
        var checks: [BenchmarkCheck] = []

        NSLog("FOVEA_STAGE=w3-account-a-start")
        let accountA = try request(
            route: "/w3/auth",
            resourceID: "shared-auth-image",
            namespace: "account-a",
            authorization: "Bearer account-a",
            requestID: "w3-\(runIndex)-account-a",
            target: target
        )
        let aOutput = try await adapter.makeLoad(accountA).result()
        await accumulator.append(resourceID: accountA.resourceID, target: target, output: aOutput)
        let aDigest = try imageDigest(aOutput)
        NSLog("FOVEA_STAGE=w3-account-a-ready")

        NSLog("FOVEA_STAGE=w3-account-b-start")
        let beforeB = DeterministicBenchmarkURLProtocol.metrics()
        let accountB = try request(
            route: "/w3/auth",
            resourceID: "shared-auth-image",
            namespace: "account-b",
            authorization: "Bearer account-b",
            requestID: "w3-\(runIndex)-account-b",
            target: target
        )
        let bOutput = try await adapter.makeLoad(accountB).result()
        await accumulator.append(resourceID: accountB.resourceID, target: target, output: bOutput)
        let bDigest = try imageDigest(bOutput)
        let afterB = DeterministicBenchmarkURLProtocol.metrics()
        NSLog("FOVEA_STAGE=w3-account-b-ready")
        let pixelLeak = aDigest == bDigest ? 1 : 0
        let metadataCoupling =
            routeCount(afterB, "/w3/auth") > routeCount(beforeB, "/w3/auth") ? 0 : 1
        checks.append(
            BenchmarkCheck(
                identifier: "cross-account-pixel-leak-zero", passed: pixelLeak == 0,
                value: pixelLeak))
        checks.append(
            BenchmarkCheck(
                identifier: "cross-account-metadata-blob-coupling-zero",
                passed: metadataCoupling == 0, value: metadataCoupling))

        NSLog("FOVEA_STAGE=w3-no-store-start")
        let noStore = try request(
            route: "/w3/no-store",
            resourceID: "no-store-image",
            namespace: "account-a",
            authorization: "Bearer account-a",
            requestID: "w3-\(runIndex)-no-store-1",
            target: target
        )
        let beforeNoStore = DeterministicBenchmarkURLProtocol.metrics()
        let firstNoStore = try await adapter.makeLoad(noStore).result()
        await accumulator.append(
            resourceID: noStore.resourceID, target: target, output: firstNoStore)
        await adapter.purgeMemory()
        let secondNoStoreRequest = try request(
            route: "/w3/no-store",
            resourceID: "no-store-image",
            namespace: "account-a",
            authorization: "Bearer account-a",
            requestID: "w3-\(runIndex)-no-store-2",
            target: target
        )
        let secondNoStore = try await adapter.makeLoad(secondNoStoreRequest).result()
        await accumulator.append(
            resourceID: secondNoStoreRequest.resourceID, target: target, output: secondNoStore)
        let afterNoStore = DeterministicBenchmarkURLProtocol.metrics()
        let noStoreRequests =
            routeCount(afterNoStore, "/w3/no-store") - routeCount(beforeNoStore, "/w3/no-store")
        let noStoreViolation = noStoreRequests == 2 ? 0 : 1
        checks.append(
            BenchmarkCheck(
                identifier: "no-store-reusable-write-zero", passed: noStoreViolation == 0,
                value: noStoreViolation))
        NSLog("FOVEA_STAGE=w3-no-store-ready")

        NSLog("FOVEA_STAGE=w3-logout-start")
        try await adapter.revoke(namespace: "account-a")
        await adapter.purgeMemory()
        DeterministicBenchmarkURLProtocol.setOffline(route: "/w3/auth", value: true)
        let residueRequest = try request(
            route: "/w3/auth",
            resourceID: "shared-auth-image",
            namespace: "account-a",
            authorization: "Bearer account-a",
            requestID: "w3-\(runIndex)-logout-residue",
            target: target
        )
        let residue = try await adapter.makeLoad(residueRequest).result()
        await accumulator.append(
            resourceID: residueRequest.resourceID, target: target, output: residue)
        DeterministicBenchmarkURLProtocol.setOffline(route: "/w3/auth", value: false)
        let logoutViolation = residue.measurement.outcome == .completed ? 1 : 0
        checks.append(
            BenchmarkCheck(
                identifier: "logout-residue-zero", passed: logoutViolation == 0,
                value: logoutViolation))
        NSLog("FOVEA_STAGE=w3-logout-ready")

        NSLog("FOVEA_STAGE=w3-redirect-start")
        let redirectRequest = try request(
            route: "/w3/redirect",
            resourceID: "redirect-image",
            namespace: "account-b",
            authorization: "Bearer account-b",
            requestID: "w3-\(runIndex)-redirect",
            target: target
        )
        let redirectOutput = try await adapter.makeLoad(redirectRequest).result()
        await accumulator.append(
            resourceID: redirectRequest.resourceID, target: target, output: redirectOutput)
        NSLog("FOVEA_STAGE=w3-redirect-ready")

        NSLog("FOVEA_STAGE=w3-revoke-race-start")
        let delayedRequest = try request(
            route: "/w3/delayed",
            resourceID: "delayed-image",
            namespace: "race-account",
            authorization: "Bearer account-a",
            requestID: "w3-\(runIndex)-race",
            target: target
        )
        let delayedLoad = try await adapter.makeLoad(delayedRequest)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await adapter.revoke(namespace: "race-account")
        let delayedOutput = await delayedLoad.result()
        await accumulator.append(
            resourceID: delayedRequest.resourceID, target: target, output: delayedOutput)
        await adapter.purgeMemory()
        DeterministicBenchmarkURLProtocol.setOffline(route: "/w3/delayed", value: true)
        let raceProbe = try await adapter.makeLoad(delayedRequest).result()
        await accumulator.append(
            resourceID: delayedRequest.resourceID, target: target, output: raceProbe)
        DeterministicBenchmarkURLProtocol.setOffline(route: "/w3/delayed", value: false)
        let raceViolation = raceProbe.measurement.outcome == .completed ? 1 : 0
        NSLog("FOVEA_STAGE=w3-revoke-race-ready")
        checks.append(
            BenchmarkCheck(
                identifier: "revoke-commit-race-residue-zero", passed: raceViolation == 0,
                value: raceViolation))

        let origin = DeterministicBenchmarkURLProtocol.metrics()
        checks.append(
            BenchmarkCheck(
                identifier: "cross-origin-authorization-leak-zero",
                passed: origin.redirectAuthorizationLeakCount == 0,
                value: origin.redirectAuthorizationLeakCount
            )
        )
        let snapshot = await accumulator.snapshot()
        return WorkloadResult(
            observations: snapshot.observations,
            checks: checks,
            durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- started,
            decodedMegapixels: snapshot.decodedMegapixels,
            completedLoads: snapshot.completed,
            cancelledLoads: snapshot.cancelled,
            failedLoads: snapshot.failed
        )
    }

    private static func request(
        route: String,
        resourceID: String,
        namespace: String,
        authorization: String,
        requestID: String,
        target: ComparatorPixelTarget
    ) throws -> ComparatorRequest {
        try ComparatorRequest(
            resourceID: resourceID,
            url: BenchmarkCoordinator.benchmarkURL(path: route),
            target: target,
            contentMode: .aspectFit,
            priority: .immediate,
            securityNamespace: namespace,
            headers: [
                "Authorization": authorization,
                "X-Benchmark-Request-ID": requestID,
            ]
        )
    }

    private static func imageDigest(_ output: ComparatorLoadOutput) throws -> String {
        guard output.measurement.outcome == .completed,
            let image = output.image,
            let provider = image.cgImage.dataProvider,
            let data = provider.data as Data?
        else {
            throw BenchmarkAppError.adapterDidNotRender
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func routeCount(_ metrics: BenchmarkOriginMetrics, _ route: String) -> Int {
        metrics.routeRequestCounts[route, default: 0]
    }
}
