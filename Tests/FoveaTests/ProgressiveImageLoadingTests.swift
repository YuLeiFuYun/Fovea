import AkashicCore
import AkashicDisk
import FoveaHTTP
import FoveaPersistence
import FoveaStorage
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

@_spi(FoveaBenchmarking) @testable import FoveaCore

final class ProgressiveImageLoadingTests: XCTestCase {

    func testResponseCompletionClosesUnobservedProgressiveFinalization_UI_PT_034() async {
        let finalization = PipelineProgressiveFinalization()

        let candidate = await finalization.valueAfterResponseCompletion()

        XCTAssertNil(candidate)
        let completedCandidate = await finalization.completedCandidate()
        XCTAssertNil(completedCandidate)
    }

    func testDefaultImageMethodReturnsFinalEventAfterPreviews() async throws {
        let preview = try testDecodedImage(width: 10, height: 10)
        let final = try testDecodedImage(width: 20, height: 20)
        let loader = EventSequenceLoader(events: [
            .preview(preview, quality: 250),
            .final(final),
        ])

        let image = try await loader.image(for: try testRequest())

        XCTAssertEqual(image.pixelWidth, 20)
        XCTAssertEqual(image.pixelHeight, 20)
    }

    func testDefaultImageMethodFailsWhenStreamEndsWithoutFinal() async throws {
        let preview = try testDecodedImage(width: 10, height: 10)
        let loader = EventSequenceLoader(events: [.preview(preview, quality: 250)])

        do {
            _ = try await loader.image(for: try testRequest())
            XCTFail("A progressive stream without a final image must fail")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure, .incompleteProgressiveStream)
        }
    }

    func testDifferentTargetsShareProgressiveFetchAndNonOwnerFallsBack_UI_PT_035()
        async throws
    {
        let root = try makeTemporaryDirectory("w11-progressive-multi-target")
        let fixture = try BenchmarkFixtureCatalog.load(
            named: "progressive-people-usda-meeting-1920x1280.jpg"
        )
        let transport = SharedProgressiveJPEGTransport(body: fixture.data)
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")
            ),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")
            ),
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let url = try XCTUnwrap(
            URL(string: "https://example.test/w11-progressive-multi-target.jpg")
        )
        let small = try ImageRequest.publicImage(
            url: url,
            target: TargetPixels(width: 320, height: 320),
            appID: "progressive-loader-tests"
        )
        let large = try ImageRequest.publicImage(
            url: url,
            target: TargetPixels(width: 768, height: 768),
            appID: "progressive-loader-tests"
        )
        let owner = PipelineEventRecorder()
        let nonOwner = PipelineEventRecorder()
        let ownerOutcome = PipelineEventTaskOutcomeRecorder()
        let nonOwnerOutcome = PipelineEventTaskOutcomeRecorder()
        let ownerDone = expectation(description: "W11 progressive owner completes")
        let nonOwnerDone = expectation(description: "W11 progressive non-owner completes")
        let ownerTask = Task {
            defer { ownerDone.fulfill() }
            do {
                for try await event in pipeline.events(for: small) {
                    await owner.record(event)
                }
                await ownerOutcome.record(.success)
            } catch let failure as PipelineFailure {
                await ownerOutcome.record(.failure(failure))
            } catch is CancellationError {
                await ownerOutcome.record(.cancellation)
            } catch {
                await ownerOutcome.record(.other(String(describing: error)))
            }
        }
        defer {
            ownerTask.cancel()
            Task { await transport.releaseRemainingBytes() }
        }

        try await waitUntil("W11 owner observes progressive transport bytes") {
            await owner.snapshot().previewCount > 0
        }
        let nonOwnerTask = Task {
            defer { nonOwnerDone.fulfill() }
            do {
                for try await event in pipeline.events(for: large) {
                    await nonOwner.record(event)
                }
                await nonOwnerOutcome.record(.success)
            } catch let failure as PipelineFailure {
                await nonOwnerOutcome.record(.failure(failure))
            } catch is CancellationError {
                await nonOwnerOutcome.record(.cancellation)
            } catch {
                await nonOwnerOutcome.record(.other(String(describing: error)))
            }
        }
        defer { nonOwnerTask.cancel() }
        try await waitUntil("W11 different targets share one encoded fetch") {
            let requestCount = await transport.requestCount
            let subscriberCount = await pipeline.fetchSubscriberCountForTesting(small)
            return requestCount == 1 && subscriberCount == 2
        }

        await transport.releaseRemainingBytes()
        await fulfillment(of: [ownerDone, nonOwnerDone], timeout: 3)

        let ownerSnapshot = await owner.snapshot()
        let nonOwnerSnapshot = await nonOwner.snapshot()
        XCTAssertEqual(ownerSnapshot.finalCount, 1)
        XCTAssertEqual(nonOwnerSnapshot.finalCount, 1)
        XCTAssertEqual(ownerSnapshot.finalImage?.pixelWidth, 320)
        XCTAssertEqual(nonOwnerSnapshot.finalImage?.pixelWidth, 768)
        let requestCount = await transport.requestCount
        let ownerResult = await ownerOutcome.snapshot()
        let nonOwnerResult = await nonOwnerOutcome.snapshot()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(ownerResult, .success)
        XCTAssertEqual(nonOwnerResult, .success)
    }

    func testDifferentTargetProgressiveOwnerCancellationStress_UI_PT_036() async throws {
        let root = try makeTemporaryDirectory("w11-progressive-owner-cancel-stress")
        let fixture = try BenchmarkFixtureCatalog.load(
            named: "progressive-people-usda-meeting-1920x1280.jpg"
        )
        let transport = SharedProgressiveJPEGTransport(body: fixture.data)
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")
            ),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")
            ),
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )

        for round in 0..<12 {
            await transport.prepareNextRequestGate()
            let url = try XCTUnwrap(
                URL(string: "https://example.test/w11-cancel-\(round).jpg")
            )
            let ownerRequest = try ImageRequest.publicImage(
                url: url,
                target: TargetPixels(width: 320, height: 320),
                appID: "progressive-loader-tests"
            )
            let survivorRequest = try ImageRequest.publicImage(
                url: url,
                target: TargetPixels(width: 768, height: 768),
                appID: "progressive-loader-tests"
            )
            let owner = PipelineEventRecorder()
            let survivor = PipelineEventRecorder()
            let ownerOutcome = PipelineEventTaskOutcomeRecorder()
            let survivorOutcome = PipelineEventTaskOutcomeRecorder()
            let ownerDone = expectation(description: "W11 cancelled owner round \(round)")
            let survivorDone = expectation(description: "W11 survivor round \(round)")
            let ownerTask = Task {
                defer { ownerDone.fulfill() }
                do {
                    for try await event in pipeline.events(for: ownerRequest) {
                        await owner.record(event)
                    }
                    await ownerOutcome.record(.success)
                } catch let failure as PipelineFailure {
                    await ownerOutcome.record(.failure(failure))
                } catch is CancellationError {
                    await ownerOutcome.record(.cancellation)
                } catch {
                    await ownerOutcome.record(.other(String(describing: error)))
                }
            }

            try await waitUntil("W11 cancellation owner observes progress round \(round)") {
                await owner.snapshot().previewCount > 0
            }
            let survivorTask = Task {
                defer { survivorDone.fulfill() }
                do {
                    for try await event in pipeline.events(for: survivorRequest) {
                        await survivor.record(event)
                    }
                    await survivorOutcome.record(.success)
                } catch let failure as PipelineFailure {
                    await survivorOutcome.record(.failure(failure))
                } catch is CancellationError {
                    await survivorOutcome.record(.cancellation)
                } catch {
                    await survivorOutcome.record(.other(String(describing: error)))
                }
            }
            try await waitUntil("W11 cancellation targets share fetch round \(round)") {
                let requestCount = await transport.requestCount
                let subscriberCount = await pipeline.fetchSubscriberCountForTesting(ownerRequest)
                return requestCount == round + 1 && subscriberCount == 2
            }

            ownerTask.cancel()
            await transport.releaseRemainingBytes()
            await fulfillment(of: [ownerDone, survivorDone], timeout: 3)

            let survivorResult = await survivorOutcome.snapshot()
            let ownerSnapshot = await owner.snapshot()
            let survivorSnapshot = await survivor.snapshot()
            let requestCount = await transport.requestCount
            XCTAssertEqual(ownerSnapshot.finalCount, 0)
            XCTAssertEqual(survivorResult, .success)
            XCTAssertEqual(survivorSnapshot.finalCount, 1)
            XCTAssertEqual(survivorSnapshot.finalImage?.pixelWidth, 768)
            XCTAssertEqual(requestCount, round + 1)
            survivorTask.cancel()
        }
    }

    func testDifferentTargetProgressiveNamespaceRevokeStress_UI_PT_037() async throws {
        let root = try makeTemporaryDirectory("w11-progressive-revoke-stress")
        let fixture = try BenchmarkFixtureCatalog.load(
            named: "progressive-people-usda-meeting-1920x1280.jpg"
        )

        for round in 0..<12 {
            let roundRoot = root.appendingPathComponent("round-\(round)")
            let transport = SharedProgressiveJPEGTransport(
                body: fixture.data,
                cacheControl: "max-age=3600"
            )
            let registry = NamespaceRegistry()
            let records = try await RepresentationRecordStore.open(
                root: roundRoot.appendingPathComponent("records")
            )
            let barrierRecords = ProgressiveCleanupBarrierRecordStore(base: records)
            let pipeline = FoveaPipeline(
                transport: transport,
                encodedStore: try await AkashicOriginalEncodedStore.open(
                    root: roundRoot.appendingPathComponent("encoded")
                ),
                recordStore: barrierRecords,
                namespaceRegistry: registry,
                profileAccessPolicy: .unrestricted,
                codec: ImageIOImageDecoder()
            )
            let namespace = SecurityNamespaceID("w11-revoke-\(round)")
            let url = try XCTUnwrap(
                URL(string: "https://example.test/w11-revoke-\(round).jpg")
            )
            let ownerRequest = try ImageRequest(
                url: url,
                target: TargetPixels(width: 320, height: 320),
                namespace: namespace,
                authorizationContext: AuthorizationContextID("w11-principal-\(round)")
            )
            let nonOwnerRequest = try ImageRequest(
                url: url,
                target: TargetPixels(width: 768, height: 768),
                namespace: namespace,
                authorizationContext: AuthorizationContextID("w11-principal-\(round)")
            )
            let owner = PipelineEventRecorder()
            let nonOwner = PipelineEventRecorder()
            let ownerOutcome = PipelineEventTaskOutcomeRecorder()
            let nonOwnerOutcome = PipelineEventTaskOutcomeRecorder()
            let revokeOutcome = PipelineEventTaskOutcomeRecorder()
            let ownerDone = expectation(description: "W11 revoke owner round \(round)")
            let nonOwnerDone = expectation(description: "W11 revoke non-owner round \(round)")
            let revokeDone = expectation(description: "W11 revoke completes round \(round)")
            let ownerTask = Task {
                defer { ownerDone.fulfill() }
                do {
                    for try await event in pipeline.events(for: ownerRequest) {
                        await owner.record(event)
                    }
                    await ownerOutcome.record(.success)
                } catch let failure as PipelineFailure {
                    await ownerOutcome.record(.failure(failure))
                } catch is CancellationError {
                    await ownerOutcome.record(.cancellation)
                } catch {
                    await ownerOutcome.record(.other(String(describing: error)))
                }
            }
            try await waitUntil("W11 revoke owner observes progress round \(round)") {
                await owner.snapshot().previewCount > 0
            }
            let nonOwnerTask = Task {
                defer { nonOwnerDone.fulfill() }
                do {
                    for try await event in pipeline.events(for: nonOwnerRequest) {
                        await nonOwner.record(event)
                    }
                    await nonOwnerOutcome.record(.success)
                } catch let failure as PipelineFailure {
                    await nonOwnerOutcome.record(.failure(failure))
                } catch is CancellationError {
                    await nonOwnerOutcome.record(.cancellation)
                } catch {
                    await nonOwnerOutcome.record(.other(String(describing: error)))
                }
            }
            try await waitUntil("W11 revoke targets share fetch round \(round)") {
                let requestCount = await transport.requestCount
                let subscriberCount = await pipeline.fetchSubscriberCountForTesting(ownerRequest)
                return requestCount == 1 && subscriberCount == 2
            }

            let revokeTask = Task {
                defer { revokeDone.fulfill() }
                do {
                    try await pipeline.revoke(namespace: namespace)
                    await revokeOutcome.record(.success)
                } catch let failure as PipelineFailure {
                    await revokeOutcome.record(.failure(failure))
                } catch is CancellationError {
                    await revokeOutcome.record(.cancellation)
                } catch {
                    await revokeOutcome.record(.other(String(describing: error)))
                }
            }
            await barrierRecords.waitUntilCleanupStarts()

            do {
                _ = try await registry.generation(for: namespace)
                XCTFail("W11 revocation barrier must reject old-generation work")
            } catch let failure as PipelineFailure {
                XCTAssertEqual(failure.category, .namespaceRevoked)
            }
            await transport.releaseRemainingBytes()
            await barrierRecords.releaseCleanup()
            await fulfillment(of: [ownerDone, nonOwnerDone, revokeDone], timeout: 3)

            let revokeResult = await revokeOutcome.snapshot()
            let ownerSnapshot = await owner.snapshot()
            let nonOwnerSnapshot = await nonOwner.snapshot()
            let requestCount = await transport.requestCount
            let generation = try await registry.generation(for: namespace)
            let oldRecords = await records.records(
                for: ownerRequest.fetchBaseKey.digestHex,
                namespace: namespace.value,
                namespaceGeneration: 0
            )
            XCTAssertEqual(revokeResult, .success)
            XCTAssertEqual(ownerSnapshot.finalCount, 0)
            XCTAssertEqual(nonOwnerSnapshot.finalCount, 0)
            XCTAssertEqual(requestCount, 1)
            XCTAssertEqual(generation, NamespaceGeneration(1))
            XCTAssertTrue(oldRecords.isEmpty)
            ownerTask.cancel()
            nonOwnerTask.cancel()
            revokeTask.cancel()
        }
    }

    func testConcurrentSubscribersShareOneProgressiveSessionAndReplayLatest_UI_PT_031()
        async throws
    {
        let root = try makeTemporaryDirectory("shared-progressive-session")
        let fixture = try BenchmarkFixtureCatalog.load(
            named: "progressive-people-usda-meeting-1920x1280.jpg"
        )
        let transport = SharedProgressiveJPEGTransport(body: fixture.data)
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded")
        )
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/shared-progressive.jpg")),
            target: TargetPixels(width: 512, height: 512),
            appID: "progressive-loader-tests"
        )
        let first = ProgressiveSequenceRecorder()
        let second = ProgressiveSequenceRecorder()
        let firstTask = Task {
            for try await event in pipeline.events(for: request) {
                await first.record(event)
            }
        }
        defer {
            firstTask.cancel()
            Task { await transport.releaseRemainingBytes() }
        }

        try await waitUntil("first subscriber receives the first network preview") {
            await first.networkPreviewQualities.count == 1
        }
        let secondTask = Task {
            for try await event in pipeline.events(for: request) {
                await second.record(event)
            }
        }
        defer { secondTask.cancel() }
        try await waitUntil("late subscriber replays the latest shared preview") {
            await second.networkPreviewQualities.count == 1
        }
        try await waitUntil("both subscribers join one fetch execution") {
            await pipeline.fetchSubscriberCountForTesting(request) == 2
        }
        let firstAtJoin = await first.snapshot()
        let secondAtJoin = await second.snapshot()
        XCTAssertEqual(firstAtJoin.networkPreviewQualities, [1])
        XCTAssertEqual(secondAtJoin.networkPreviewQualities, [1])

        await transport.releaseRemainingBytes()
        try await firstTask.value
        try await secondTask.value

        let firstSnapshot = await first.snapshot()
        let secondSnapshot = await second.snapshot()
        let requestCount = await transport.requestCount
        let producerStarts = await pipeline.progressiveProducerStartCountForTesting()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(producerStarts, 1)
        // 每个订阅者使用 bufferingNewest(1)：慢消费者允许合并中间 generation，
        // 但已观察的质量必须非空、严格递增且来自同一四代 producer。
        for qualities in [
            firstSnapshot.networkPreviewQualities,
            secondSnapshot.networkPreviewQualities,
        ] {
            XCTAssertFalse(qualities.isEmpty)
            XCTAssertEqual(qualities.first, 1)
            XCTAssertTrue(qualities.allSatisfy { (1...4).contains($0) })
            XCTAssertTrue(
                zip(qualities, qualities.dropFirst()).allSatisfy { previous, next in
                    previous < next
                }
            )
        }
        XCTAssertEqual(firstSnapshot.fullQualityPreviewCount, 0)
        XCTAssertEqual(secondSnapshot.fullQualityPreviewCount, 0)
        XCTAssertEqual(firstSnapshot.finalCount, 1)
        XCTAssertEqual(secondSnapshot.finalCount, 1)
    }

    func testProgressivePreparationReusesDecodeAdmission_UI_PT_032()
        async throws
    {
        let result = try await runPreparedFinalizationScenario(completionDigestOverride: nil)

        XCTAssertEqual(result.fallbackPrepared, 0)
        XCTAssertEqual(result.progressiveDecoded, 1)
        XCTAssertEqual(result.fallbackDecoded, 0)
        XCTAssertEqual(result.progressiveDiscarded, 0)
    }

    func testMismatchedProgressiveDigestDiscardsCandidateAndFallsBack_UI_PT_033() async throws {
        let result = try await runPreparedFinalizationScenario(
            completionDigestOverride: String(repeating: "0", count: 64)
        )

        XCTAssertEqual(result.fallbackPrepared, 1)
        XCTAssertEqual(result.progressiveDecoded, 0)
        XCTAssertEqual(result.fallbackDecoded, 1)
        XCTAssertEqual(result.progressiveDiscarded, 1)
    }

    private func runPreparedFinalizationScenario(
        completionDigestOverride: String?
    ) async throws -> PreparedProgressiveCodec.Snapshot {
        let root = try makeTemporaryDirectory("prepared-progressive-finalization")
        let fixture = try BenchmarkFixtureCatalog.load(
            named: "progressive-people-usda-meeting-1920x1280.jpg"
        )
        let transport = SharedProgressiveJPEGTransport(
            body: fixture.data,
            completionDigestOverride: completionDigestOverride
        )
        let codec = PreparedProgressiveCodec()
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")
            ),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")
            ),
            profileAccessPolicy: .unrestricted,
            codec: codec
        )
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/prepared-progressive.jpg")),
            target: TargetPixels(width: 32, height: 32),
            appID: "progressive-loader-tests"
        )
        let consumer = Task {
            for try await _ in pipeline.events(for: request) {}
        }
        defer { consumer.cancel() }
        try await waitUntil("prepared finalization request starts") {
            await transport.requestCount == 1
        }
        await transport.releaseRemainingBytes()
        try await consumer.value
        return codec.snapshot()
    }

    func testFoveaPipelinePublishesFullQualityPreviewBeforeDurableFinal_UI_PT_024_CACHE_PT_042()
        async throws
    {
        let root = try makeTemporaryDirectory("pipeline-full-quality-preview")
        let body = try makePNG(width: 96, height: 64)
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: body
            )
        ])
        let baseStore = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded")
        )
        let commitBarrier = CommitBarrierEncodedStore(base: baseStore)
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: commitBarrier,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/full-quality-preview.png")),
            target: TargetPixels(width: 48, height: 32),
            appID: "progressive-loader-tests"
        )
        let recorder = PipelineEventRecorder()
        let consumer = Task {
            for try await event in pipeline.events(for: request) {
                await recorder.record(event)
            }
        }

        await commitBarrier.waitUntilCommitStarts()
        try await waitUntil("durable commit 完成前发布完整像素 preview") {
            await recorder.previewCount == 1
        }
        let finalCountBeforeCommit = await recorder.finalCount
        let previewImage = await recorder.previewImage
        let previewQuality = await recorder.previewQuality
        XCTAssertEqual(finalCountBeforeCommit, 0)
        let preview = try XCTUnwrap(previewImage)
        XCTAssertEqual(preview.pixelWidth, 48)
        XCTAssertEqual(preview.pixelHeight, 32)
        XCTAssertEqual(previewQuality, UInt16.max)

        await commitBarrier.releaseCommit()
        try await consumer.value
        let finalCountAfterCommit = await recorder.finalCount
        let finalImage = await recorder.finalImage
        XCTAssertEqual(finalCountAfterCommit, 1)
        let final = try XCTUnwrap(finalImage)
        XCTAssertEqual(final.pixelWidth, preview.pixelWidth)
        XCTAssertEqual(final.pixelHeight, preview.pixelHeight)
    }

    func testFullQualityPreviewDoesNotWaitForOriginalStaging_UI_PT_025_CACHE_PT_043()
        async throws
    {
        let root = try makeTemporaryDirectory("pipeline-stage-preview")
        let body = try makePNG(width: 96, height: 64)
        let baseStore = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded")
        )
        let stageBarrier = StageBarrierEncodedStore(base: baseStore)
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let pipeline = FoveaPipeline(
            transport: FakeHTTPTransport(stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                    body: body
                )
            ]),
            encodedStore: stageBarrier,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/stage-preview.png")),
            target: TargetPixels(width: 48, height: 32),
            appID: "progressive-loader-tests"
        )
        let recorder = PipelineEventRecorder()
        let consumer = Task {
            for try await event in pipeline.events(for: request) {
                await recorder.record(event)
            }
        }

        await stageBarrier.waitUntilStageStarts()
        try await waitUntil("原编码 staging 阻塞时仍发布完整像素 preview") {
            await recorder.previewCount == 1
        }
        let beforeRelease = await recorder.snapshot()
        XCTAssertEqual(beforeRelease.finalCount, 0)
        XCTAssertEqual(beforeRelease.previewQuality, UInt16.max)
        XCTAssertEqual(beforeRelease.previewImage?.pixelWidth, 48)
        let physicalIDBeforeRelease = await baseStore.physicalID(
            contentID: ContentID(data: body).description,
            namespace: request.namespace.value
        )
        XCTAssertNil(physicalIDBeforeRelease)

        await stageBarrier.releaseStage()
        try await consumer.value
        let afterRelease = await recorder.snapshot()
        let physicalIDAfterRelease = await baseStore.physicalID(
            contentID: ContentID(data: body).description,
            namespace: request.namespace.value
        )
        XCTAssertEqual(afterRelease.finalCount, 1)
        XCTAssertNotNil(physicalIDAfterRelease)
    }

    func testRapidCancellationWarmupDefersDurabilityUntilVisibleConsumer_UI_PT_027_CACHE_PT_044()
        async throws
    {
        let root = try makeTemporaryDirectory("adaptive-warmup")
        let body = try makePNG(width: 96, height: 64)
        let transport = FakeHTTPTransport(
            // 三次前台尝试各自只有一次 transport。取消预热必须在 fetch 交接租约内
            // 加入原 single-flight，不得为第二、第三次取消另起 replacement 请求。
            stubs: (0..<3).map { _ in
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                    body: body,
                    delayNanoseconds: 50_000_000
                )
            })
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded")
        )
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let logicalSource = LogicalSourceID("adaptive-warmup-shared-source")
        let requests = try (0..<3).map { index in
            try ImageRequest.publicImage(
                url: XCTUnwrap(URL(string: "https://example.test/warmup-\(index).png")),
                logicalSource: logicalSource,
                target: TargetPixels(width: 48, height: 32),
                appID: "progressive-loader-tests"
            )
        }

        for request in requests {
            let consumer = Task {
                for try await _ in pipeline.events(for: request) {}
            }
            try await Task.sleep(nanoseconds: 5_000_000)
            consumer.cancel()
            _ = await consumer.result
        }

        let finalRequest = requests[2]
        try await waitUntil("最终请求的安全预热 handoff 已发布") {
            await pipeline.hasTransportVerifiedHandoffForTesting(finalRequest)
        }
        let capturedBeforeVisible = await transport.capturedRequests()
        XCTAssertEqual(
            capturedBeforeVisible.count,
            3,
            "取消预热必须复用每次前台请求的原 single-flight，不得额外重取"
        )
        let recordsBeforeVisible = await records.records(
            for: finalRequest.fetchBaseKey.digestHex,
            namespace: finalRequest.namespace.value,
            namespaceGeneration: 0
        )
        XCTAssertTrue(recordsBeforeVisible.isEmpty)

        var events: [ImageLoadingEvent] = []
        for try await event in pipeline.events(for: finalRequest) { events.append(event) }

        let captured = await transport.capturedRequests()
        let recordsAfterVisible = await records.records(
            for: finalRequest.fetchBaseKey.digestHex,
            namespace: finalRequest.namespace.value,
            namespaceGeneration: 0
        )
        let physicalID = await encoded.physicalID(
            contentID: ContentID(data: body).description,
            namespace: finalRequest.namespace.value
        )
        XCTAssertEqual(
            captured.map(\.url),
            capturedBeforeVisible.map(\.url),
            "可见消费者必须复用 exact handoff，不得新增 transport 请求"
        )
        XCTAssertEqual(events.count, 2)
        if case .preview(_, let quality) = events[0] {
            XCTAssertEqual(quality, UInt16.max)
        } else {
            XCTFail("最终存活消费者必须先收到完整质量 preview")
        }
        if case .final = events[1] {
        } else {
            XCTFail("耐久提交后必须发布 final")
        }
        XCTAssertEqual(recordsAfterVisible.count, 1)
        XCTAssertNotNil(physicalID)
    }

    func testRepeatedOriginalWarmupReusesTransportVerifiedHandoffWithoutRefetch_CACHE_PT_045()
        async throws
    {
        let root = try makeTemporaryDirectory("repeated-adaptive-warmup")
        let body = try makePNG(width: 96, height: 64)
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: body
            )
        ])
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded")
        )
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/repeated-warmup.png")),
            target: TargetPixels(width: 48, height: 32),
            appID: "progressive-loader-tests"
        )

        try await pipeline.warmOriginalForTesting(request)
        try await pipeline.warmOriginalForTesting(request)

        let captured = await transport.capturedRequests()
        let persistentRecords = await records.records(
            for: request.fetchBaseKey.digestHex,
            namespace: request.namespace.value,
            namespaceGeneration: 0
        )
        let physicalID = await encoded.physicalID(
            contentID: ContentID(data: body).description,
            namespace: request.namespace.value
        )
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(persistentRecords.isEmpty)
        XCTAssertNil(physicalID)
    }

    func testBenchmarkMemoryPurgeRemovesTransportVerifiedHandoff_CACHE_PT_047() async throws {
        let root = try makeTemporaryDirectory("benchmark-memory-purge-handoff")
        let body = try makePNG(width: 96, height: 64)
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: body
            )
        ])
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded")
        )
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/benchmark-memory-purge.png")),
            target: TargetPixels(width: 48, height: 32),
            appID: "progressive-loader-tests"
        )

        try await pipeline.warmOriginalForTesting(request)
        let handoffBeforePurge = await pipeline.hasTransportVerifiedHandoffForTesting(request)
        XCTAssertTrue(handoffBeforePurge)

        await pipeline.purgeMemoryStateForBenchmarking()

        let handoffAfterPurge = await pipeline.hasTransportVerifiedHandoffForTesting(request)
        XCTAssertFalse(handoffAfterPurge)
    }

    func testMalformedTransportVerifiedHandoffCannotPersistAndIsRemoved_CACHE_PT_046()
        async throws
    {
        let root = try makeTemporaryDirectory("malformed-transport-handoff")
        let malformed = Data("not-an-image".utf8)
        let valid = try makePNG(width: 96, height: 64)
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: malformed
            ),
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: valid
            ),
        ])
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded")
        )
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/malformed-handoff.png")),
            target: TargetPixels(width: 48, height: 32),
            appID: "progressive-loader-tests"
        )

        // 传输层完整性足以进入 transient handoff，但尚未获得图像合法性证明。
        try await pipeline.warmOriginalForTesting(request)
        let capturedAfterWarmup = await transport.capturedRequests()
        XCTAssertEqual(capturedAfterWarmup.count, 1)

        do {
            _ = try await pipeline.image(for: request)
            XCTFail("畸形 transport-verified handoff 不得跨过图像验证边界")
        } catch let failure as PipelineFailure {
            XCTAssertTrue(failure.stage == .probe || failure.stage == .decode)
        }
        let recordsAfterFailure = await records.records(
            for: request.fetchBaseKey.digestHex,
            namespace: request.namespace.value,
            namespaceGeneration: 0
        )
        let malformedPhysicalID = await encoded.physicalID(
            contentID: ContentID(data: malformed).description,
            namespace: request.namespace.value
        )
        XCTAssertTrue(recordsAfterFailure.isEmpty)
        XCTAssertNil(malformedPhysicalID)

        // 失败必须删除 handoff；下一次消费者重新回源，并只持久化通过完整图像门禁的字节。
        let image = try await pipeline.image(for: request)
        let capturedAfterRecovery = await transport.capturedRequests()
        let recordsAfterRecovery = await records.records(
            for: request.fetchBaseKey.digestHex,
            namespace: request.namespace.value,
            namespaceGeneration: 0
        )
        let validPhysicalID = await encoded.physicalID(
            contentID: ContentID(data: valid).description,
            namespace: request.namespace.value
        )
        XCTAssertEqual(image.pixelWidth, 48)
        XCTAssertEqual(capturedAfterRecovery.count, 2)
        XCTAssertEqual(recordsAfterRecovery.count, 1)
        XCTAssertNotNil(validPhysicalID)
    }

    func testRefreshingLoaderPreservesProgressiveEventsAcross401_AUTH_PT_013() async throws {
        let preview = try testDecodedImage(width: 10, height: 10)
        let final = try testDecodedImage(width: 20, height: 20)
        let state = ProgressiveAuthenticationState()
        let refresher = ProgressiveCredentialRefresher()
        let loader = RefreshingImageLoader(
            base: AuthenticationAwareProgressiveLoader(
                state: state,
                preview: preview,
                final: final
            ),
            refresher: refresher
        )
        let request = try ImageRequest(
            url: XCTUnwrap(URL(string: "https://example.test/private-progressive.png")),
            target: TargetPixels(width: 20, height: 20),
            namespace: SecurityNamespaceID("progressive-account"),
            authorizationContext: AuthorizationContextID("progressive-principal"),
            credentialGeneration: CredentialGeneration(1),
            headers: ["Authorization": "Bearer expired"]
        )

        var events: [ImageLoadingEvent] = []
        for try await event in loader.events(for: request) { events.append(event) }

        let generations = await state.generations
        let refreshCount = await refresher.refreshCount
        XCTAssertEqual(events.count, 2)
        if case .preview(let image, let quality) = events[0] {
            XCTAssertEqual(image.pixelWidth, 10)
            XCTAssertEqual(quality, 500)
        } else {
            XCTFail("Expected a progressive preview after credential replay")
        }
        if case .final(let image) = events[1] {
            XCTAssertEqual(image.pixelWidth, 20)
        } else {
            XCTFail("Expected a final image after credential replay")
        }
        XCTAssertEqual(generations, [1, 2])
        XCTAssertEqual(refreshCount, 1)
    }

    private func testRequest() throws -> ImageRequest {
        try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/progressive.png")),
            target: TargetPixels(width: 20, height: 20),
            appID: "progressive-loader-tests"
        )
    }
}

