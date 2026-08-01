import FoveaCore
import ImageCraftCore
import XCTest

@testable import FoveaWorkbench

final class FoveaWorkbenchIntegrationTests: XCTestCase {
    func testDeterministicImageTraversesProductionPipelineAndHitsMemory_DEMO_PT_006() async throws {
        let (runtime, diagnostics) = try await makeRuntime()
        let scenario = try scenario("cacheable-image")
        let request = try request(for: scenario)

        let first = try await runtime.pipeline.image(for: request)
        let second = try await runtime.pipeline.image(for: request)

        XCTAssertLessThanOrEqual(first.pixelWidth, 400)
        XCTAssertLessThanOrEqual(first.pixelHeight, 300)
        XCTAssertEqual(first.pixelWidth, second.pixelWidth)
        let originRequestCounts = await DemoOriginMetrics.shared.snapshot()

        XCTAssertEqual(originRequestCounts["/image/cacheable"], 1)
        let observedMemoryHit = await waitForEvent(in: diagnostics) {
            $0.kind == .renderedMemoryHit
        }
        XCTAssertTrue(observedMemoryHit)
    }

    func testETagScenarioPerforms304Revalidation_DEMO_PT_006() async throws {
        let (runtime, diagnostics) = try await makeRuntime()
        let request = try request(for: scenario("etag-revalidation"))

        _ = try await runtime.pipeline.image(for: request)
        _ = try await runtime.pipeline.image(for: request)

        let originRequestCounts = await DemoOriginMetrics.shared.snapshot()

        XCTAssertEqual(originRequestCounts["/image/revalidate"], 2)
        let observedNotModified = await waitForEvent(in: diagnostics) {
            $0.statusCode == 304
        }
        XCTAssertTrue(observedNotModified)
    }

    func testVaryVariantsCoexistAndReturnToFreshEnglishRecord() async throws {
        let (runtime, _) = try await makeRuntime()
        let vary = try scenario("vary-language")
        var english = WorkbenchConfiguration.defaults
        english.varyLanguage = .english
        var chinese = english
        chinese.varyLanguage = .chinese

        _ = try await runtime.pipeline.image(for: try request(for: vary, configuration: english))
        _ = try await runtime.pipeline.image(for: try request(for: vary, configuration: chinese))
        _ = try await runtime.pipeline.image(for: try request(for: vary, configuration: english))

        let originRequestCounts = await DemoOriginMetrics.shared.snapshot()

        XCTAssertEqual(originRequestCounts["/image/vary"], 2)
    }

    func testAuthenticatedScenarioUsesExplicitPrivateProfile() async throws {
        let (runtime, _) = try await makeRuntime()
        let image = try await runtime.pipeline.image(
            for: try request(for: scenario("authenticated-private"))
        )
        XCTAssertGreaterThan(image.pixelWidth, 0)
        let originRequestCounts = await DemoOriginMetrics.shared.snapshot()

        XCTAssertEqual(originRequestCounts["/image/authenticated"], 1)
    }

