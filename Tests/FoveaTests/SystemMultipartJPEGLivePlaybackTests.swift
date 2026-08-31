import CoreGraphics
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaSystem
import ImageCraftCore
import ImageIO
import XCTest

final class SystemMultipartJPEGLivePlaybackTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SystemMJPEGURLProtocol.state.reset()
    }

    func testOfficialSystemStreamsParsesDecodesAndPublishesLatestMJPEGFrame_W5_PT_090() async throws
    {
        let first = try makeSystemMJPEGJPEG(width: 16, height: 12, fill: 0x31)
        let second = try makeSystemMJPEGJPEG(width: 24, height: 18, fill: 0x7a)
        let body = systemMultipartBody(boundary: "system-frame", frames: [first, second])
        SystemMJPEGURLProtocol.state.configure(body: body)
        let system = try await makeSystemMJPEGPipeline()
        let request = try ImageRequest(
            url: try XCTUnwrap(URL(string: "https://system-mjpeg.example.test/finite")),
            target: TargetPixels(width: 8, height: 8),
            colorPolicy: .convertToSRGB,
            namespace: .publicNamespace(appID: "system-mjpeg"),
            networkPolicy: ImageRequestNetworkPolicy(
                allowsCellularAccess: false,
                allowsConstrainedNetworkAccess: false,
                allowsExpensiveNetworkAccess: false
            ),
            headers: ["X-MJPEG-Test": "preserved"]
        )
        let handle = try await system.makeMultipartJPEGLivePlayback(
            for: request,
            playbackPolicy: MultipartJPEGLivePlaybackPolicy(
                minimumFrameIntervalNanoseconds: 1
            ),
            maximumBufferedParts: 4,
            clock: SystemMJPEGAutoClock()
        )
        let recorder = SystemMJPEGOutputRecorder()
        try await handle.start { output in
            await recorder.record(output)
        }

        try await waitUntil("official system publishes final MJPEG frame") {
            await recorder.lastIndex() == 1
        }
        let recordedOutput = await recorder.lastOutput()
        let output = try XCTUnwrap(recordedOutput)
        XCTAssertEqual(output.sourcePartIndex, 1)
        XCTAssertEqual(output.image.pixelWidth, 8)
        XCTAssertEqual(output.image.pixelHeight, 6)
        XCTAssertGreaterThanOrEqual(output.decodedFrameCount, 1)

        let snapshot = SystemMJPEGURLProtocol.state.snapshot()
        XCTAssertEqual(snapshot.startedCount, 1)
        XCTAssertEqual(snapshot.requests.count, 1)
        let captured = try XCTUnwrap(snapshot.requests.first)
        XCTAssertEqual(captured.value(forHTTPHeaderField: "X-MJPEG-Test"), "preserved")
        XCTAssertFalse(captured.allowsCellularAccess)
        XCTAssertFalse(captured.allowsConstrainedNetworkAccess)
        XCTAssertFalse(captured.allowsExpensiveNetworkAccess)
        XCTAssertEqual(captured.cachePolicy, .reloadIgnoringLocalCacheData)
        try await waitUntil("finite MJPEG session unregisters after success") {
            await system.animationRuntime.registeredLiveSessionCount() == 0
        }

        await handle.cancel()
        let registeredAfterCancel = await system.animationRuntime.registeredLiveSessionCount()
        XCTAssertEqual(registeredAfterCancel, 0)
        await system.invalidateAndCancel()
    }

    func testCancellingUnstartedOfficialSessionStopsTransport_W5_PT_091() async throws {
        let system = try await makeSystemMJPEGPipeline()
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://system-mjpeg.example.test/hold")),
            target: TargetPixels(width: 8, height: 8),
            appID: "system-mjpeg-cancel"
        )
        let handle = try await system.makeMultipartJPEGLivePlayback(for: request)
        try await waitUntil("official MJPEG transport starts") {
            SystemMJPEGURLProtocol.state.snapshot().startedCount == 1
        }

        await handle.cancel()

        try await waitUntil("unstarted official MJPEG transport stops") {
            SystemMJPEGURLProtocol.state.snapshot().stoppedCount == 1
        }
        let registrationCount = await system.animationRuntime.registeredLiveSessionCount()
        XCTAssertEqual(registrationCount, 0)
        await system.invalidateAndCancel()
    }

    func testOfficialSystemRejectsPrivateMJPEGBeforeTransportSideEffects_W5_PT_092() async throws {
        let system = try await makeSystemMJPEGPipeline()
        let request = try ImageRequest(
            url: try XCTUnwrap(URL(string: "https://system-mjpeg.example.test/hold")),
            target: TargetPixels(width: 8, height: 8),
            namespace: SecurityNamespaceID("private-system-mjpeg"),
            authorizationContext: AuthorizationContextID("account")
        )

        do {
            _ = try await system.makeMultipartJPEGLivePlayback(for: request)
            XCTFail("Public-only system accepted a private MJPEG request")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.reasonCode, "profile-access-denied")
        }
        XCTAssertEqual(SystemMJPEGURLProtocol.state.snapshot().startedCount, 0)
        let deniedRegistrationCount = await system.animationRuntime.registeredLiveSessionCount()
        XCTAssertEqual(deniedRegistrationCount, 0)
        await system.invalidateAndCancel()
    }

    func testLiveMJPEGAndOrdinaryFetchShareConfiguredAdmission_W5_PT_094() async throws {
        let ordinaryBody = try makePNG(width: 6, height: 4)
        SystemMJPEGURLProtocol.state.configure(
            body: Data(),
            ordinaryBody: ordinaryBody
        )
        let system = try await makeSystemMJPEGPipeline(
            pipelineConfiguration: PipelineConfiguration(
                maximumConcurrentFetches: 1,
                maximumQueuedFetches: 4
            )
        )
        let liveRequest = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://system-mjpeg.example.test/hold")),
            target: TargetPixels(width: 8, height: 8),
            appID: "system-mjpeg-admission"
        )
        let live = try await system.makeMultipartJPEGLivePlayback(for: liveRequest)
        try await waitUntil("live MJPEG occupies shared fetch permit") {
            SystemMJPEGURLProtocol.state.snapshot().requestPaths == ["hold"]
        }

        let ordinaryRequest = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://system-mjpeg.example.test/ordinary.png")),
            target: TargetPixels(width: 6, height: 4),
            appID: "system-mjpeg-admission"
        )
        let ordinaryTask = Task {
            try await system.pipeline.encodedData(for: ordinaryRequest)
        }
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(
            SystemMJPEGURLProtocol.state.snapshot().requestPaths,
            ["hold"]
        )

        await live.cancel()
        try await waitUntil("ordinary fetch starts after live permit release") {
            SystemMJPEGURLProtocol.state.snapshot().requestPaths == ["hold", "ordinary.png"]
        }
        let loaded = try await ordinaryTask.value
        XCTAssertEqual(loaded, ordinaryBody)
        await system.invalidateAndCancel()
    }

    func testLiveQueueRejectionFailsWithoutStartingTransportAndUnregisters_W5_PT_095()
        async throws
    {
        SystemMJPEGURLProtocol.state.configure(
            body: systemMultipartBody(
                boundary: "system-frame",
                frames: [try makeSystemMJPEGJPEG(width: 8, height: 8, fill: 0x55)]
            )
        )
        let system = try await makeSystemMJPEGPipeline(
            pipelineConfiguration: PipelineConfiguration(
                maximumConcurrentFetches: 1,
                maximumQueuedFetches: 0
            )
        )
        let firstRequest = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://system-mjpeg.example.test/hold")),
            target: TargetPixels(width: 8, height: 8),
            appID: "system-mjpeg-queue"
        )
        let first = try await system.makeMultipartJPEGLivePlayback(for: firstRequest)
        try await waitUntil("first live stream occupies sole fetch permit") {
            SystemMJPEGURLProtocol.state.snapshot().requestPaths == ["hold"]
        }

        let secondRequest = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://system-mjpeg.example.test/finite")),
            target: TargetPixels(width: 8, height: 8),
            appID: "system-mjpeg-queue"
        )
        let second = try await system.makeMultipartJPEGLivePlayback(for: secondRequest)
        let failures = SystemMJPEGFailureRecorder()
        try await second.start(
            output: { _ in },
            failure: { error in await failures.record(error) }
        )

        try await waitUntil("queued live stream reports admission failure") {
            await failures.reasonCodes() == ["fetch-queue-limit-exceeded"]
        }
        XCTAssertEqual(
            SystemMJPEGURLProtocol.state.snapshot().requestPaths,
            ["hold"]
        )
        let registrations = await system.animationRuntime.registeredLiveSessionCount()
        XCTAssertEqual(registrations, 1)

        await first.cancel()
        await second.cancel()
        await system.invalidateAndCancel()
    }

    func testOfficialMJPEGEmitsBoundedRedactedDiagnostics_W5_PT_096() async throws {
        let first = try makeSystemMJPEGJPEG(width: 10, height: 10, fill: 0x22)
        let second = try makeSystemMJPEGJPEG(width: 12, height: 12, fill: 0x66)
        SystemMJPEGURLProtocol.state.configure(
            body: systemMultipartBody(
                boundary: "system-frame",
                frames: [first, second]
            )
        )
        let diagnostics = BoundedDiagnosticsSink(capacity: 256)
        let system = try await makeSystemMJPEGPipeline(diagnostics: diagnostics)
        await system.simulateApplicationActiveForTesting(false)
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://system-mjpeg.example.test/finite")),
            target: TargetPixels(width: 8, height: 8),
            appID: "system-mjpeg-diagnostics"
        )
        let handle = try await system.makeMultipartJPEGLivePlayback(
            for: request,
            playbackPolicy: MultipartJPEGLivePlaybackPolicy(
                minimumFrameIntervalNanoseconds: 1
            ),
            clock: SystemMJPEGAutoClock()
        )
        let recorder = SystemMJPEGOutputRecorder()
        try await handle.start { output in await recorder.record(output) }
        try await waitUntil("inactive MJPEG input drains into latest slot") {
            let snapshot = await handle.session.snapshotForTesting()
            return snapshot.inputFinished
                && snapshot.pendingPartIndex == 1
                && snapshot.droppedEncodedFrameCount == 1
        }
        let outputWhileInactive = await recorder.lastOutput()
        XCTAssertNil(outputWhileInactive)

        await system.simulateApplicationActiveForTesting(true)
        try await waitUntil("diagnostic MJPEG publishes latest frame") {
            await recorder.lastIndex() == 1
        }

        let events = await diagnostics.snapshot().map(\.event)
        let liveQueued = events.first {
            $0.kind == .fetchQueued && $0.reason == "mjpeg-live"
        }
        let liveStarted = events.first {
            $0.kind == .fetchStarted && $0.reason == "mjpeg-live"
        }
        let liveCompleted = events.first {
            $0.kind == .fetchCompleted && $0.reason == "mjpeg-live"
        }
        let superseded = events.first {
            $0.kind == .responseAnomaly
                && $0.reason == "mjpeg-live-frame-superseded"
        }
        let published = events.first {
            $0.kind == .decodeCompleted
                && $0.reason == "mjpeg-live-frame-published"
        }
        XCTAssertNotNil(liveQueued)
        XCTAssertNotNil(liveStarted)
        XCTAssertNotNil(liveCompleted)
        XCTAssertEqual(superseded?.itemCount, 1)
        XCTAssertEqual(published?.itemCount, 1)
        XCTAssertEqual(published?.outputPixelCount, 64)
        for event in [liveQueued, liveStarted, liveCompleted, superseded, published] {
            let digest = try XCTUnwrap(event?.keyDigest)
            XCTAssertEqual(digest.count, 64)
            XCTAssertTrue(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            XCTAssertFalse(event?.reason?.contains("system-mjpeg.example.test") == true)
            XCTAssertFalse(event?.reason?.contains("X-MJPEG-Test") == true)
        }

        await handle.cancel()
        await system.invalidateAndCancel()
    }

    func testNamespaceRevocationActivelyCancelsPrivateLiveTransport_W5_PT_097() async throws {
        let namespace = SecurityNamespaceID("private-live-revocation")
        let authorization = AuthorizationContextID("private-live-account")
        let system = try await makeSystemMJPEGPipeline(
            profileAccessPolicy: .allowOnly([
                ProfileAccessScope(
                    namespace: namespace,
                    authorizationContext: authorization
                )
            ])
        )
        let request = try ImageRequest(
            url: try XCTUnwrap(URL(string: "https://system-mjpeg.example.test/hold")),
            target: TargetPixels(width: 8, height: 8),
            namespace: namespace,
            authorizationContext: authorization
        )
        let handle = try await system.makeMultipartJPEGLivePlayback(for: request)
        try await waitUntil("private live transport starts before revocation") {
            SystemMJPEGURLProtocol.state.snapshot().requestPaths == ["hold"]
        }
        let registeredBefore = await system.animationRuntime.registeredLiveSessionCount()
        XCTAssertEqual(registeredBefore, 1)

        try await system.pipeline.revoke(namespace: namespace)

        try await waitUntil("namespace revocation stops private live transport") {
            SystemMJPEGURLProtocol.state.snapshot().stoppedCount == 1
        }
        let registeredAfter = await system.animationRuntime.registeredLiveSessionCount()
        let sessionState = await handle.session.snapshotForTesting()
        XCTAssertEqual(registeredAfter, 0)
        XCTAssertTrue(sessionState.isCancelled)
        await system.invalidateAndCancel()
    }

    func testReduceMotionDefaultsToFirstSourceFrameAndClosesTransport_W5_PT_100()
        async throws
    {
        let frames = try [
            makeSystemMJPEGJPEG(width: 9, height: 9, fill: 0x11),
            makeSystemMJPEGJPEG(width: 12, height: 12, fill: 0x44),
            makeSystemMJPEGJPEG(width: 15, height: 15, fill: 0x77),
        ]
        SystemMJPEGURLProtocol.state.configure(
            body: systemMultipartBody(boundary: "system-frame", frames: frames)
        )
        let system = try await makeSystemMJPEGPipeline()
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://system-mjpeg.example.test/finite")),
            target: TargetPixels(width: 8, height: 8),
            appID: "system-mjpeg-reduce-motion"
        )
        let handle = try await system.makeMultipartJPEGLivePlayback(
            for: request,
            reduceMotionEnabled: true,
            clock: SystemMJPEGAutoClock()
        )
        let recorder = SystemMJPEGOutputRecorder()
        try await handle.start { output in await recorder.record(output) }

        try await waitUntil("Reduce Motion publishes first MJPEG source frame") {
            await recorder.lastIndex() == 0
        }
        try await waitUntil("Reduce Motion MJPEG closes and unregisters") {
            await system.animationRuntime.registeredLiveSessionCount() == 0
                && SystemMJPEGURLProtocol.state.snapshot().stoppedCount >= 1
        }
        let outputs = await recorder.outputs()
        let state = await handle.session.snapshotForTesting()
        XCTAssertEqual(outputs.map(\.sourcePartIndex), [0])
        XCTAssertEqual(outputs.map(\.decodedFrameCount), [1])
        XCTAssertTrue(state.isFinished)
        XCTAssertFalse(state.isCancelled)
        await system.invalidateAndCancel()
    }

    func testReduceMotionPreserveKeepsLiveStreamRegistered_W5_PT_101() async throws {
        let frames = try [
            makeSystemMJPEGJPEG(width: 10, height: 10, fill: 0x21),
            makeSystemMJPEGJPEG(width: 14, height: 14, fill: 0x61),
        ]
        SystemMJPEGURLProtocol.state.configure(
            body: systemMultipartOpenBody(boundary: "system-frame", frames: frames)
        )
        let system = try await makeSystemMJPEGPipeline()
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://system-mjpeg.example.test/open")),
            target: TargetPixels(width: 8, height: 8),
            appID: "system-mjpeg-preserve-motion"
        )
        let handle = try await system.makeMultipartJPEGLivePlayback(
            for: request,
            playbackPolicy: MultipartJPEGLivePlaybackPolicy(
                maximumFramesPerSecond: 60,
                reduceMotionBehavior: .preserveLiveMotion
            ),
            reduceMotionEnabled: true,
            clock: SystemMJPEGAutoClock()
        )
        let recorder = SystemMJPEGOutputRecorder()
        try await handle.start { output in await recorder.record(output) }

        try await waitUntil("preserved live motion publishes current frame") {
            await recorder.lastOutput() != nil
        }
        let registered = await system.animationRuntime.registeredLiveSessionCount()
        let state = await handle.session.snapshotForTesting()
        XCTAssertEqual(registered, 1)
        XCTAssertFalse(state.isFinished)
        XCTAssertFalse(state.isCancelled)
        XCTAssertEqual(SystemMJPEGURLProtocol.state.snapshot().stoppedCount, 0)

        await handle.cancel()
        try await waitUntil("preserved live motion cancels transport") {
            SystemMJPEGURLProtocol.state.snapshot().stoppedCount >= 1
        }
        await system.invalidateAndCancel()
    }

    func testOfficialMJPEGUsesProgressOnlyTransportWithoutStagingBody_W5_PT_106()
        async throws
    {
        let frames = try [
            makeSystemMJPEGJPEG(width: 32, height: 24, fill: 0x18),
            makeSystemMJPEGJPEG(width: 40, height: 30, fill: 0x58),
        ]
        SystemMJPEGURLProtocol.state.configure(
            body: systemMultipartBody(boundary: "system-frame", frames: frames)
        )
        let root = try makeTemporaryDirectory("system-mjpeg-progress-only")
        let staging = root.appendingPathComponent("must-remain-absent", isDirectory: true)
        let system = try await makeSystemMJPEGPipeline(stagingDirectory: staging)
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://system-mjpeg.example.test/finite")),
            target: TargetPixels(width: 16, height: 16),
            appID: "system-mjpeg-progress-only"
        )
        let handle = try await system.makeMultipartJPEGLivePlayback(
            for: request,
            playbackPolicy: MultipartJPEGLivePlaybackPolicy(
                minimumFrameIntervalNanoseconds: 1
            ),
            clock: SystemMJPEGAutoClock()
        )
        let recorder = SystemMJPEGOutputRecorder()
        try await handle.start { output in await recorder.record(output) }
        try await waitUntil("official progress-only MJPEG completes") {
            let lastIndex = await recorder.lastIndex()
            let registered = await system.animationRuntime.registeredLiveSessionCount()
            return lastIndex == 1 && registered == 0
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        await system.invalidateAndCancel()
    }

    private func makeSystemMJPEGPipeline(
        pipelineConfiguration: PipelineConfiguration = PipelineConfiguration(),
        diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
        profileAccessPolicy: ProfileAccessPolicy = .publicOnly,
        stagingDirectory: URL? = nil
    ) async throws -> FoveaSystemPipeline {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SystemMJPEGURLProtocol.self]
        return try await FoveaSystemPipeline.open(
            cacheRoot: try makeTemporaryDirectory("system-mjpeg"),
            configuration: pipelineConfiguration,
            diagnostics: diagnostics,
            profileAccessPolicy: profileAccessPolicy,
            automaticallyPurgesMemoryOnPressure: true,
            sessionConfiguration: sessionConfiguration,
            stagingDirectory: stagingDirectory
        )
    }
}

