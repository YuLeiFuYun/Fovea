import AkashicDisk
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class AuthenticationRefreshTests: XCTestCase {
    func testConcurrentUnauthorizedRequestsShareOneRefreshAuthPt007() async throws {
        let fixture = try await makeFixture()
        let refresher = GatedCredentialRefresher()
        let loader = RefreshingImageLoader(base: fixture.pipeline, refresher: refresher)

        async let first = loader.image(for: fixture.request)
        async let second = loader.image(for: fixture.request)
        await refresher.waitUntilStarted()
        await refresher.release()
        _ = try await [first, second]

        let refreshCount = await refresher.refreshCount
        XCTAssertEqual(refreshCount, 1)
        let counts = await fixture.transport.counts
        XCTAssertGreaterThanOrEqual(counts["Bearer old", default: 0], 1)
        XCTAssertGreaterThanOrEqual(counts["Bearer new", default: 0], 1)
    }

    func testCompletedRefreshCoversLateOldGenerationUnauthorizedRequestAuthPt007() async throws {
        let fixture = try await makeFixture()
        let refresher = FixedCredentialRefresher(
            result: CredentialRefreshResult(
                credentialGeneration: CredentialGeneration(2),
                headers: ["Authorization": "Bearer new"]
            )
        )
        let loader = RefreshingImageLoader(base: fixture.pipeline, refresher: refresher)

        _ = try await loader.image(for: fixture.request)
        _ = try await loader.image(for: fixture.request)

        let refreshCount = await refresher.refreshCount
        let counts = await fixture.transport.counts
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(counts["Bearer old"], 2)
        XCTAssertEqual(counts["Bearer new"], 2)
    }

    func testCancellingOneRefreshSubscriberDoesNotCancelOtherAuthPt007() async throws {
        let fixture = try await makeFixture()
        let refresher = GatedCredentialRefresher()
        let loader = RefreshingImageLoader(base: fixture.pipeline, refresher: refresher)
        let first = Task { try await loader.image(for: fixture.request) }
        let second = Task { try await loader.image(for: fixture.request) }
        await refresher.waitUntilStarted()

        first.cancel()
        await refresher.release()
        do {
            _ = try await first.value
            XCTFail("Cancelled subscriber must not receive a refreshed image")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .cancelled)
        }
        _ = try await second.value

        let refreshCount = await refresher.refreshCount
        let wasCancelled = await refresher.wasCancelled
        XCTAssertEqual(refreshCount, 1)
        XCTAssertFalse(wasCancelled)
        let counts = await fixture.transport.counts
        XCTAssertEqual(counts["Bearer new"], 1)
    }

    func testCancelledCallerCannotReplayRememberedCredentials_AUTH_PT_018() async throws {
        let fixture = try await makeFixture()
        let base = SecondOldCredentialGateLoader(base: fixture.pipeline)
        let refresher = FixedCredentialRefresher(
            result: CredentialRefreshResult(
                credentialGeneration: CredentialGeneration(2),
                headers: ["Authorization": "Bearer new"]
            )
        )
        let loader = RefreshingImageLoader(base: base, refresher: refresher)

        _ = try await loader.image(for: fixture.request)

        let cancelled = Task { try await loader.image(for: fixture.request) }
        await base.waitUntilSecondOldCredentialRequest()
        cancelled.cancel()
        await base.releaseSecondOldCredentialRequest()

        do {
            _ = try await cancelled.value
            XCTFail("A cancelled caller must not replay remembered credentials")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .cancelled)
            XCTAssertEqual(failure.stage, .requestValidation)
        }

        let refreshCount = await refresher.refreshCount
        let counts = await fixture.transport.counts
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(counts["Bearer new"], 1)
    }

    func testLastCancelledRefreshSubscriberCancelsOrphanAfterGrace_AUTH_PT_015() async throws {
        let fixture = try await makeFixture()
        let refresher = GatedCredentialRefresher()
        let loader = RefreshingImageLoader(
            base: fixture.pipeline,
            refresher: refresher,
            policy: CredentialRefreshPolicy(handoffGraceNanoseconds: 1_000_000)
        )
        let task = Task { try await loader.image(for: fixture.request) }
        await refresher.waitUntilStarted()

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled refresh subscriber must fail")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .cancelled)
        }
        try await waitUntil("credential refresh 收到取消") {
            await refresher.wasCancelled
        }

        let wasCancelled = await refresher.wasCancelled
        let refreshCount = await refresher.refreshCount
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(refreshCount, 1)
    }

    func testLateRefreshSubscriberWithinGraceReusesInFlightTask_AUTH_PT_015() async throws {
        let fixture = try await makeFixture()
        let refresher = GatedCredentialRefresher()
        let loader = RefreshingImageLoader(
            base: fixture.pipeline,
            refresher: refresher,
            policy: CredentialRefreshPolicy(handoffGraceNanoseconds: 500_000_000)
        )
        let first = Task { try await loader.image(for: fixture.request) }
        await refresher.waitUntilStarted()
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Cancelled subscriber must fail")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .cancelled)
        }

        let second = Task { try await loader.image(for: fixture.request) }
        try await waitUntil("第二个旧凭证请求进入 transport") {
            await fixture.transport.counts["Bearer old", default: 0] >= 2
        }
        let oldCredentialRequestCount = await fixture.transport.counts["Bearer old", default: 0]
        XCTAssertGreaterThanOrEqual(oldCredentialRequestCount, 2)
        await refresher.release()
        _ = try await second.value

        let refreshCount = await refresher.refreshCount
        let wasCancelled = await refresher.wasCancelled
        XCTAssertEqual(refreshCount, 1)
        XCTAssertFalse(wasCancelled)
    }

    func testRememberedCredentialsAreBoundedExpireAndCanBeInvalidated() async throws {
        let fixture = try await makeFixture()
        let refresher = FixedCredentialRefresher(
            result: CredentialRefreshResult(
                credentialGeneration: CredentialGeneration(2),
                headers: ["Authorization": "Bearer new"]
            )
        )
        let loader = RefreshingImageLoader(
            base: fixture.pipeline,
            refresher: refresher,
            policy: CredentialRefreshPolicy(
                resultReuseWindowNanoseconds: 60_000_000_000,
                maximumRememberedScopes: 2
            )
        )

        for namespace in ["account-a", "account-b", "account-c"] {
            _ = try await loader.image(
                for: try authenticatedRequest(
                    url: XCTUnwrap(URL(string: "https://example.test/\(namespace).png")),
                    context: "account",
                    generation: 1,
                    token: "Bearer old",
                    namespace: namespace
                )
            )
        }
        let boundedScopeCount = await loader.rememberedCredentialScopeCount()
        XCTAssertEqual(boundedScopeCount, 2)

        await loader.invalidateCredentials(for: SecurityNamespaceID("account-c"))
        let remainingScopeCount = await loader.rememberedCredentialScopeCount()
        XCTAssertEqual(remainingScopeCount, 1)

        let clock = CredentialTestMonotonicTimeSource()
        let expiringLoader = RefreshingImageLoader(
            base: fixture.pipeline,
            refresher: refresher,
            policy: CredentialRefreshPolicy(
                resultReuseWindowNanoseconds: 1_000_000,
                maximumRememberedScopes: 2
            ),
            timeSource: clock
        )
        _ = try await expiringLoader.image(for: fixture.request)
        clock.advance(nanoseconds: 1_000_001)
        _ = try await expiringLoader.image(for: fixture.request)
        let refreshCount = await refresher.refreshCount
        XCTAssertEqual(refreshCount, 5)
    }

    func testRevocableRefreshingLoaderInvalidatesCredentialsBeforeNamespaceRevoke() async throws {
        let fixture = try await makeFixture()
        let base = RevocationSpyImageLoader(base: fixture.pipeline)
        let refresher = FixedCredentialRefresher(
            result: CredentialRefreshResult(
                credentialGeneration: CredentialGeneration(2),
                headers: ["Authorization": "Bearer new"]
            )
        )
        let loader = RefreshingImageLoader(base: base, refresher: refresher)

        _ = try await loader.image(for: fixture.request)
        let rememberedBeforeRevoke = await loader.rememberedCredentialScopeCount()
        XCTAssertEqual(rememberedBeforeRevoke, 1)

        try await loader.revoke(namespace: fixture.request.namespace)

        let rememberedAfterRevoke = await loader.rememberedCredentialScopeCount()
        let revocationCount = await base.revocationCount
        XCTAssertEqual(rememberedAfterRevoke, 0)
        XCTAssertEqual(revocationCount, 1)
    }

    func testRefreshGenerationMustAdvanceAuthPt009() async throws {
        let fixture = try await makeFixture()
        let refresher = FixedCredentialRefresher(
            result: CredentialRefreshResult(
                credentialGeneration: CredentialGeneration(1),
                headers: ["Authorization": "Bearer new"]
            )
        )
        let loader = RefreshingImageLoader(base: fixture.pipeline, refresher: refresher)

        do {
            _ = try await loader.image(for: fixture.request)
            XCTFail("A refresh that does not advance generation must fail closed")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .authorization)
            XCTAssertEqual(failure.reasonCode, "credential-generation-not-advanced")
        }
        let counts = await fixture.transport.counts
        XCTAssertEqual(counts["Bearer old"], 1)
        XCTAssertNil(counts["Bearer new"])
    }

    func testForbiddenResponseDoesNotTriggerCredentialRefreshAuthPt009() async throws {
        let fixture = try await makeFixture(oldStatusCode: 403)
        let refresher = FixedCredentialRefresher(
            result: CredentialRefreshResult(
                credentialGeneration: CredentialGeneration(2),
                headers: ["Authorization": "Bearer new"]
            )
        )
        let loader = RefreshingImageLoader(base: fixture.pipeline, refresher: refresher)

        do {
            _ = try await loader.image(for: fixture.request)
            XCTFail("403 must not be converted into a credential refresh")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.statusCode, 403)
        }
        let refreshCount = await refresher.refreshCount
        XCTAssertEqual(refreshCount, 0)
    }

    func testRecursiveRefreshIsRejectedAuthPt009() async throws {
        let fixture = try await makeFixture()
        let refresher = RecursiveCredentialRefresher()
        let loader = RefreshingImageLoader(base: fixture.pipeline, refresher: refresher)
        await refresher.install {
            _ = try await loader.image(for: fixture.request)
        }

        do {
            _ = try await loader.image(for: fixture.request)
            XCTFail("Recursive credential refresh must not deadlock or recurse")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .authorization)
            XCTAssertEqual(failure.reasonCode, "credential-refresh-reentrancy")
        }
    }

    func testAuthorizationContextChangeChangesPersistentIdentityAuthPt002() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/context-change.png"))
        let first = try authenticatedRequest(
            url: url,
            context: "reader",
            generation: 1,
            token: "Bearer reader"
        )
        let second = try authenticatedRequest(
            url: url,
            context: "admin",
            generation: 1,
            token: "Bearer admin"
        )

        XCTAssertNotEqual(first.fetchBaseKey, second.fetchBaseKey)
        XCTAssertNotEqual(first.fetchVariantKey, second.fetchVariantKey)
    }

    func testCredentialReplacementPreservesRequestSemantics_AUTH_PT_013() throws {
        let original = try ImageRequest(
            url: try XCTUnwrap(URL(string: "https://example.test/credential-semantics.png")),
            target: try TargetPixels(width: 44, height: 33),
            contentMode: .fill,
            geometryPolicyFingerprint: "tests-geometry-v2",
            colorPolicy: .convertToSRGB,
            renderCacheAdmission: .transient,
            namespace: SecurityNamespaceID("account-a"),
            authorizationContext: AuthorizationContextID("reader"),
            credentialGeneration: CredentialGeneration(4),
            priority: .high,
            cachePolicy: .onlyIfCached,
            stalePolicy: .disallow,
            networkPolicy: .conservative,
            headers: [
                "Authorization": "Bearer old",
                "Accept-Language": "zh-CN",
            ]
        )
        let refreshed = try original.replacingCredentials(
            CredentialRefreshResult(
                credentialGeneration: CredentialGeneration(5),
                headers: ["Authorization": "Bearer new"]
            )
        )

        XCTAssertEqual(refreshed.url, original.url)
        XCTAssertEqual(refreshed.logicalSource, original.logicalSource)
        XCTAssertEqual(refreshed.target, original.target)
        XCTAssertEqual(refreshed.contentMode, original.contentMode)
        XCTAssertEqual(refreshed.geometryPolicyFingerprint, original.geometryPolicyFingerprint)
        XCTAssertEqual(refreshed.colorPolicy, original.colorPolicy)
        XCTAssertEqual(refreshed.renderCacheAdmission, original.renderCacheAdmission)
        XCTAssertEqual(refreshed.namespace, original.namespace)
        XCTAssertEqual(refreshed.authorizationContext, original.authorizationContext)
        XCTAssertEqual(refreshed.priority, original.priority)
        XCTAssertEqual(refreshed.cachePolicy, original.cachePolicy)
        XCTAssertEqual(refreshed.stalePolicy, original.stalePolicy)
        XCTAssertEqual(refreshed.networkPolicy, original.networkPolicy)
        XCTAssertEqual(refreshed.headers["accept-language"], "zh-CN")
        XCTAssertEqual(refreshed.headers["authorization"], "Bearer new")
        XCTAssertEqual(refreshed.credentialGeneration, CredentialGeneration(5))
    }

    private func makeFixture(oldStatusCode: Int = 401) async throws -> AuthRefreshFixture {
        let body = try makePNG()
        let transport = CredentialSwitchingTransport(
            oldStatusCode: oldStatusCode,
            body: body
        )
        let root = try makeTemporaryDirectory()
        let pipeline = FoveaPipeline(
            configuration: PipelineConfiguration(
                transportRetryPolicy: TransportRetryPolicy(maximumAttempts: 1)
            ),
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")
            ),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")
            ),
            profileAccessPolicy: .unrestricted,
            decoder: ImageIOImageDecoder()
        )
        let request = try authenticatedRequest(
            url: XCTUnwrap(URL(string: "https://example.test/private-refresh.png")),
            context: "account",
            generation: 1,
            token: "Bearer old"
        )
        return AuthRefreshFixture(
            pipeline: pipeline,
            transport: transport,
            request: request
        )
    }

    private func authenticatedRequest(
        url: URL,
        context: String,
        generation: UInt64,
        token: String,
        namespace: String = "account-a"
    ) throws -> ImageRequest {
        try ImageRequest(
            url: url,
            target: TargetPixels(width: 20, height: 20),
            namespace: SecurityNamespaceID(namespace),
            authorizationContext: AuthorizationContextID(context),
            credentialGeneration: CredentialGeneration(generation),
            headers: ["Authorization": token]
        )
    }
}

