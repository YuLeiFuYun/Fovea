import AkashicDisk
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class RetryPolicyTests: XCTestCase {
    func testRetryPolicyClampsProgrammaticExtremesAndRejectsPersistedOverflow() throws {
        let policy = TransportRetryPolicy(
            maximumAttempts: Int.max,
            baseDelayNanoseconds: UInt64.max,
            maximumDelayNanoseconds: UInt64.max,
            maximumTotalDelayNanoseconds: UInt64.max,
            maximumAdditionalResponseBytes: Int.max
        )
        XCTAssertEqual(policy.maximumAttempts, 8)
        XCTAssertEqual(policy.baseDelayNanoseconds, 60_000_000_000)
        XCTAssertEqual(policy.maximumDelayNanoseconds, 300_000_000_000)
        XCTAssertEqual(policy.maximumTotalDelayNanoseconds, 900_000_000_000)
        XCTAssertEqual(policy.schemaVersion, TransportRetryPolicy.currentSchemaVersion)
        XCTAssertEqual(policy.maximumAdditionalResponseBytes, 1024 * 1024 * 1024)

        let data = try JSONEncoder().encode(TransportRetryPolicy())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["maximumAttempts"] = 9
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TransportRetryPolicy.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testRetryPolicyCodableRejectsInvalidPersistedLimits() throws {
        let encoded = try JSONEncoder().encode(TransportRetryPolicy())
        let decoded = try JSONDecoder().decode(TransportRetryPolicy.self, from: encoded)
        XCTAssertEqual(decoded, TransportRetryPolicy())

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["maximumAttempts"] = 0
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TransportRetryPolicy.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )

        object["maximumAttempts"] = 1
        object["schemaVersion"] = 1
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TransportRetryPolicy.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testFullJitterUsesEntireWindowAndNeverUndercutsRetryAfter_MATH_PT_012() {
        let policy = TransportRetryPolicy(
            maximumAttempts: 4,
            baseDelayNanoseconds: 100,
            maximumDelayNanoseconds: 1_000,
            maximumTotalDelayNanoseconds: 10_000
        )

        XCTAssertEqual(
            policy.delayNanoseconds(
                afterFailedAttempt: 1,
                retryAfterNanoseconds: nil,
                jitterFractionPermille: 0
            ),
            0
        )
        XCTAssertEqual(
            policy.delayNanoseconds(
                afterFailedAttempt: 1,
                retryAfterNanoseconds: nil,
                jitterFractionPermille: 500
            ),
            50
        )
        XCTAssertEqual(
            policy.delayNanoseconds(
                afterFailedAttempt: 2,
                retryAfterNanoseconds: nil,
                jitterFractionPermille: 1_000
            ),
            200
        )
        XCTAssertEqual(
            policy.delayNanoseconds(
                afterFailedAttempt: 2,
                retryAfterNanoseconds: 175,
                jitterFractionPermille: 100
            ),
            175
        )
        XCTAssertEqual(
            policy.delayNanoseconds(
                afterFailedAttempt: 20,
                retryAfterNanoseconds: 2_000,
                jitterFractionPermille: 1_000
            ),
            1_000
        )
    }

    func testTransientTransportFailureRetriesWithinSharedBudgetErrPt003() async throws {
        let body = try makePNG()
        let transport = SequencedRetryTransport(steps: [
            .failure(URLError(.networkConnectionLost)),
            .response(statusCode: 200, headers: imageHeaders, body: body),
        ])
        let sleeper = RecordingRetrySleeper()
        let diagnostics = BoundedDiagnosticsSink(capacity: 64)
        let pipeline = try await makeRetryPipeline(
            transport: transport,
            sleeper: sleeper,
            diagnostics: diagnostics,
            policy: TransportRetryPolicy(
                maximumAttempts: 3,
                baseDelayNanoseconds: 10,
                maximumDelayNanoseconds: 100,
                maximumTotalDelayNanoseconds: 100
            )
        )
        let request = try publicRequest("transient-retry.png")

        _ = try await pipeline.image(for: request)

        let requestCount = await transport.requestCount
        let delays = await sleeper.delays
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(delays, [10])
        let retries = await diagnostics.snapshot().map(\.event).filter {
            $0.kind == .fetchRetryScheduled
        }
        XCTAssertEqual(retries.count, 1)
        XCTAssertEqual(retries.first?.attempt, 1)
        XCTAssertEqual(retries.first?.retryDelayNanoseconds, 10)
        XCTAssertEqual(retries.first?.reason, "url-session-transport")
    }

    func testRetryAfterControlsBoundedDelayErrPt003() async throws {
        let body = try makePNG()
        let transport = SequencedRetryTransport(steps: [
            .response(
                statusCode: 503,
                headers: ["Retry-After": "1"],
                body: Data()
            ),
            .response(statusCode: 200, headers: imageHeaders, body: body),
        ])
        let sleeper = RecordingRetrySleeper()
        let pipeline = try await makeRetryPipeline(
            transport: transport,
            sleeper: sleeper,
            policy: TransportRetryPolicy(
                maximumAttempts: 2,
                baseDelayNanoseconds: 10,
                maximumDelayNanoseconds: 2_000_000_000,
                maximumTotalDelayNanoseconds: 2_000_000_000
            )
        )

        _ = try await pipeline.image(for: publicRequest("retry-after.png"))

        let requestCount = await transport.requestCount
        let delays = await sleeper.delays
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(delays, [1_000_000_000])
    }

    func testSubscriberJoinDoesNotResetRetryBudgetErrPt003() async throws {
        let transport = SequencedRetryTransport(steps: [
            .failure(URLError(.timedOut)),
            .failure(URLError(.timedOut)),
            .failure(URLError(.timedOut)),
        ])
        let sleeper = GateFirstRetrySleeper()
        let diagnostics = BoundedDiagnosticsSink(capacity: 64)
        let pipeline = try await makeRetryPipeline(
            transport: transport,
            sleeper: sleeper,
            diagnostics: diagnostics,
            policy: TransportRetryPolicy(
                maximumAttempts: 3,
                baseDelayNanoseconds: 1,
                maximumDelayNanoseconds: 4,
                maximumTotalDelayNanoseconds: 10
            )
        )
        let request = try publicRequest("shared-budget.png")
        let first = Task { try await pipeline.image(for: request) }
        await sleeper.waitUntilFirstSleep()
        let joined = Task { try await pipeline.image(for: request) }
        try await waitUntilFetchJoined(diagnostics)
        await sleeper.releaseFirstSleep()

        for task in [first, joined] {
            do {
                _ = try await task.value
                XCTFail("All shared attempts must fail")
            } catch let failure as PipelineFailure {
                XCTAssertEqual(failure.category, .transport)
            }
        }

        let requestCount = await transport.requestCount
        let delays = await sleeper.delays
        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(delays, [1, 2])
    }

    func testCancellationDuringBackoffStopsFurtherAttemptsErrPt004() async throws {
        let transport = SequencedRetryTransport(steps: [
            .failure(URLError(.networkConnectionLost)),
            .response(statusCode: 200, headers: imageHeaders, body: try makePNG()),
        ])
        let sleeper = CancellableRetrySleeper()
        let diagnostics = BoundedDiagnosticsSink(capacity: 32)
        let pipeline = try await makeRetryPipeline(
            transport: transport,
            sleeper: sleeper,
            diagnostics: diagnostics,
            policy: TransportRetryPolicy(
                maximumAttempts: 2,
                baseDelayNanoseconds: 1_000_000_000,
                maximumDelayNanoseconds: 1_000_000_000,
                maximumTotalDelayNanoseconds: 1_000_000_000
            )
        )
        let request = try publicRequest("cancel-backoff.png")
        let task = Task { try await pipeline.image(for: request) }
        await sleeper.waitUntilSleeping()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled subscriber must not receive a result")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .cancelled)
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
        try await waitUntilDiagnostic(.fetchCancelled, in: diagnostics)
        let events = await diagnostics.snapshot().map(\.event)
        let started = try XCTUnwrap(events.first { $0.kind == .fetchStarted })
        let cancelled = try XCTUnwrap(events.first { $0.kind == .fetchCancelled })
        XCTAssertEqual(cancelled.keyDigest, started.keyDigest)
        XCTAssertEqual(cancelled.failureDisposition, .cancelled)
    }

    func testRetrySleeperFailureIsNotMisclassifiedAsCancellation() async throws {
        let transport = SequencedRetryTransport(steps: [
            .failure(URLError(.networkConnectionLost)),
            .response(statusCode: 200, headers: imageHeaders, body: try makePNG()),
        ])
        let diagnostics = BoundedDiagnosticsSink(capacity: 32)
        let pipeline = try await makeRetryPipeline(
            transport: transport,
            sleeper: FailingRetrySleeper(),
            diagnostics: diagnostics,
            policy: TransportRetryPolicy(
                maximumAttempts: 2,
                baseDelayNanoseconds: 1,
                maximumDelayNanoseconds: 1,
                maximumTotalDelayNanoseconds: 1
            )
        )

        do {
            _ = try await pipeline.image(for: publicRequest("sleeper-failure.png"))
            XCTFail("A failed retry scheduler must terminate the operation")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .internalFailure)
            XCTAssertEqual(failure.stage, .transport)
            XCTAssertEqual(failure.disposition, .terminal)
        }

        let events = await diagnostics.snapshot().map(\.event)
        XCTAssertEqual(events.filter { $0.kind == .fetchFailed }.count, 1)
        XCTAssertFalse(events.contains { $0.kind == .fetchCancelled })
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testAuthorizationStatusDoesNotRetryErrPt004() async throws {
        let transport = SequencedRetryTransport(steps: [
            .response(statusCode: 401, headers: [:], body: Data()),
            .response(statusCode: 200, headers: imageHeaders, body: try makePNG()),
        ])
        let sleeper = RecordingRetrySleeper()
        let pipeline = try await makeRetryPipeline(
            transport: transport,
            sleeper: sleeper,
            policy: TransportRetryPolicy(maximumAttempts: 3)
        )

        do {
            _ = try await pipeline.image(for: publicRequest("auth-no-retry.png"))
            XCTFail("401 must remain terminal without an explicit authorizer refresh")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .http)
            XCTAssertEqual(failure.statusCode, 401)
            XCTAssertEqual(failure.disposition, .terminal)
        }
        let requestCount = await transport.requestCount
        let delays = await sleeper.delays
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(delays.isEmpty)
    }

    func testTLSAndAuthenticationTransportFailuresNeverRetryErrPt004() async throws {
        for code in [
            URLError.serverCertificateUntrusted,
            URLError.appTransportSecurityRequiresSecureConnection,
            URLError.userAuthenticationRequired,
            URLError.badURL,
        ] {
            let transport = SequencedRetryTransport(steps: [
                .failure(URLError(code)),
                .response(statusCode: 200, headers: imageHeaders, body: try makePNG()),
            ])
            let sleeper = RecordingRetrySleeper()
            let pipeline = try await makeRetryPipeline(
                transport: transport,
                sleeper: sleeper,
                policy: TransportRetryPolicy(maximumAttempts: 3)
            )

            do {
                _ = try await pipeline.image(for: publicRequest("terminal-\(code.rawValue).png"))
                XCTFail("Terminal URL error must not retry: \(code)")
            } catch let failure as PipelineFailure {
                XCTAssertEqual(failure.disposition, .terminal)
                XCTAssertEqual(failure.reasonCode, "url-session-terminal")
            }
            let requestCount = await transport.requestCount
            let delays = await sleeper.delays
            XCTAssertEqual(requestCount, 1)
            XCTAssertTrue(delays.isEmpty)
        }
    }

    func testAdditionalResponseByteBudgetStopsRetry() async throws {
        let transport = SequencedRetryTransport(steps: [
            .response(statusCode: 503, headers: [:], body: Data(repeating: 1, count: 128)),
            .response(statusCode: 200, headers: imageHeaders, body: try makePNG()),
        ])
        let pipeline = try await makeRetryPipeline(
            transport: transport,
            sleeper: RecordingRetrySleeper(),
            policy: TransportRetryPolicy(
                maximumAttempts: 2,
                maximumAdditionalResponseBytes: 64
            )
        )

        do {
            _ = try await pipeline.image(for: publicRequest("byte-budget.png"))
            XCTFail("503 must surface when retry byte budget is exhausted")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.statusCode, 503)
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testTotalDelayBudgetStopsRetry() async throws {
        let transport = SequencedRetryTransport(steps: [
            .failure(URLError(.timedOut)),
            .response(statusCode: 200, headers: imageHeaders, body: try makePNG()),
        ])
        let sleeper = RecordingRetrySleeper()
        let pipeline = try await makeRetryPipeline(
            transport: transport,
            sleeper: sleeper,
            policy: TransportRetryPolicy(
                maximumAttempts: 2,
                baseDelayNanoseconds: 100,
                maximumDelayNanoseconds: 100,
                maximumTotalDelayNanoseconds: 50
            )
        )

        do {
            _ = try await pipeline.image(for: publicRequest("delay-budget.png"))
            XCTFail("Transport failure must surface when delay budget is exhausted")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .transport)
        }
        let requestCount = await transport.requestCount
        let delays = await sleeper.delays
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(delays.isEmpty)
    }

    private func waitUntilDiagnostic(
        _ kind: DiagnosticEventKind,
        in diagnostics: BoundedDiagnosticsSink
    ) async throws {
        try await waitUntil("发布诊断事件 \(kind.rawValue)") {
            await diagnostics.snapshot().contains { $0.event.kind == kind }
        }
    }

    private func waitUntilFetchJoined(_ diagnostics: BoundedDiagnosticsSink) async throws {
        try await waitUntil("第二个订阅者加入共享重试任务") {
            await diagnostics.snapshot().contains { $0.event.kind == .fetchJoined }
        }
    }

    private func makeRetryPipeline(
        transport: any HTTPTransporting,
        sleeper: any RetrySleeping,
        diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
        policy: TransportRetryPolicy
    ) async throws -> FoveaPipeline {
        let root = try makeTemporaryDirectory()
        return FoveaPipeline(
            configuration: PipelineConfiguration(transportRetryPolicy: policy),
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")
            ),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")
            ),
            namespaceRegistry: NamespaceRegistry(),
            diagnostics: diagnostics,
            profileAccessPolicy: .unrestricted,
            decoder: ImageIOImageDecoder(),
            retrySleeper: sleeper,
            retryJitter: FixedRetryJitter()
        )
    }

    private func publicRequest(_ path: String) throws -> ImageRequest {
        try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/\(path)")),
            target: TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
    }

    private var imageHeaders: [String: String] {
        ["Content-Type": "image/png", "Cache-Control": "no-store"]
    }
}