private actor SystemMJPEGFailureRecorder {
    private var stored: [String] = []

    func record(_ error: any Error) {
        if let failure = error as? PipelineFailure {
            stored.append(failure.reasonCode)
        } else {
            stored.append(String(describing: error))
        }
    }

    func reasonCodes() -> [String] { stored }
}

private actor SystemMJPEGOutputRecorder {
    private var storedOutputs: [MultipartJPEGLiveFrameOutput] = []

    func record(_ output: MultipartJPEGLiveFrameOutput) {
        storedOutputs.append(output)
    }

    func lastIndex() -> Int? { storedOutputs.last?.sourcePartIndex }
    func lastOutput() -> MultipartJPEGLiveFrameOutput? { storedOutputs.last }
    func outputs() -> [MultipartJPEGLiveFrameOutput] { storedOutputs }
}

private actor SystemMJPEGAutoClock: AnimationPlaybackClock {
    private var value: UInt64 = 0

    func nowNanoseconds() -> UInt64 { value }

    func sleep(untilNanoseconds deadline: UInt64) throws {
        try Task.checkCancellation()
        value = max(value, deadline)
    }
}

private final class SystemMJPEGURLProtocol: URLProtocol {
    static let state = SystemMJPEGURLProtocolState()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "system-mjpeg.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.state.recordStart(request)
        if url.lastPathComponent == "ordinary.png" {
            let body = Self.state.ordinaryBody()
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "image/png",
                    "Content-Length": String(body.count),
                    "Cache-Control": "no-store",
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "multipart/x-mixed-replace; boundary=system-frame"
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard url.lastPathComponent != "hold" else { return }
        let body = Self.state.body()
        for start in stride(from: 0, to: body.count, by: 11) {
            let end = min(body.count, start + 11)
            client?.urlProtocol(self, didLoad: body.subdata(in: start..<end))
        }
        if url.lastPathComponent != "open" {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.state.recordStop()
    }
}

private final class SystemMJPEGURLProtocolState: @unchecked Sendable {
    struct Snapshot {
        let startedCount: Int
        let stoppedCount: Int
        let requests: [URLRequest]
        var requestPaths: [String] { requests.compactMap { $0.url?.lastPathComponent } }
    }