    func testConcurrentBurstProducesSingleFlightJoin() async throws {
        let (runtime, diagnostics) = try await makeRuntime()
        let request = try request(for: scenario("single-flight-burst"))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = try await runtime.pipeline.image(for: request) }
            }
            try await group.waitForAll()
        }

        let originRequestCounts = await DemoOriginMetrics.shared.snapshot()

        XCTAssertEqual(originRequestCounts["/image/slow"], 1)
        let observedFetchJoin = await waitForEvent(in: diagnostics) {
            $0.kind == .fetchJoined
        }
        XCTAssertTrue(observedFetchJoin)
    }

    func testExpectedFailureScenariosProduceStableReasonCodes() async throws {
        let (runtime, _) = try await makeRuntime()
        let expectations = [
            "cache-only-miss": "only-if-cached-miss",
            "destination-denied": "profile-access-denied",
            "http-404": "unsupported-http-status",
            "wrong-mime": "non-image-response",
            "corrupt-image": "unsupported-image-format",
            "empty-image-body": "unsupported-image-format",
            "oversized-body": "encoded-body-limit-exceeded",
            "incomplete-body": "incomplete-response-body",
        ]

        for (identifier, reason) in expectations {
            do {
                _ = try await runtime.pipeline.image(for: try request(for: scenario(identifier)))
                XCTFail("\(identifier) unexpectedly succeeded")
            } catch let failure as PipelineFailure {
                XCTAssertEqual(failure.reasonCode, reason, identifier)
            }
        }
    }

    func testNoStoreRefetchesAndMissingContentTypeEmitsAnomaly() async throws {
        let (runtime, diagnostics) = try await makeRuntime()
        let noStore = try request(for: scenario("no-store"))
        _ = try await runtime.pipeline.image(for: noStore)
        _ = try await runtime.pipeline.image(for: noStore)
        let originRequestCounts = await DemoOriginMetrics.shared.snapshot()

        XCTAssertEqual(originRequestCounts["/image/no-store"], 2)

        let missingType = try request(for: scenario("missing-content-type"))
        _ = try await runtime.pipeline.image(for: missingType)
        let observedAnomaly = await waitForEvent(in: diagnostics) {
            $0.kind == .responseAnomaly && $0.reason == "missing-content-type"
        }
        XCTAssertTrue(observedAnomaly)
    }

    func testVaryWildcardResponseIsNeverReusedAcrossRequests() async throws {
        let (runtime, _) = try await makeRuntime()
        let request = try request(for: scenario("vary-wildcard"))

        _ = try await runtime.pipeline.image(for: request)
        _ = try await runtime.pipeline.image(for: request)

        let counts = await DemoOriginMetrics.shared.snapshot()
        XCTAssertEqual(counts["/image/vary-star"], 2)
    }

    func testSameOriginRedirectTraversesFinalDestination() async throws {
        let (runtime, diagnostics) = try await makeRuntime()
        let request = try request(for: scenario("same-origin-redirect"))

        let image = try await runtime.pipeline.image(for: request)

        XCTAssertGreaterThan(image.pixelWidth, 0)
        let counts = await DemoOriginMetrics.shared.snapshot()
        XCTAssertEqual(counts["/redirect/image"], 1)
        XCTAssertEqual(counts["/redirect/final-image"], 1)
        let observedRedirect = await waitForEvent(in: diagnostics) {
            ($0.redirectCount ?? 0) >= 1 || ($0.transactionCount ?? 0) >= 2
        }
        XCTAssertTrue(observedRedirect)
    }

    func testFeedRequestsShareByAssetInsteadOfCellIdentity() async throws {
        let (runtime, _) = try await makeRuntime()
        let items = WorkbenchFeedItem.makeItems(
            count: 48,
            uniqueAssetCount: 12,
            delayed: true
        )
        let target = try TargetPixels(width: 240, height: 160)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for item in items {
                let request = try WorkbenchRequestFactory.makeFeedRequest(
                    item: item,
                    target: target,
                    configuration: .deterministicDefaults,
                    identityRevision: "feed-test"
                )
                group.addTask { _ = try await runtime.pipeline.image(for: request) }
            }
            try await group.waitForAll()
        }

        let counts = await DemoOriginMetrics.shared.snapshot()
        let feedCounts = counts.filter { $0.key.hasPrefix("/feed/asset-") }
        XCTAssertEqual(feedCounts.count, 12)
        XCTAssertTrue(feedCounts.values.allSatisfy { $0 == 1 })
    }

    func testServerFailureUsesBoundedRetryBudget() async throws {
        let (runtime, _) = try await makeRuntime()
        do {
            _ = try await runtime.pipeline.image(for: try request(for: scenario("http-500")))
            XCTFail("HTTP 500 unexpectedly succeeded")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.reasonCode, "unsupported-http-status")
            XCTAssertEqual(failure.disposition, .retryable)
        }
        let originRequestCounts = await DemoOriginMetrics.shared.snapshot()

        XCTAssertEqual(originRequestCounts["/failure/status/500"], 2)
    }

    func testCancellationStopsSlowRequest() async throws {
        let (runtime, diagnostics) = try await makeRuntime()
        let request = try request(for: scenario("slow-placeholder"))
        let task = Task { try await runtime.pipeline.image(for: request) }
        let fetchStarted = await waitForEvent(in: diagnostics) { $0.kind == .fetchStarted }
        XCTAssertTrue(fetchStarted)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled request unexpectedly succeeded")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .cancelled)
            XCTAssertEqual(failure.reasonCode, "cancelled")
        }
        let observedCancellation = await waitForEvent(in: diagnostics) {
            $0.kind == .fetchCancelled || $0.failureCategory == .cancelled
        }
        XCTAssertTrue(observedCancellation)
    }

    func testRemoteAssetReentryAvoidsOriginAndRelaunchRestoresFromDisk() async throws {
        await DemoOriginMetrics.shared.reset()
        let configuration = WorkbenchConfiguration.deterministicDefaults
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoveaWorkbenchReentry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstDiagnostics = WorkbenchDiagnosticsSink(capacity: 1_024)
        let firstRuntime = try await WorkbenchPipelineFactory.open(
            cacheRoot: root,
            configuration: configuration,
            diagnostics: firstDiagnostics
        )
        let request = try WorkbenchRequestFactory.makeRemoteAssetRequest(
            asset: WorkbenchRemoteAssetCatalog.featured,
            target: TargetPixels(width: 640, height: 420),
            configuration: configuration
        )

        let first = try await firstRuntime.pipeline.image(for: request)
        let reentered = try await firstRuntime.pipeline.image(for: request)
        XCTAssertEqual(first.pixelWidth, reentered.pixelWidth)
        XCTAssertEqual(first.pixelHeight, reentered.pixelHeight)
        var originCounts = await DemoOriginMetrics.shared.snapshot()
        XCTAssertEqual(originCounts["/image/cacheable"], 1)

        await firstRuntime.invalidateAndCancel()

        let secondDiagnostics = WorkbenchDiagnosticsSink(capacity: 1_024)
        let secondRuntime = try await WorkbenchPipelineFactory.open(
            cacheRoot: root,
            configuration: configuration,
            diagnostics: secondDiagnostics
        )
        let restored = try await secondRuntime.pipeline.image(for: request)
        XCTAssertEqual(restored.pixelWidth, first.pixelWidth)
        XCTAssertEqual(restored.pixelHeight, first.pixelHeight)
        let observedDiskHit = await waitForEvent(in: secondDiagnostics) {
            $0.kind == .originalEncodedHit
        }
        XCTAssertTrue(observedDiskHit)
        originCounts = await DemoOriginMetrics.shared.snapshot()
        XCTAssertEqual(originCounts["/image/cacheable"], 1)
    }

    func testNamespaceRevocationInvalidatesPrivateReusableState() async throws {
        let (runtime, diagnostics) = try await makeRuntime()
        let request = try request(for: scenario("authenticated-private"))
        _ = try await runtime.pipeline.image(for: request)
        try await runtime.pipeline.revoke(namespace: workbenchPrivateNamespace)
        _ = try await runtime.pipeline.image(for: request)

        let originRequestCounts = await DemoOriginMetrics.shared.snapshot()

        XCTAssertEqual(originRequestCounts["/image/authenticated"], 2)
        let observedRevocation = await waitForEvent(in: diagnostics) {
            $0.kind == .namespaceRevoked
        }
        XCTAssertTrue(observedRevocation)
    }

    private func waitForEvent(
        in diagnostics: WorkbenchDiagnosticsSink,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        matching predicate: (DiagnosticEvent) -> Bool
    ) async -> Bool {
        let timeoutSeconds = Double(timeoutNanoseconds) / 1_000_000_000
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        repeat {
            if await diagnostics.snapshot().contains(where: { predicate($0.event) }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func makeRuntime(
        configuration: WorkbenchConfiguration = .defaults
    ) async throws -> (WorkbenchPipelineRuntime, WorkbenchDiagnosticsSink) {
        await DemoOriginMetrics.shared.reset()
        let diagnostics = WorkbenchDiagnosticsSink(capacity: 1_024)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoveaWorkbenchTests-\(UUID().uuidString)", isDirectory: true)
        let runtime = try await WorkbenchPipelineFactory.open(
            cacheRoot: root,
            configuration: configuration,
            diagnostics: diagnostics
        )
        return (runtime, diagnostics)
    }

    private func scenario(_ identifier: String) throws -> WorkbenchScenario {
        try XCTUnwrap(WorkbenchScenarioCatalog.all.first { $0.id == identifier })
    }

    private func request(
        for scenario: WorkbenchScenario,
        configuration: WorkbenchConfiguration = .defaults
    ) throws -> ImageRequest {
        try WorkbenchRequestFactory.makeRequest(
            scenario: scenario,
            target: TargetPixels(width: 400, height: 300),
            configuration: configuration
        )
    }
}