private final class CredentialTestMonotonicTimeSource: MonotonicTimeSource,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var value: UInt64 = 1_000_000_000

    func nowNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(nanoseconds: UInt64) {
        lock.lock()
        value &+= nanoseconds
        lock.unlock()
    }
}

private struct AuthRefreshFixture {
    let pipeline: FoveaPipeline
    let transport: CredentialSwitchingTransport
    let request: ImageRequest
}

private actor CredentialSwitchingTransport: HTTPTransporting {
    nonisolated let reusePolicy = TransportReusePolicy.reusable(
        contextIdentifier: "tests-credential-switch-v1"
    )

    private let oldStatusCode: Int
    private let body: Data
    private(set) var counts: [String: Int] = [:]

    init(oldStatusCode: Int, body: Data) {
        self.oldStatusCode = oldStatusCode
        self.body = body
    }

    func execute(_ request: TransportRequest) async throws -> TransportResponse {
        let credential = request.request.value(forHTTPHeaderField: "Authorization") ?? "missing"
        counts[credential, default: 0] += 1
        let statusCode = credential == "Bearer new" ? 200 : oldStatusCode
        let responseBody = statusCode == 200 ? body : Data()
        return TransportResponse(
            head: try TransportResponseHead(
                statusCode: statusCode,
                headers: statusCode == 200
                    ? ["Content-Type": "image/png", "Cache-Control": "no-store"]
                    : [:],
                url: request.request.url
            ),
            body: responseBody,
            metrics: TransportMetrics(receivedBytes: responseBody.count, spilledToDisk: false)
        )
    }
}