    private let lock = NSLock()
    private var storedBody = Data()
    private var storedOrdinaryBody = Data()
    private var startedCount = 0
    private var stoppedCount = 0
    private var requests: [URLRequest] = []

    func reset() {
        lock.withLock {
            storedBody = Data()
            storedOrdinaryBody = Data()
            startedCount = 0
            stoppedCount = 0
            requests = []
        }
    }

    func configure(body: Data, ordinaryBody: Data = Data()) {
        lock.withLock {
            storedBody = body
            storedOrdinaryBody = ordinaryBody
        }
    }

    func body() -> Data { lock.withLock { storedBody } }
    func ordinaryBody() -> Data { lock.withLock { storedOrdinaryBody } }

    func recordStart(_ request: URLRequest) {
        lock.withLock {
            startedCount += 1
            requests.append(request)
        }
    }

    func recordStop() { lock.withLock { stoppedCount += 1 } }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                startedCount: startedCount,
                stoppedCount: stoppedCount,
                requests: requests
            )
        }
    }
}

private func systemMultipartOpenBody(boundary: String, frames: [Data]) -> Data {
    var result = Data()
    for frame in frames {
        result.append(Data("--\(boundary)\r\n".utf8))
        result.append(Data("Content-Type: image/jpeg\r\n".utf8))
        result.append(Data("Content-Length: \(frame.count)\r\n\r\n".utf8))
        result.append(frame)
        result.append(Data("\r\n".utf8))
    }
    return result
}

private func systemMultipartBody(boundary: String, frames: [Data]) -> Data {
    var result = Data()
    for frame in frames {
        result.append(Data("--\(boundary)\r\n".utf8))
        result.append(Data("Content-Type: image/jpeg\r\n".utf8))
        result.append(Data("Content-Length: \(frame.count)\r\n\r\n".utf8))
        result.append(frame)
        result.append(Data("\r\n".utf8))
    }
    result.append(Data("--\(boundary)--\r\n".utf8))
    return result
}

private func makeSystemMJPEGJPEG(width: Int, height: Int, fill: UInt8) throws -> Data {
    let bytesPerRow = width * 4
    let pixels = Data(repeating: fill, count: bytesPerRow * height)
    guard let provider = CGDataProvider(data: pixels as CFData),
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    else { throw NSError(domain: "SystemMJPEGTests", code: 1) }

    let output = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        )
    else { throw NSError(domain: "SystemMJPEGTests", code: 2) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "SystemMJPEGTests", code: 3)
    }
    return output as Data
}