private struct EventSequenceLoader: ProgressiveImageLoading {
    let events: [ImageLoadingEvent]

    func events(
        for request: ImageRequest
    ) -> AsyncThrowingStream<ImageLoadingEvent, any Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private func testDecodedImage(width: Int, height: Int) throws -> DecodedImage {
    try ImageIOImageDecoder().decode(
        data: makePNG(width: width, height: height),
        target: TargetPixels(width: width, height: height)
    )
}

private actor ProgressiveAuthenticationState {
    private(set) var generations: [UInt64] = []

    func record(_ generation: UInt64) {
        generations.append(generation)
    }
}

private struct AuthenticationAwareProgressiveLoader: ProgressiveImageLoading {
    let state: ProgressiveAuthenticationState
    let preview: DecodedImage
    let final: DecodedImage

    func events(
        for request: ImageRequest
    ) -> AsyncThrowingStream<ImageLoadingEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let generation = request.credentialGeneration?.value ?? 0
                await state.record(generation)
                if generation == 1 {
                    continuation.finish(
                        throwing: PipelineFailure(
                            category: .http,
                            stage: .responseValidation,
                            disposition: .terminal,
                            reasonCode: "unauthorized",
                            statusCode: 401
                        )
                    )
                    return
                }
                continuation.yield(.preview(preview, quality: 500))
                continuation.yield(.final(final))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor ProgressiveCredentialRefresher: CredentialRefreshing {
    private(set) var refreshCount = 0

    func refreshCredentials(
        namespace: SecurityNamespaceID,
        authorizationContext: AuthorizationContextID,
        currentGeneration: CredentialGeneration
    ) async throws -> CredentialRefreshResult {
        refreshCount += 1
        return CredentialRefreshResult(
            credentialGeneration: CredentialGeneration(currentGeneration.value + 1),
            headers: ["Authorization": "Bearer refreshed"]
        )
    }
}

private actor StageBarrierEncodedStore: OriginalEncodedTransactionalStoring {
    private let base: AkashicOriginalEncodedStore
    private var stageStarted = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(base: AkashicOriginalEncodedStore) {
        self.base = base
    }

    func read(contentID: String, namespace: String) async throws -> Data {
        try await base.read(contentID: contentID, namespace: namespace)
    }

    func commit(data: Data, contentID: String, namespace: String) async throws -> StoredBlob {
        try await base.commit(data: data, contentID: contentID, namespace: namespace)
    }

    func physicalID(contentID: String, namespace: String) async -> PhysicalBlobID? {
        await base.physicalID(contentID: contentID, namespace: namespace)
    }

    func remove(contentID: String, namespace: String) async throws {
        try await base.remove(contentID: contentID, namespace: namespace)
    }

    func removeAll(namespace: String) async throws {
        try await base.removeAll(namespace: namespace)
    }

    func stage(
        data: Data,
        contentID: String,
        namespace: String
    ) async throws -> OriginalEncodedStage {
        stageStarted = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }
        try Task.checkCancellation()
        return try await base.stage(data: data, contentID: contentID, namespace: namespace)
    }