private actor SecondOldCredentialGateLoader: ImageLoading {
    private let base: any ImageLoading
    private var oldCredentialRequestCount = 0
    private var secondRequestReached = false
    private var secondRequestReleased = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(base: any ImageLoading) {
        self.base = base
    }

    func image(for request: ImageRequest) async throws -> DecodedImage {
        if request.credentialGeneration == CredentialGeneration(1) {
            oldCredentialRequestCount += 1
            if oldCredentialRequestCount == 2 {
                secondRequestReached = true
                for waiter in reachedWaiters { waiter.resume() }
                reachedWaiters.removeAll(keepingCapacity: false)
                if !secondRequestReleased {
                    await withCheckedContinuation { releaseWaiters.append($0) }
                }
                throw PipelineFailure(
                    category: .http,
                    stage: .responseValidation,
                    disposition: .terminal,
                    reasonCode: "unsupported-http-status",
                    statusCode: 401
                )
            }
        }
        return try await base.image(for: request)
    }

    func waitUntilSecondOldCredentialRequest() async {
        guard !secondRequestReached else { return }
        await withCheckedContinuation { reachedWaiters.append($0) }
    }

    func releaseSecondOldCredentialRequest() {
        secondRequestReleased = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll(keepingCapacity: false)
    }
}

