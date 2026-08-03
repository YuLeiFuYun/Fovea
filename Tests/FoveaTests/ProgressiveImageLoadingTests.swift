import AkashicCore
import AkashicDisk
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaStorage
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class ProgressiveImageLoadingTests: XCTestCase {
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
        let requests = try (0..<3).map { index in
            try ImageRequest.publicImage(
                url: XCTUnwrap(URL(string: "https://example.test/warmup-\(index).png")),
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