    func publish(_ stage: OriginalEncodedStage) async throws -> StoredBlob {
        try await base.publish(stage)
    }

    func discard(_ stage: OriginalEncodedStage) async {
        await base.discard(stage)
    }

    func waitUntilStageStarts() async {
        if stageStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseStage() {
        guard !released else { return }
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor ProgressiveSequenceRecorder {
    struct Snapshot: Sendable {
        let networkPreviewQualities: [UInt16]
        let fullQualityPreviewCount: Int
        let finalCount: Int
    }

    private(set) var networkPreviewQualities: [UInt16] = []
    private var fullQualityPreviewCount = 0
    private var finalCount = 0

    func record(_ event: ImageLoadingEvent) {
        switch event {
        case .preview(_, let quality) where quality < UInt16.max:
            networkPreviewQualities.append(quality)
        case .preview:
            fullQualityPreviewCount += 1
        case .final:
            finalCount += 1
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            networkPreviewQualities: networkPreviewQualities,
            fullQualityPreviewCount: fullQualityPreviewCount,
            finalCount: finalCount
        )
    }
}

private final class PreparedProgressiveCodec:
    ImageCodec, PreparedImageDecoding, ProgressiveImageDecoding, @unchecked Sendable
{
    struct Snapshot: Equatable {
        let fallbackPrepared: Int
        let progressiveDecoded: Int
        let fallbackDecoded: Int
        let progressiveDiscarded: Int
    }

    private enum TokenKind {
        case progressive
        case fallback
    }

    let codecDescriptor = ImageCodecDescriptor(
        identifier: ImageCodecIdentifier(rawValue: "test.prepared-progressive"),
        implementationVersion: 1,
        capabilities: ImageCodecCapabilities(
            formats: [.jpeg],
            deliveryModes: [.completeFrame, .progressiveGenerations],
            progressiveFormats: [.jpeg],
            trackModes: [.primaryFrame],
            metadata: [.orientation, .sourceColorProfile],
            dynamicRanges: [.standard],
            outputRepresentations: [.coreGraphicsImage],
            cancellationMode: .operationBoundary
        )
    )

    private let lock = NSLock()
    private var tokens: [UUID: TokenKind] = [:]
    private var fallbackPrepared = 0
    private var progressiveDecoded = 0
    private var fallbackDecoded = 0
    private var progressiveDiscarded = 0

    func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
        try Self.probe()
    }

    func decode(
        data: Data,
        probe: ImageProbe,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        lock.withLock { fallbackDecoded += 1 }
        return try testDecodedImage(
            width: request.target.width,
            height: request.target.height
        )
    }

    func prepare(data: Data, limits: DecodeLimits) throws -> ImageDecodePreparation {
        let preparation = ImageDecodePreparation(probe: try Self.probe())
        lock.withLock {
            fallbackPrepared += 1
            tokens[preparation.identifier] = .fallback
        }
        return preparation
    }

    func decode(
        preparation: ImageDecodePreparation,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        let kind = lock.withLock { tokens.removeValue(forKey: preparation.identifier) }
        guard let kind else { throw ImageCraftError.probeMismatch }
        lock.withLock {
            switch kind {
            case .progressive: progressiveDecoded += 1
            case .fallback: fallbackDecoded += 1
            }
        }
        return try testDecodedImage(
            width: request.target.width,
            height: request.target.height
        )
    }

    func discard(_ preparation: ImageDecodePreparation) {
        let kind = lock.withLock { tokens.removeValue(forKey: preparation.identifier) }
        if kind == .progressive { lock.withLock { progressiveDiscarded += 1 } }
    }

    func makeProgressiveSession(
        format: EncodedImageFormat,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> any ImageProgressiveDecodeSession {
        guard format == .jpeg else { throw ImageCraftError.progressiveDecodingUnsupported }
        return Session(codec: self)
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                fallbackPrepared: fallbackPrepared,
                progressiveDecoded: progressiveDecoded,
                fallbackDecoded: fallbackDecoded,
                progressiveDiscarded: progressiveDiscarded
            )
        }
    }

    private func progressivePreparation(byteCount: Int) throws
        -> ImageProgressiveDecodePreparationFinalization
    {
        let preparation = ImageDecodePreparation(probe: try Self.probe())
        lock.withLock { tokens[preparation.identifier] = .progressive }
        return ImageProgressiveDecodePreparationFinalization(
            preparation: preparation,
            sourceByteCount: byteCount
        )
    }

    private static func probe() throws -> ImageProbe {
        try ImageProbe(
            pixelWidth: 64,
            pixelHeight: 64,
            frameCount: 1,
            orientation: 1,
            format: .jpeg,
            metadataByteCount: 0,
            auxiliaryAttachmentCount: 0,
            sourceColorProfile: .standardSRGB
        )
    }

    private final class Session: ProgressiveImagePreparingSession, @unchecked Sendable {
        private let lock = NSLock()
        private let codec: PreparedProgressiveCodec
        private var byteCount = 0
        private var isClosed = false

        init(codec: PreparedProgressiveCodec) {
            self.codec = codec
        }

        var receivedByteCount: Int { lock.withLock { byteCount } }

        func append(_ chunk: Data) throws -> ImageProgressiveDecodeGeneration? {
            try lock.withLock {
                guard !isClosed else { throw ImageCraftError.progressiveSessionFinished }
                byteCount += chunk.count
                return nil
            }
        }

        func finish() throws {
            try lock.withLock {
                guard !isClosed else { throw ImageCraftError.progressiveSessionFinished }
                isClosed = true
            }
        }

        func finishWithPreparation() throws -> ImageProgressiveDecodePreparationFinalization {
            let count = try lock.withLock {
                guard !isClosed else { throw ImageCraftError.progressiveSessionFinished }
                isClosed = true
                return byteCount
            }
            return try codec.progressivePreparation(byteCount: count)
        }

        func cancel() { lock.withLock { isClosed = true } }
    }
}

private actor ProgressiveCleanupBarrierRecordStore: RepresentationRecordStoring {
    private let base: RepresentationRecordStore
    private var cleanupStarted = false
    private var cleanupReleased = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(base: RepresentationRecordStore) {
        self.base = base
    }

    func records(
        for baseKeyDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async -> [RepresentationRecord] {
        await base.records(
            for: baseKeyDigest,
            namespace: namespace,
            namespaceGeneration: namespaceGeneration
        )
    }

    func put(_ record: RepresentationRecord) async throws {
        try await base.put(record)
    }

    func containsReference(
        to contentID: String,
        namespace: String,
        excludingVariantDigest: String?
    ) async -> Bool {
        await base.containsReference(
            to: contentID,
            namespace: namespace,
            excludingVariantDigest: excludingVariantDigest
        )
    }

    func remove(
        _ variantDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async throws {
        try await base.remove(
            variantDigest,
            namespace: namespace,
            namespaceGeneration: namespaceGeneration
        )
    }

    func removeAll(namespace: String) async throws {
        cleanupStarted = true
        for waiter in startedWaiters { waiter.resume() }
        startedWaiters.removeAll(keepingCapacity: false)
        if !cleanupReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        try await base.removeAll(namespace: namespace)
    }

    func waitUntilCleanupStarts() async {
        guard !cleanupStarted else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func releaseCleanup() {
        cleanupReleased = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll(keepingCapacity: false)
    }
}

private actor SharedProgressiveJPEGTransport:
    HTTPTransporting, TransportProgressObservationSupporting
{
    nonisolated let reusePolicy = TransportReusePolicy.reusable(
        contextIdentifier: "shared-progressive-jpeg-test-v1"
    )

    private let body: Data
    private let completionDigestOverride: String?
    private let cacheControl: String
    private var remainingBytesReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestCount = 0

    init(
        body: Data,
        completionDigestOverride: String? = nil,
        cacheControl: String = "no-store"
    ) {
        self.body = body
        self.completionDigestOverride = completionDigestOverride
        self.cacheControl = cacheControl
    }

    func execute(_ request: TransportRequest) async throws -> TransportResponse {
        requestCount += 1
        let head = try TransportResponseHead(
            statusCode: 200,
            headers: [
                "Content-Type": "image/jpeg",
                "Content-Length": String(body.count),
                "Cache-Control": cacheControl,
            ],
            url: request.request.url
        )
        request.progressObserver?(.response(head))
        var offset = 0
        for _ in 0..<2 {
            let end = min(body.count, offset + 16 * 1024)
            request.progressObserver?(
                .data(body.subdata(in: offset..<end), cumulativeByteCount: end)
            )
            offset = end
        }
        await waitForRemainingBytes()
        while offset < body.count {
            try Task.checkCancellation()
            let end = min(body.count, offset + 16 * 1024)
            request.progressObserver?(
                .data(body.subdata(in: offset..<end), cumulativeByteCount: end)
            )
            offset = end
            try await testSleep(.milliseconds(2))
        }
        let response = TransportResponse(
            head: head,
            body: body,
            metrics: TransportMetrics(receivedBytes: body.count, spilledToDisk: false)
        )
        request.progressObserver?(
            .complete(
                digestHex: completionDigestOverride ?? response.digestHex,
                byteCount: body.count
            )
        )
        return response
    }

    func prepareNextRequestGate() {
        precondition(releaseWaiters.isEmpty)
        remainingBytesReleased = false
    }

    func releaseRemainingBytes() {
        guard !remainingBytesReleased else { return }
        remainingBytesReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private func waitForRemainingBytes() async {
        guard !remainingBytesReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }
}

private enum PipelineEventTaskOutcome: Equatable, Sendable {
    case pending
    case success
    case cancellation
    case failure(PipelineFailure)
    case other(String)

    var isCancellationLike: Bool {
        switch self {
        case .cancellation:
            true
        case .failure(let failure):
            failure.category == .cancelled
        case .pending, .success, .other:
            false
        }
    }

    var isRevocationLike: Bool {
        switch self {
        case .cancellation:
            true
        case .failure(let failure):
            failure.category == .namespaceRevoked || failure.category == .cancelled
        case .pending, .success, .other:
            false
        }
    }
}

private actor PipelineEventTaskOutcomeRecorder {
    private var outcome: PipelineEventTaskOutcome = .pending

    func record(_ outcome: PipelineEventTaskOutcome) {
        self.outcome = outcome
    }

    func snapshot() -> PipelineEventTaskOutcome { outcome }
}

private actor PipelineEventRecorder {
    struct Snapshot: Sendable {
        let previewCount: Int
        let finalCount: Int
        let previewQuality: UInt16?
        let previewImage: DecodedImage?
        let finalImage: DecodedImage?
    }

    private(set) var previewCount = 0
    private(set) var finalCount = 0
    private(set) var previewQuality: UInt16?
    private(set) var previewImage: DecodedImage?
    private(set) var finalImage: DecodedImage?

    func record(_ event: ImageLoadingEvent) {
        switch event {
        case .preview(let image, let quality):
            previewCount += 1
            previewQuality = quality
            previewImage = image
        case .final(let image):
            finalCount += 1
            finalImage = image
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            previewCount: previewCount,
            finalCount: finalCount,
            previewQuality: previewQuality,
            previewImage: previewImage,
            finalImage: finalImage
        )
    }
}