private actor RevocationSpyImageLoader: ImageLoading, NamespaceRevoking {
    private let base: FoveaPipeline
    private(set) var revocationCount = 0

    init(base: FoveaPipeline) {
        self.base = base
    }

    func image(for request: ImageRequest) async throws -> DecodedImage {
        try await base.image(for: request)
    }

    func revoke(namespace: SecurityNamespaceID) async throws {
        revocationCount += 1
        try await base.revoke(namespace: namespace)
    }
}

private actor GatedCredentialRefresher: CredentialRefreshing {
    private(set) var refreshCount = 0
    private(set) var wasCancelled = false
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func refreshCredentials(
        namespace: SecurityNamespaceID,
        authorizationContext: AuthorizationContextID,
        currentGeneration: CredentialGeneration
    ) async throws -> CredentialRefreshResult {
        refreshCount += 1
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        do {
            if !released {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { releaseWaiters.append($0) }
                } onCancel: {
                    Task { await self.markCancelled() }
                }
            }
            try Task.checkCancellation()
        } catch {
            wasCancelled = true
            throw error
        }
        return CredentialRefreshResult(
            credentialGeneration: CredentialGeneration(currentGeneration.value + 1),
            headers: ["Authorization": "Bearer new"]
        )
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }

    private func markCancelled() {
        wasCancelled = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}

private actor FixedCredentialRefresher: CredentialRefreshing {
    private let result: CredentialRefreshResult
    private(set) var refreshCount = 0

    init(result: CredentialRefreshResult) {
        self.result = result
    }

    func refreshCredentials(
        namespace: SecurityNamespaceID,
        authorizationContext: AuthorizationContextID,
        currentGeneration: CredentialGeneration
    ) async throws -> CredentialRefreshResult {
        refreshCount += 1
        return result
    }
}

private actor RecursiveCredentialRefresher: CredentialRefreshing {
    private var recursiveOperation: (@Sendable () async throws -> Void)?

    func install(_ operation: @escaping @Sendable () async throws -> Void) {
        recursiveOperation = operation
    }

    func refreshCredentials(
        namespace: SecurityNamespaceID,
        authorizationContext: AuthorizationContextID,
        currentGeneration: CredentialGeneration
    ) async throws -> CredentialRefreshResult {
        try await recursiveOperation?()
        return CredentialRefreshResult(
            credentialGeneration: CredentialGeneration(currentGeneration.value + 1),
            headers: ["Authorization": "Bearer new"]
        )
    }
}
