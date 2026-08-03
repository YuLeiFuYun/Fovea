import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaSystem
import FoveaTesting
import ImageCraftCore
import XCTest

final class FoveaSystemPipelineTests: XCTestCase {
    func testSystemPipelineInvalidationPreventsNewNetworkTasks_RES_PT_019() async throws {
        let root = try makeTemporaryDirectory("system-invalidation")
        let system = try await FoveaSystemPipeline.open(
            cacheRoot: root,
            automaticallyPurgesMemoryOnPressure: false
        )
        await system.invalidateAndCancel()
        await system.invalidateAndCancel()

        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/closed.png")),
            target: TargetPixels(width: 20, height: 20),
            appID: "system-invalidation"
        )
        do {
            _ = try await system.pipeline.image(for: request)
            XCTFail("Closed system pipeline unexpectedly created network work")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .cancelled)
            XCTAssertEqual(failure.stage, .transport)
            XCTAssertEqual(failure.reasonCode, "cancelled")
        }
    }

    func testSystemMemoryPressureMonitorCanBeEnabledOrDisabled() async throws {
        let disabled = try await FoveaSystemPipeline.open(
            cacheRoot: try makeTemporaryDirectory("system-pressure-disabled"),
            automaticallyPurgesMemoryOnPressure: false
        )
        let enabled = try await FoveaSystemPipeline.open(
            cacheRoot: try makeTemporaryDirectory("system-pressure-enabled"),
            automaticallyPurgesMemoryOnPressure: true
        )

        let disabledRemovalCount = await disabled.simulateMemoryPressureForTesting()
        let enabledRemovalCount = await enabled.simulateMemoryPressureForTesting()
        XCTAssertEqual(disabledRemovalCount, 0)
        XCTAssertEqual(enabledRemovalCount, 0)
    }

    func testMemoryPressureMonitorIsRetainedByPipelineInsteadOfWrapper() async throws {
        var system: FoveaSystemPipeline? = try await FoveaSystemPipeline.open(
            cacheRoot: try makeTemporaryDirectory("system-pressure-lifetime")
        )
        var pipeline: FoveaPipeline? = try XCTUnwrap(system?.pipeline)
        weak let monitor = system?.memoryPressureMonitor

        let anchorCount = await pipeline?.lifetimeAnchorCountForTesting()
        XCTAssertEqual(anchorCount, 2)
        system = nil
        for _ in 0..<20 where monitor == nil { await Task.yield() }
        XCTAssertNotNil(monitor)

        pipeline = nil
        try await waitUntil("pipeline 释放 memory-pressure monitor") {
            monitor == nil
        }
        XCTAssertNil(monitor)
    }

    func testMemoryPressurePurgesRenderedMemoryWithoutRefetch_RES_PT_011() async throws {
        let body = try makePNG(width: 40, height: 20)
        let diagnostics = BoundedDiagnosticsSink(capacity: 32)
        let (pipeline, transport, _, _) = try await makePipeline(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                    body: body
                )
            ],
            diagnostics: diagnostics
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/memory-pressure.png")),
            target: TargetPixels(width: 20, height: 20),
            appID: "memory-pressure-tests"
        )
        _ = try await pipeline.image(for: request)
        let monitor = FoveaMemoryPressureMonitor(pipeline: pipeline)

        let removed = await monitor.simulatePressureForTesting()
        let removedAgain = await monitor.simulatePressureForTesting()
        _ = try await pipeline.image(for: request)
        let requestCount = await transport.capturedRequests().count

        let purgeEvents = await diagnostics.snapshot().map(\.event).filter {
            $0.kind == .renderedMemoryPurged
        }
        let firstPurge = try XCTUnwrap(purgeEvents.first)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(removedAgain, 0)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(firstPurge.itemCount, 1)
        XCTAssertGreaterThan(firstPurge.byteCount ?? 0, firstPurge.itemCount ?? Int.max)
    }

    func testSystemCompositionDefaultsToPublicOnly_AUTH_PT_014() async throws {
        let root = try makeTemporaryDirectory("system-public-only")
        let system = try await FoveaSystemPipeline.open(cacheRoot: root)
        let request = try ImageRequest(
            url: try XCTUnwrap(URL(string: "https://127.0.0.1:1/private.png")),
            target: try TargetPixels(width: 20, height: 20),
            namespace: SecurityNamespaceID("account-a"),
            authorizationContext: .public,
            cachePolicy: .onlyIfCached
        )

        do {
            _ = try await system.pipeline.image(for: request)
            XCTFail("官方组合根默认必须拒绝私有 namespace")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .authorization)
            XCTAssertEqual(failure.reasonCode, "profile-access-denied")
        }
    }

    func testSystemCompositionAppliesDestinationPolicyBeforeCache_AUTH_PT_017() async throws {
        let root = try makeTemporaryDirectory("system-destination-policy")
        let allowedOrigin = try HTTPOrigin(
            url: XCTUnwrap(URL(string: "https://allowed.example.test/image.png"))
        )
        let destinationPolicy = try HTTPDestinationPolicy.allowOnly([allowedOrigin])
        let system = try await FoveaSystemPipeline.open(
            cacheRoot: root,
            transportPolicy: URLSessionTransportPolicy(destinationPolicy: destinationPolicy)
        )
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://denied.example.test/image.png")),
            target: TargetPixels(width: 20, height: 20),
            appID: "system-destination-policy",
            cachePolicy: .onlyIfCached
        )

        do {
            _ = try await system.pipeline.image(for: request)
            XCTFail(
                "Official composition must apply the same destination policy before cache lookup")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.reasonCode, "profile-access-denied")
            XCTAssertEqual(failure.stage, .requestValidation)
        }
    }

    func testSystemCompositionNormalizesInvalidNamespaceGenerationManifest_AUTH_PT_020()
        async throws
    {
        let root = try makeTemporaryDirectory("system-invalid-namespace-generation")
        var stores: FoveaPersistentStores? = try await FoveaPersistentStores.open(root: root)
        let generationRoot = try XCTUnwrap(stores?.generation.root)
        weak let releasedEncoded = stores?.encoded
        weak let releasedNamespaceStore = stores?.namespaceGenerations
        stores = nil
        try await waitUntil("persistent store actors 释放 writer lease") {
            releasedEncoded == nil && releasedNamespaceStore == nil
        }
        XCTAssertNil(releasedEncoded)
        XCTAssertNil(releasedNamespaceStore)

        let manifestRoot = generationRoot.appendingPathComponent(
            "namespace-generations",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: manifestRoot,
            withIntermediateDirectories: true
        )
        let manifestURL = manifestRoot.appendingPathComponent("namespace-generations.json")
        let original = Data(#"{"schemaVersion":999,"generations":{}}"#.utf8)
        try original.write(to: manifestURL, options: .atomic)

        do {
            _ = try await FoveaSystemPipeline.open(cacheRoot: root)
            XCTFail("The official composition root must fail closed on unknown revoke metadata")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.reasonCode, "namespace-generation-persistence-failed")
            XCTAssertEqual(failure.stage, .revocation)
            XCTAssertEqual(failure.disposition, .terminal)
        }
        XCTAssertEqual(try Data(contentsOf: manifestURL), original)
    }

    func testSafeCompositionRootCreatesSinglePersistentGeneration_PIPE_PT_009() async throws {
        let root = try makeTemporaryDirectory("system-pipeline")

        let first = try await FoveaSystemPipeline.open(cacheRoot: root)
        let second = try await FoveaSystemPipeline.open(cacheRoot: root)

        XCTAssertNotNil(UUID(uuidString: first.storageGenerationIdentifier))
        XCTAssertEqual(first.storageGenerationIdentifier, second.storageGenerationIdentifier)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("current-generation.json").path
            )
        )
    }
}