private actor SequencedRetryTransport: HTTPTransporting {
    nonisolated let reusePolicy = TransportReusePolicy.reusable(
        contextIdentifier: "tests-sequenced-retry-v1"
    )

    enum Step: Sendable {
        case failure(URLError)
        case response(statusCode: Int, headers: [String: String], body: Data)
    }

    private var steps: [Step]
    private(set) var requestCount = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func execute(_ request: TransportRequest) async throws -> TransportResponse {
        requestCount += 1
        guard !steps.isEmpty else { throw URLError(.resourceUnavailable) }
        let step = steps.removeFirst()
        switch step {
        case .failure(let error):
            throw error
        case .response(let statusCode, let headers, let body):
            return TransportResponse(
                head: try TransportResponseHead(
                    statusCode: statusCode,
                    headers: headers,
                    url: request.request.url
                ),
                body: body,
                metrics: TransportMetrics(receivedBytes: body.count, spilledToDisk: false)
            )
        }
    }
}

private struct FailingRetrySleeper: RetrySleeping {
    func sleep(nanoseconds: UInt64) async throws {
        throw RetrySleeperFixtureError.failed
    }
}

private enum RetrySleeperFixtureError: Error {
    case failed
}

private actor RecordingRetrySleeper: RetrySleeping {
    private(set) var delays: [UInt64] = []

    func sleep(nanoseconds: UInt64) async throws {
        delays.append(nanoseconds)
        try Task.checkCancellation()
    }
}

private actor GateFirstRetrySleeper: RetrySleeping {
    private(set) var delays: [UInt64] = []
    private var firstSleepStarted = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(nanoseconds: UInt64) async throws {
        delays.append(nanoseconds)
        if delays.count == 1 {
            firstSleepStarted = true
            for waiter in startWaiters { waiter.resume() }
            startWaiters.removeAll()
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
        }
        try Task.checkCancellation()
    }

    func waitUntilFirstSleep() async {
        guard !firstSleepStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstSleep() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}

private actor CancellableRetrySleeper: RetrySleeping {
    private var isSleeping = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(nanoseconds: UInt64) async throws {
        isSleeping = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }

    func waitUntilSleeping() async {
        guard !isSleeping else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct FixedRetryJitter: RetryJittering {
    func fractionPermille() async -> Int { 1_000 }
}
