import ComparativeLabCore
import CryptoKit
import UIKit

private final class ProgressiveMeasurementBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ComparatorProgressiveFrameMeasurement] = []

    func append(_ value: ComparatorProgressiveFrameMeasurement) {
        lock.withLock { values.append(value) }
    }

    func snapshot() -> [ComparatorProgressiveFrameMeasurement] {
        lock.withLock { values }
    }
}

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
                let displayStarted = DispatchTime.now().uptimeNanoseconds
                let output = try await adapter.makeLoad(request).result()
                let normalizedOutput: ComparatorLoadOutput
                if output.measurement.outcome == .completed {
                    guard let image = output.image else {
                        throw BenchmarkAppError.adapterDidNotRender
                    }
                    let materializationStarted = DispatchTime.now().uptimeNanoseconds
                    _ = try materializePixels(image.cgImage)
                    let materializationDuration =
                        DispatchTime.now().uptimeNanoseconds &- materializationStarted
                    let displayReadyDuration =
                        DispatchTime.now().uptimeNanoseconds &- displayStarted
                    let measurement = try ComparatorLoadResult(
                        outcome: output.measurement.outcome,
                        cacheSource: output.measurement.cacheSource,
                        latencyNanoseconds: output.measurement.latencyNanoseconds,
                        pixelWidth: output.measurement.pixelWidth,
                        pixelHeight: output.measurement.pixelHeight,
                        receivedBytes: output.measurement.receivedBytes,
                        failureCategory: output.measurement.failureCategory,
                        pixelMaterializationNanoseconds: materializationDuration,
                        displayReadyLatencyNanoseconds: displayReadyDuration
                    )
                    normalizedOutput = ComparatorLoadOutput(
                        measurement: measurement,
                        image: image
                    )
                    if image.cgImage.width > target.width || image.cgImage.height > target.height {
                        targetViolations += 1
                    }
                    controller.imageView.image = UIImage(cgImage: image.cgImage)
                    await Task.yield()
                } else {
                    normalizedOutput = output
                }
                await accumulator.append(
                    resourceID: resourceID,
                    target: target,
                    output: normalizedOutput
                )
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

    private static func materializePixels(_ image: CGImage) throws -> UInt8 {
        guard image.width > 0, image.height > 0,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            throw BenchmarkAppError.adapterDidNotRender
        }
        let bytesPerRow = image.width * 4
        var pixels = Data(count: bytesPerRow * image.height)
        let drew = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let baseAddress = storage.baseAddress,
                let context = CGContext(
                    data: baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                )
            else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        guard drew else { throw BenchmarkAppError.adapterDidNotRender }
        return pixels.withUnsafeBytes { storage in
            guard let first = storage.first, let last = storage.last else { return 0 }
            return first &+ last
        }
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

    static func runW4(
        adapter: any ComparatorAdapter,
        controller: HeroBenchmarkViewController,
        runIndex: Int
    ) async throws -> WorkloadResult {
        guard let progressive = adapter as? any ComparatorProgressiveAdapter else {
            throw BenchmarkAppError.runFailed("w4-progressive-adapter-unavailable")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let target = try ComparatorPixelTarget(width: 512, height: 512)
        let completeRequestID = "w4-\(runIndex)-complete"
        let completeRequest = try ComparatorRequest(
            resourceID: "w4-progressive-complete",
            url: BenchmarkCoordinator.benchmarkURL(path: "/w4/progressive.jpg"),
            target: target,
            contentMode: .aspectFit,
            priority: .immediate,
            headers: ["X-Benchmark-Request-ID": completeRequestID]
        )
        let completeLoad = try await progressive.makeProgressiveLoad(completeRequest)
        let presentationRecorder = ImageViewPresentationRecorder(imageView: controller.imageView)
        presentationRecorder.start()
        defer { presentationRecorder.stop() }
        var completeFrames: [ComparatorProgressiveFrameMeasurement] = []
        var completeFrameBindings:
            [(measurement: ComparatorProgressiveFrameMeasurement, token: UInt64, boundAt: UInt64)] =
                []
        var finalFrame: ComparatorProgressiveFrame?
        var finalObservedAtNanoseconds: UInt64?
        var nextBindingToken: UInt64 = 1
        for try await frame in completeLoad.frames {
            completeFrames.append(frame.measurement)
            controller.imageView.image = UIImage(cgImage: frame.image.cgImage)
            let boundAt = DispatchTime.now().uptimeNanoseconds
            let bindingToken = nextBindingToken
            nextBindingToken &+= 1
            presentationRecorder.didBind(
                image: frame.image.cgImage,
                bindingToken: bindingToken
            )
            completeFrameBindings.append(
                (measurement: frame.measurement, token: bindingToken, boundAt: boundAt)
            )
            await Task.yield()
            if frame.measurement.kind == .final {
                finalFrame = frame
                finalObservedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
            }
        }
        guard let finalFrame else {
            throw BenchmarkAppError.runFailed("w4-final-missing")
        }
        // `Task.yield()` is not a presentation oracle. Give the final binding a bounded number of
        // actual refresh opportunities so P2 is defined by CADisplayLink observation instead.
        await DisplayFrameBarrier(frameCount: 3).wait()
        presentationRecorder.stop()
        let previews = completeFrames.filter { $0.kind == .preview }
        let firstPreview = previews.first
        let previewBindings = completeFrameBindings.filter { $0.measurement.kind == .preview }
        guard
            let finalBinding = completeFrameBindings.last(where: { $0.measurement.kind == .final })
        else { throw BenchmarkAppError.runFailed("w4-final-binding-missing") }
        let finalP2 = presentationRecorder.observation(for: finalBinding.token)
        let usefulPreviewBindings = previewBindings.filter { binding in
            guard let observation = presentationRecorder.observation(for: binding.token),
                let finalP2
            else { return false }
            return observation.uptimeNanoseconds < finalP2.uptimeNanoseconds
        }
        let obsoletePreviewCount: Int? = finalP2.map { _ in
            previewBindings.count - usefulPreviewBindings.count
        }
        let finalBindToP2Nanoseconds: UInt64
        if let finalP2, finalP2.uptimeNanoseconds >= finalBinding.boundAt {
            finalBindToP2Nanoseconds = finalP2.uptimeNanoseconds - finalBinding.boundAt
        } else {
            finalBindToP2Nanoseconds = 0
        }
        let completeOrigin = DeterministicBenchmarkURLProtocol.metrics()
        let finalAfterLastByteNanoseconds: UInt64
        if let finalObservedAtNanoseconds,
            completeOrigin.latestCompletedAtNanoseconds > 0,
            finalObservedAtNanoseconds >= completeOrigin.latestCompletedAtNanoseconds
        {
            finalAfterLastByteNanoseconds =
                finalObservedAtNanoseconds - completeOrigin.latestCompletedAtNanoseconds
        } else {
            finalAfterLastByteNanoseconds = 0
        }
        let targetViolation =
            finalFrame.measurement.pixelWidth > target.width
            || finalFrame.measurement.pixelHeight > target.height

        let cancelRequestID = "w4-\(runIndex)-cancel"
        var cancelComponents = URLComponents(
            url: BenchmarkCoordinator.benchmarkURL(path: "/w4/progressive.jpg"),
            resolvingAgainstBaseURL: false
        )!
        cancelComponents.queryItems = [URLQueryItem(name: "case", value: "cancel")]
        let cancelRequest = try ComparatorRequest(
            resourceID: "w4-progressive-cancel",
            url: cancelComponents.url!,
            target: target,
            contentMode: .aspectFit,
            priority: .immediate,
            headers: ["X-Benchmark-Request-ID": cancelRequestID]
        )
        let cancelLoad = try await progressive.makeProgressiveLoad(cancelRequest)
        let cancelMeasurements = ProgressiveMeasurementBox()
        let cancelCollector = Task { @MainActor in
            do {
                for try await frame in cancelLoad.frames {
                    cancelMeasurements.append(frame.measurement)
                    controller.imageView.image = UIImage(cgImage: frame.image.cgImage)
                    await Task.yield()
                }
            } catch {
                // Cancellation is the expected terminal state for this branch.
            }
        }
        try await Task.sleep(nanoseconds: 220_000_000)
        DeterministicBenchmarkURLProtocol.markCancellation(requestID: cancelRequestID)
        cancelLoad.cancel()
        try await Task.sleep(nanoseconds: 40_000_000)
        cancelCollector.cancel()
        let cancelFrames = cancelMeasurements.snapshot()

        let finalMeasurement = try ComparatorLoadResult(
            outcome: .completed,
            cacheSource: .network,
            latencyNanoseconds: finalFrame.measurement.elapsedNanoseconds,
            pixelWidth: finalFrame.measurement.pixelWidth,
            pixelHeight: finalFrame.measurement.pixelHeight,
            receivedBytes: finalFrame.measurement.receivedBytes
        )
        let observation = try ComparatorObservation(
            sequence: 0,
            resourceID: completeRequest.resourceID,
            target: target,
            result: finalMeasurement
        )
        let firstPreviewLatency = firstPreview.map { Int(clamping: $0.elapsedNanoseconds) } ?? -1
        let firstPreviewBytes = firstPreview?.receivedBytes ?? -1
        let cancelPreviewCount = cancelFrames.filter { $0.kind == .preview }.count
        let checks = [
            BenchmarkCheck(
                identifier: "w4-preview-produced",
                passed: true,
                value: previews.count
            ),
            BenchmarkCheck(
                identifier: "w4-first-preview-latency-nanoseconds",
                passed: true,
                value: firstPreviewLatency
            ),
            BenchmarkCheck(
                identifier: "w4-first-preview-received-bytes",
                passed: true,
                value: firstPreviewBytes
            ),
            BenchmarkCheck(
                identifier: "w4-final-latency-nanoseconds",
                passed: true,
                value: Int(clamping: finalFrame.measurement.elapsedNanoseconds)
            ),
            BenchmarkCheck(
                identifier: "w4-origin-complete-duration-nanoseconds",
                passed: completeOrigin.completedRequestCount == 1,
                value: Int(clamping: completeOrigin.completedRequestDurationP50Nanoseconds)
            ),
            BenchmarkCheck(
                identifier: "w4-final-after-last-byte-nanoseconds",
                passed: finalAfterLastByteNanoseconds > 0,
                value: Int(clamping: finalAfterLastByteNanoseconds)
            ),
            BenchmarkCheck(
                identifier: "w4-complete-preview-count",
                passed: true,
                value: previews.count
            ),
            BenchmarkCheck(
                identifier: "w4-p2-observed-preview-count",
                passed: finalP2 != nil,
                value: finalP2 == nil ? -1 : usefulPreviewBindings.count
            ),
            BenchmarkCheck(
                identifier: "w4-p2-obsolete-preview-count",
                passed: obsoletePreviewCount != nil,
                value: obsoletePreviewCount ?? -1
            ),
            BenchmarkCheck(
                identifier: "w4-final-p2-observed",
                passed: finalP2 != nil,
                value: finalP2 == nil ? 0 : 1
            ),
            BenchmarkCheck(
                identifier: "w4-final-bind-to-p2-nanoseconds",
                passed: finalBindToP2Nanoseconds > 0,
                value: Int(clamping: finalBindToP2Nanoseconds)
            ),
            BenchmarkCheck(
                identifier: "w4-cancel-preview-count-at-220ms",
                passed: true,
                value: cancelPreviewCount
            ),
            BenchmarkCheck(
                identifier: "w4-target-pixel-invariant",
                passed: !targetViolation,
                value: targetViolation ? 1 : 0
            ),
        ]
        return WorkloadResult(
            observations: [observation],
            checks: checks,
            durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- started,
            decodedMegapixels: Double(
                finalFrame.measurement.pixelWidth * finalFrame.measurement.pixelHeight
            ) / 1_000_000,
            completedLoads: 1,
            cancelledLoads: 1,
            failedLoads: 0
        )
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
