import AkashicCore
import AkashicDisk
import CoreGraphics
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaStorage
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class PipelineTests: XCTestCase {
    func testTransformFailureRetainsOriginalAndPublishesNoRendered_CACHE_PT_030() async throws {
        let root = try makeTemporaryDirectory()
        let body = try makePNG()
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: body
            )
        ])
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let transformer = FailingImageTransformer()
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder(),
            transformer: transformer
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/transform-failure.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )

        for _ in 0..<2 {
            do {
                _ = try await pipeline.image(for: request)
                XCTFail("失败的 transform 不得交付 final")
            } catch let failure as PipelineFailure {
                XCTAssertEqual(failure.category, .transform)
                XCTAssertEqual(failure.stage, .transform)
                XCTAssertEqual(failure.reasonCode, "transform-failed")
            }
        }

        let storedRecords = await records.records(
            for: request.fetchBaseKey.digestHex,
            namespace: request.namespace.value,
            namespaceGeneration: 0
        )
        let physicalID = await encoded.physicalID(
            contentID: ContentID(data: body).description,
            namespace: request.namespace.value
        )
        let requestCount = await transport.capturedRequests().count
        let transformCount = await transformer.transformCount
        XCTAssertEqual(storedRecords.count, 1)
        XCTAssertNotNil(physicalID)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(transformCount, 2)
    }

    func testConcurrentEquivalentRequestsShareOneTransform_SCHED_PT_017() async throws {
        let root = try makeTemporaryDirectory()
        let body = try makePNG(width: 40, height: 40)
        let response = FakeHTTPTransport.Stub(
            statusCode: 200,
            headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
            body: body
        )
        // 获取完成早于表征发布，因此较慢平台可能在第一次响应提交前
        // 合法启动第二次传输。该测试通过提供两个等价响应，
        // 隔离并验证更强的 RenderKey 契约。
        let transport = FakeHTTPTransport(stubs: [response, response])
        let transformer = CountingSlowImageTransformer()
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")
            ),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")
            ),
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder(),
            transformer: transformer
        )
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/shared-transform.png")),
            target: TargetPixels(width: 20, height: 20),
            appID: "shared-transform-tests"
        )

        async let first = pipeline.image(for: request)
        async let second = pipeline.image(for: request)
        let images = try await [first, second]

        let transformCount = await transformer.transformCount
        XCTAssertEqual(images.map(\.pixelWidth), [20, 20])
        XCTAssertEqual(transformCount, 1)
    }

    func testTransformOutputIsRevalidatedBeforeDeliveryAndMemoryAdmission() async throws {
        let root = try makeTemporaryDirectory()
        let body = try makePNG(width: 40, height: 40)
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                body: body
            )
        ])
        let pipeline = FoveaPipeline(
            configuration: PipelineConfiguration(
                maximumDecodeWorkingSetBytes: 2 * 1024 * 1024
            ),
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")
            ),
            recordStore: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")
            ),
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder(),
            transformer: OversizedImageTransformer()
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/transform-output-limit.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )

        do {
            _ = try await pipeline.image(for: request)
            XCTFail("A transformer must not publish a surface above the pipeline working-set cap")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .resourceLimit)
            XCTAssertEqual(failure.stage, .transform)
            XCTAssertEqual(failure.reasonCode, "transform-output-limit-exceeded")
        }
    }

    func testEncodedDataRequestDoesNotProbeDecodeOrPersist_GEO_PT_008() async throws {
        let root = try makeTemporaryDirectory()
        let body = try makePNG()
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: body
            )
        ])
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            codec: RejectingDecoder()
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/encoded-data.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )

        let received = try await pipeline.encodedData(for: request)

        let requestCount = await transport.capturedRequests().count
        let storedRecords = await records.records(
            for: request.fetchBaseKey.digestHex,
            namespace: request.namespace.value,
            namespaceGeneration: 0
        )
        let storedBlob = await encoded.physicalID(
            contentID: ContentID(data: body).description,
            namespace: request.namespace.value
        )
        XCTAssertEqual(received, body)
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(storedRecords.isEmpty)
        XCTAssertNil(storedBlob)
    }

    func testOnlyIfCachedMissIsExplicitAndNeverStartsNetwork_ERR_PT_002() async throws {
        let body = try makePNG()
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: body
            )
        ])
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/only-if-cached.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests",
            cachePolicy: .onlyIfCached
        )

        do {
            _ = try await pipeline.image(for: request)
            XCTFail("onlyIfCached 未命中必须返回明确失败")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .cacheRead)
            XCTAssertEqual(failure.stage, .cacheLookup)
            XCTAssertEqual(failure.disposition, .terminal)
            XCTAssertEqual(failure.reasonCode, "only-if-cached-miss")
        }

        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 0)
    }

    func testTaskLocalTransportBypassesCacheAndCrossRequestSingleFlight_AUTH_PT_008() async throws {
        let root = try makeTemporaryDirectory()
        let body = try makePNG()
        let transport = FakeHTTPTransport(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                    body: body,
                    delayNanoseconds: 30_000_000
                ),
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                    body: body,
                    delayNanoseconds: 30_000_000
                ),
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                    body: body
                ),
            ],
            reusePolicy: .taskLocal
        )
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
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
            url: try XCTUnwrap(URL(string: "https://example.test/opaque-session.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )

        async let first = pipeline.image(for: request)
        async let second = pipeline.image(for: request)
        _ = try await (first, second)
        _ = try await pipeline.image(for: request)

        let requestCount = await transport.capturedRequests().count
        let storedRecords = await records.records(
            for: request.fetchBaseKey.digestHex,
            namespace: request.namespace.value,
            namespaceGeneration: 0
        )
        let storedBlob = await encoded.physicalID(
            contentID: ContentID(data: body).description,
            namespace: request.namespace.value
        )
        XCTAssertEqual(requestCount, 3)
        XCTAssertTrue(storedRecords.isEmpty)
        XCTAssertNil(storedBlob)
    }

    func testCredentialHeaderWithoutContextFailsBeforeNetwork_AUTH_PT_006() async throws {
        let body = try makePNG()
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [
            .init(statusCode: 200, headers: ["Content-Type": "image/png"], body: body)
        ])
        let request = try ImageRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/credential.png")),
            target: try TargetPixels(width: 20, height: 20),
            namespace: SecurityNamespaceID.publicNamespace(appID: "tests"),
            headers: ["Authorization": "Bearer secret"]
        )
        do {
            _ = try await pipeline.image(for: request)
            XCTFail("Expected fail-closed authorization error")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .authorization)
            XCTAssertEqual(failure.stage, .requestValidation)
            XCTAssertEqual(failure.disposition, .terminal)
            XCTAssertEqual(failure.reasonCode, "missing-authorization-context")
        }
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 0)
    }

    func testInjectedClockControlsFreshnessWithoutSleeping() async throws {
        let root = try makeTemporaryDirectory()
        let body = try makePNG()
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records"))
        let transport = FakeHTTPTransport(stubs: [])
        let now = Date(timeIntervalSince1970: 20_000)
        let clock = TestWallClock(now)
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.com/clock.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
        let contentID = ContentID(data: body)
        _ = try await encoded.commit(
            data: body,
            contentID: contentID.description,
            namespace: request.namespace.value
        )
        try await records.put(
            makeRepresentationRecord(
                namespace: request.namespace.value,
                baseKeyDigest: request.fetchBaseKey.digestHex,
                variantKeyDigest: request.fetchVariantKey.digestHex,
                requestTime: now,
                responseTime: now,
                responseDate: now,
                expiresAt: now.addingTimeInterval(10),
                contentID: contentID.description,
                payloadLength: body.count
            )
        )
        let pipeline = FoveaPipeline(
            configuration: PipelineConfiguration(
                transportRetryPolicy: TransportRetryPolicy(maximumAttempts: 1)
            ),
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            namespaceRegistry: NamespaceRegistry(),
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder(),
            clock: clock
        )

        _ = try await pipeline.image(for: request)
        let freshRequestCount = await transport.capturedRequests().count
        XCTAssertEqual(freshRequestCount, 0)

        await clock.set(now.addingTimeInterval(11))
        await assertThrowsErrorAsync { try await pipeline.image(for: request) }
        let staleRequestCount = await transport.capturedRequests().count
        XCTAssertEqual(staleRequestCount, 1)
    }

    func testCachedDecodeFailureDoesNotDeleteRecordOrRetryNetwork() async throws {
        let root = try makeTemporaryDirectory()
        let body = try makePNG()
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records"))
        let transport = FakeHTTPTransport(stubs: [])
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.com/cached-decode-failure.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
        let contentID = ContentID(data: body)
        _ = try await encoded.commit(
            data: body,
            contentID: contentID.description,
            namespace: request.namespace.value
        )
        let record = makeRepresentationRecord(
            namespace: request.namespace.value,
            baseKeyDigest: request.fetchBaseKey.digestHex,
            variantKeyDigest: request.fetchVariantKey.digestHex,
            expiresAt: Date().addingTimeInterval(3600),
            contentID: contentID.description,
            payloadLength: body.count
        )
        try await records.put(record)
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            codec: AlwaysFailingDecoder()
        )

        await assertThrowsErrorAsync { try await pipeline.image(for: request) }

        let capturedRequestCount = await transport.capturedRequests().count
        let preservedRecord = await records.records(
            for: request.fetchBaseKey.digestHex,
            namespace: request.namespace.value,
            namespaceGeneration: 0
        ).first
        XCTAssertEqual(capturedRequestCount, 0)
        XCTAssertNotNil(preservedRecord)
    }

    func testLiveTransportWithoutProgressOnlyCapabilityFailsClosed() async throws {
        let (pipeline, _, _, _) = try await makePipeline(stubs: [])
        let request = try TransportRequest(
            request: URLRequest(
                url: try XCTUnwrap(URL(string: "https://example.test/unsupported-live.mjpeg"))
            ),
            maximumBytes: 1_024,
            memoryThreshold: 128
        )

        do {
            _ = try await pipeline.executeMultipartJPEGLiveTransport(
                request,
                priority: .normal,
                keyDigest: "unsupported-live"
            )
            XCTFail("Transport without progress-only execution unexpectedly started live playback")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .resourceLimit)
            XCTAssertEqual(failure.stage, .transport)
            XCTAssertEqual(failure.reasonCode, "live-progress-transport-unsupported")
        }
    }

    func testCancellationDuringDecodeDoesNotCommitCache() async throws {
        let root = try makeTemporaryDirectory()
        let body = try makePNG()
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records"))
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: body
            )
        ])
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.com/cancel-decode.png")),
            target: TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
        let diagnostics = BoundedDiagnosticsSink(capacity: 32)
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            diagnostics: diagnostics,
            profileAccessPolicy: .unrestricted,
            codec: SlowDecoder(delay: 0.15)
        )

        let task = Task { try await pipeline.image(for: request) }
        try await waitUntil("decode 阶段开始") {
            await diagnostics.snapshot().contains { $0.event.kind == .decodeStarted }
        }
        let decodeStarted = await diagnostics.snapshot().contains {
            $0.event.kind == .decodeStarted
        }
        XCTAssertTrue(decodeStarted)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled decode must not deliver or commit")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .cancelled)
            XCTAssertEqual(failure.disposition, .cancelled)
            XCTAssertTrue([.decode, .pipeline].contains(failure.stage))
        }

        let record = await records.records(
            for: request.fetchBaseKey.digestHex,
            namespace: request.namespace.value,
            namespaceGeneration: 0
        ).first
        XCTAssertNil(record)
        let physicalID = await encoded.physicalID(
            contentID: ContentID(data: body).description,
            namespace: request.namespace.value
        )
        XCTAssertNil(physicalID)
        let blobDirectory = root.appendingPathComponent("encoded/blobs", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: blobDirectory.path),
            []
        )
    }

    func testCorruptFreshBlobFallsBackToNetwork() async throws {
        let root = try makeTemporaryDirectory()
        let firstBody = try makePNG(red: 200)
        let replacementBody = try makePNG(red: 10)
        let (pipeline, transport, encoded, records) = try await makePipeline(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                    body: firstBody
                ),
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                    body: replacementBody
                ),
            ],
            root: root
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.com/corrupt-fresh.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
        _ = try await pipeline.image(for: request)
        let recordValue = await records.record(for: variantKey(for: request).digestHex)
        let record = try XCTUnwrap(recordValue)
        let physicalIDValue = await encoded.physicalID(
            contentID: record.contentID, namespace: request.namespace.value)
        let physicalID = try XCTUnwrap(physicalIDValue)
        let blobURL = root.appendingPathComponent(
            "encoded/blobs/\(physicalID.foveaStorageFileName)"
        )
        try Data("corrupt".utf8).write(to: blobURL, options: [.atomic])
        // 本用例验证冷内存时的磁盘损坏恢复；合法 rendered-memory 副本应当先于磁盘返回。
        let purgedItemCount = await pipeline.purgeMemoryCache()
        XCTAssertEqual(purgedItemCount, 1)

        _ = try await pipeline.image(for: request)
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 2)
    }

    func test304NoStoreRevokesExistingReusableState() async throws {
        let body = try makePNG()
        let (pipeline, transport, encoded, records) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: [
                    "Content-Type": "image/png",
                    "Cache-Control": "max-age=0",
                    "ETag": "v1",
                ],
                body: body
            ),
            .init(
                statusCode: 304,
                headers: ["Cache-Control": "no-store", "ETag": "v1"],
                body: Data()
            ),
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: body
            ),
        ])
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.com/304-no-store.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )

        _ = try await pipeline.image(for: request)
        let contentID = ContentID(data: body).description
        let initialRecord = await records.record(for: request.fetchVariantKey.digestHex)
        let initialBlob = await encoded.physicalID(
            contentID: contentID,
            namespace: request.namespace.value
        )
        XCTAssertNotNil(initialRecord)
        XCTAssertNotNil(initialBlob)

        _ = try await pipeline.image(for: request)
        let revokedRecord = await records.record(for: request.fetchVariantKey.digestHex)
        let revokedBlob = await encoded.physicalID(
            contentID: contentID,
            namespace: request.namespace.value
        )
        XCTAssertNil(revokedRecord)
        XCTAssertNil(revokedBlob)

        _ = try await pipeline.image(for: request)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 3)
    }

    func test304WithMissingBodyRetriesUnconditionalGET() async throws {
        let root = try makeTemporaryDirectory()
        let firstBody = try makePNG(red: 150)
        let replacementBody = try makePNG(red: 20)
        let (pipeline, transport, encoded, records) = try await makePipeline(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "image/png", "Cache-Control": "max-age=0", "ETag": "\"v1\"",
                    ],
                    body: firstBody
                ),
                .init(
                    statusCode: 304, headers: ["Cache-Control": "max-age=3600", "ETag": "\"v1\""]),
                .init(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "image/png", "Cache-Control": "max-age=3600",
                        "ETag": "\"v2\"",
                    ],
                    body: replacementBody
                ),
            ],
            root: root
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.com/missing-body.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
        _ = try await pipeline.image(for: request)
        let recordValue = await records.record(for: variantKey(for: request).digestHex)
        let record = try XCTUnwrap(recordValue)
        let physicalIDValue = await encoded.physicalID(
            contentID: record.contentID, namespace: request.namespace.value)
        let physicalID = try XCTUnwrap(physicalIDValue)
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("encoded/blobs/\(physicalID.foveaStorageFileName)"))

        _ = try await pipeline.image(for: request)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "If-None-Match"))
    }

    func testCancellingOneSubscriberDoesNotCancelSharedFetch() async throws {
        let body = try makePNG(width: 100, height: 50)
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                body: body,
                delayNanoseconds: 100_000_000
            )
        ])
        let url = try XCTUnwrap(URL(string: "https://example.com/shared-cancel.png"))
        let firstRequest = try ImageRequest.publicImage(
            url: url,
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
        let secondRequest = try ImageRequest.publicImage(
            url: url,
            target: try TargetPixels(width: 80, height: 80),
            appID: "tests"
        )

        let cancelled = Task { try await pipeline.image(for: firstRequest) }
        let survivor = Task { try await pipeline.image(for: secondRequest) }
        try await waitUntil("两个订阅者已加入同一个 fetch single-flight") {
            let requestCount = await transport.capturedRequests().count
            let subscriberCount = await pipeline.fetchSubscriberCountForTesting(firstRequest)
            return requestCount == 1 && subscriberCount == 2
        }
        let sharedRequestCount = await transport.capturedRequests().count
        XCTAssertEqual(sharedRequestCount, 1)
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            XCTFail("Cancelled subscriber must not receive a final image")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .cancelled)
            XCTAssertEqual(failure.stage, .transport)
            XCTAssertEqual(failure.disposition, .cancelled)
        }

        let final = try await survivor.value
        XCTAssertEqual(final.pixelWidth, 80)
        XCTAssertEqual(final.pixelHeight, 40)
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testCustomCredentialHeaderWithoutContextFailsBeforeNetwork_AUTH_PT_012() async throws {
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [])
        let request = try ImageRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/custom-private.png")),
            target: try TargetPixels(width: 20, height: 20),
            namespace: .publicNamespace(appID: "tests"),
            headers: ["X-Tenant-Credential": "secret"],
            credentialHeaderNames: ["X-Tenant-Credential"]
        )

        do {
            _ = try await pipeline.image(for: request)
            XCTFail("Custom credential-bearing request must fail closed")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .authorization)
            XCTAssertEqual(failure.stage, .requestValidation)
        }
        let requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testDifferentTargetsShareFetchButDecodeIndependently() async throws {
        let body = try makePNG(width: 100, height: 50)
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                body: body,
                delayNanoseconds: 100_000_000
            )
        ])
        let url = try XCTUnwrap(URL(string: "https://example.com/shared-fetch.png"))
        let small = try ImageRequest.publicImage(
            url: url,
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
        let large = try ImageRequest.publicImage(
            url: url,
            target: try TargetPixels(width: 80, height: 80),
            appID: "tests"
        )

        async let smallImage = pipeline.image(for: small)
        async let largeImage = pipeline.image(for: large)
        let images = try await (smallImage, largeImage)

        XCTAssertEqual(images.0.pixelWidth, 20)
        XCTAssertEqual(images.0.pixelHeight, 10)
        XCTAssertEqual(images.1.pixelWidth, 80)
        XCTAssertEqual(images.1.pixelHeight, 40)
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testFreshRecordSurvivesSignedLocatorRefresh_CACHE_PT_014() async throws {
        let body = try makePNG()
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: body
            )
        ])
        let logicalSource = LogicalSourceID("asset:private-avatar:42")
        let first = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://cdn.example.com/avatar.png?sig=old&exp=1")),
            logicalSource: logicalSource,
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
        let refreshed = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://cdn.example.com/avatar.png?sig=new&exp=2")),
            logicalSource: logicalSource,
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )

        _ = try await pipeline.image(for: first)
        _ = try await pipeline.image(for: refreshed)

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url, first.url)
    }

    func testFreshRecordAvoidsNetwork_CACHE_PT_006() async throws {
        let body = try makePNG()
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: body
            )
        ])
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.com/fresh.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
        _ = try await pipeline.image(for: request)
        _ = try await pipeline.image(for: request)
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func test304ReusesContentID_CACHE_PT_008() async throws {
        let body = try makePNG()
        let (pipeline, transport, _, records) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: [
                    "Content-Type": "image/png",
                    "Cache-Control": "max-age=0",
                    "ETag": "\"v1\"",
                ],
                body: body
            ),
            .init(statusCode: 304, headers: ["Cache-Control": "max-age=3600", "ETag": "\"v1\""]),
        ])
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.com/revalidate.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
        _ = try await pipeline.image(for: request)
        let digest = variantKey(for: request).digestHex
        let beforeRecord = await records.record(for: digest)
        let before = try XCTUnwrap(beforeRecord)
        _ = try await pipeline.image(for: request)
        let afterRecord = await records.record(for: digest)
        let after = try XCTUnwrap(afterRecord)
        XCTAssertEqual(before.contentID, after.contentID)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
    }

    func testVaryStarNeverSatisfiesNewRequest() async throws {
        let body = try makePNG()
        let (pipeline, transport, _, records) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: [
                    "Content-Type": "image/png",
                    "Cache-Control": "max-age=3600",
                    "Vary": "*",
                ],
                body: body
            ),
            .init(
                statusCode: 200,
                headers: [
                    "Content-Type": "image/png",
                    "Cache-Control": "max-age=3600",
                    "Vary": "*",
                ],
                body: body
            ),
        ])
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.com/vary-star.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )

        _ = try await pipeline.image(for: request)
        _ = try await pipeline.image(for: request)

        let requestCount = await transport.capturedRequests().count
        let record = await records.record(for: request.fetchVariantKey.digestHex)
        XCTAssertEqual(requestCount, 2)
        XCTAssertNil(record)
    }

    func testNoStoreNeverSatisfiesNewRequest_CACHE_PT_026() async throws {
        let body = try makePNG()
        let (pipeline, transport, _, records) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                body: body),
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                body: body),
        ])
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.com/no-store.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
        _ = try await pipeline.image(for: request)
        _ = try await pipeline.image(for: request)
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 2)
        let storedRecord = await records.record(for: variantKey(for: request).digestHex)
        XCTAssertNil(storedRecord)
    }

    func testRevokedGenerationCannotCommit_CACHE_PT_015_AIQA_MUT_008() async throws {
        let body = try makePNG()
        let registry = NamespaceRegistry()
        let (pipeline, transport, _, records) = try await makePipeline(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                    body: body,
                    delayNanoseconds: 100_000_000
                )
            ],
            namespaceRegistry: registry
        )
        let namespace = SecurityNamespaceID("account-a")
        let request = try ImageRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/private.png")),
            target: try TargetPixels(width: 20, height: 20),
            namespace: namespace,
            authorizationContext: AuthorizationContextID("principal-a")
        )
        let task = Task { try await pipeline.image(for: request) }
        try await waitUntil("撤销前请求进入 transport") {
            await transport.capturedRequests().count == 1
        }
        let inFlightRequestCount = await transport.capturedRequests().count
        XCTAssertEqual(inFlightRequestCount, 1)
        try await pipeline.revoke(namespace: namespace)
        do {
            _ = try await task.value
            XCTFail("Expected namespace revocation")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .namespaceRevoked)
            XCTAssertEqual(failure.disposition, .terminal)
        }
        let storedRecord = await records.record(for: variantKey(for: request).digestHex)
        XCTAssertNil(storedRecord)
    }

    func testRevokeThenNewResponsePersistsCurrentGenerationAndHitsDisk_CACHE_PT_038() async throws {
        let body = try makePNG()
        let registry = NamespaceRegistry()
        let root = try makeTemporaryDirectory()
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: body
            )
        ])
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records"))
        let namespace = SecurityNamespaceID("account-relogin")
        let request = try ImageRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/relogin.png")),
            target: try TargetPixels(width: 20, height: 20),
            namespace: namespace,
            authorizationContext: AuthorizationContextID("principal-relogin")
        )
        let firstPipeline = FoveaPipeline(
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            namespaceRegistry: registry,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )

        try await firstPipeline.revoke(namespace: namespace)
        _ = try await firstPipeline.image(for: request)

        let storedValue = await records.record(for: request.fetchVariantKey.digestHex)
        let stored = try XCTUnwrap(storedValue)
        XCTAssertEqual(stored.namespaceGeneration, 1)

        let coldMemoryPipeline = FoveaPipeline(
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            namespaceRegistry: registry,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        _ = try await coldMemoryPipeline.image(for: request)

        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testPipelineRejectsRequestsUntilNamespaceCleanupCompletes_AUTH_PT_019() async throws {
        let body = try makePNG()
        let root = try makeTemporaryDirectory("revoke-cleanup-barrier")
        let registry = NamespaceRegistry()
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: body
            )
        ])
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records")
        )
        let barrierRecords = CleanupBarrierRecordStore(base: records)
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")
            ),
            recordStore: barrierRecords,
            namespaceRegistry: registry,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let namespace = SecurityNamespaceID("account-revoke-barrier")
        let request = try ImageRequest(
            url: try XCTUnwrap(URL(string: "https://example.test/revoke-barrier.png")),
            target: try TargetPixels(width: 20, height: 20),
            namespace: namespace,
            authorizationContext: AuthorizationContextID("principal-revoke-barrier")
        )

        let revoke = Task { try await pipeline.revoke(namespace: namespace) }
        await barrierRecords.waitUntilCleanupStarts()

        do {
            _ = try await pipeline.image(for: request)
            XCTFail("A request must not overlap namespace-wide persistent cleanup")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .namespaceRevoked)
            XCTAssertEqual(failure.stage, .revocation)
        }
        let requestCountDuringCleanup = await transport.capturedRequests().count
        XCTAssertEqual(requestCountDuringCleanup, 0)

        await barrierRecords.releaseCleanup()
        try await revoke.value
        _ = try await pipeline.image(for: request)
        let requestCountAfterCleanup = await transport.capturedRequests().count
        XCTAssertEqual(requestCountAfterCleanup, 1)
        let stored = await records.record(for: request.fetchVariantKey.digestHex)
        XCTAssertEqual(stored?.namespaceGeneration, 1)
    }

    func testRequestNetworkPolicyIsAppliedBeforeTransport_RES_PT_008() async throws {
        let body = try makePNG()
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                body: body
            )
        ])
        let root = try makeTemporaryDirectory()
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
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/network-policy.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests",
            networkPolicy: .conservative
        )

        _ = try await pipeline.image(for: request)

        let captured = await transport.capturedRequests()
        let sent = try XCTUnwrap(captured.singleElement)
        XCTAssertTrue(sent.allowsCellularAccess)
        XCTAssertFalse(sent.allowsConstrainedNetworkAccess)
        XCTAssertFalse(sent.allowsExpensiveNetworkAccess)
    }

    func testFreshRenderedAliasBypassesPersistentLookup_CACHE_PT_006() async throws {
        let root = try makeTemporaryDirectory("rendered-alias-fast-path")
        let body = try makePNG(width: 100, height: 50)
        let transport = FakeHTTPTransport(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: body
            )
        ])
        let encoded = PipelineCountingEncodedStore(
            base: try await AkashicOriginalEncodedStore.open(
                root: root.appendingPathComponent("encoded")
            )
        )
        let records = PipelineCountingRecordStore(
            base: try await RepresentationRecordStore.open(
                root: root.appendingPathComponent("records")
            )
        )
        let pipeline = FoveaPipeline(
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let request = try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/rendered-alias.png")),
            target: TargetPixels(width: 40, height: 20),
            appID: "rendered-alias-tests"
        )

        _ = try await pipeline.image(for: request)
        let recordsAfterFirst = await records.queryCount
        let readsAfterFirst = await encoded.readCount
        let requestsAfterFirst = await transport.capturedRequests().count

        _ = try await pipeline.image(for: request)
        let recordsAfterSecond = await records.queryCount
        let readsAfterSecond = await encoded.readCount
        let requestsAfterSecond = await transport.capturedRequests().count
        XCTAssertEqual(recordsAfterSecond, recordsAfterFirst)
        XCTAssertEqual(readsAfterSecond, readsAfterFirst)
        XCTAssertEqual(requestsAfterSecond, requestsAfterFirst)

        _ = await pipeline.purgeMemoryCache()
        _ = try await pipeline.image(for: request)
        let recordsAfterPurge = await records.queryCount
        let readsAfterPurge = await encoded.readCount
        let requestsAfterPurge = await transport.capturedRequests().count
        XCTAssertGreaterThan(recordsAfterPurge, recordsAfterFirst)
        XCTAssertGreaterThan(readsAfterPurge, readsAfterFirst)
        XCTAssertEqual(requestsAfterPurge, requestsAfterFirst)
    }

    func testProbeFailureDoesNotPublishRecord_CACHE_PT_029_AIQA_MUT_015() async throws {
        let (pipeline, _, _, records) = try await makePipeline(stubs: [
            .init(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"],
                body: Data("broken".utf8)
            )
        ])
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.com/broken.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )
        await assertThrowsErrorAsync { try await pipeline.image(for: request) }
        let storedRecord = await records.record(for: variantKey(for: request).digestHex)
        XCTAssertNil(storedRecord)
    }
}

func assertThrowsErrorAsync<T>(
    _ expression: @escaping () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // 预期会进入错误分支。
    }
}

private struct OversizedImageTransformer: ImageTransforming {
    nonisolated let fingerprint = String(repeating: "oversized-transform-", count: 4_096)

    func transform(_ image: DecodedImage) async throws -> DecodedImage {
        let width = 1_024
        let height = 1_024
        let bytesPerRow = width * 4
        let pixels = Data(repeating: 0xff, count: height * bytesPerRow)
        guard let provider = CGDataProvider(data: pixels as CFData),
            let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            throw TransformFixtureError.failed
        }
        return DecodedImage(cgImage: cgImage)
    }
}

private actor FailingImageTransformer: ImageTransforming {
    nonisolated let fingerprint = "tests-failing-transform-v1"
    private(set) var transformCount = 0

    func transform(_ image: DecodedImage) async throws -> DecodedImage {
        transformCount += 1
        throw TransformFixtureError.failed
    }
}

private enum TransformFixtureError: Error {
    case failed
}

private struct RejectingDecoder: TestImageCodec {
    func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
        throw ImageCraftError.decodeFailed
    }

    func decode(
        data: Data,
        probe: ImageProbe,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        throw ImageCraftError.decodeFailed
    }
}

private struct AlwaysFailingDecoder: TestImageCodec {
    func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
        try ImageProbe(pixelWidth: 100, pixelHeight: 50, frameCount: 1)
    }

    func decode(
        data: Data,
        probe: ImageProbe,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        throw ImageCraftError.decodeFailed
    }
}

private actor TestWallClock: WallClock {
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date { value }

    func set(_ value: Date) {
        self.value = value
    }
}

private struct SlowDecoder: TestImageCodec {
    let delay: TimeInterval

    func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
        try ImageProbe(pixelWidth: 100, pixelHeight: 50, frameCount: 1)
    }

    func decode(
        data: Data,
        probe: ImageProbe,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage {
        Thread.sleep(forTimeInterval: delay)
        return try ImageIOImageDecoder().decode(data: data, request: request, limits: limits)
    }
}

private actor CleanupBarrierRecordStore: RepresentationRecordStoring {
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

private actor CountingSlowImageTransformer: ImageTransforming {
    nonisolated let fingerprint = "tests-counting-slow-transform-v1"
    private(set) var transformCount = 0

    func transform(_ image: DecodedImage) async throws -> DecodedImage {
        transformCount += 1
        try await testSleep(.milliseconds(50))
        return image
    }
}

private actor PipelineCountingEncodedStore: OriginalEncodedStoring {
    private let base: AkashicOriginalEncodedStore
    private(set) var readCount = 0

    init(base: AkashicOriginalEncodedStore) {
        self.base = base
    }

    func read(contentID: String, namespace: String) async throws -> Data {
        readCount += 1
        return try await base.read(contentID: contentID, namespace: namespace)
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
}

private actor PipelineCountingRecordStore: RepresentationRecordStoring {
    private let base: RepresentationRecordStore
    private(set) var queryCount = 0

    init(base: RepresentationRecordStore) {
        self.base = base
    }

    func records(
        for baseKeyDigest: String,
        namespace: String,
        namespaceGeneration: UInt64
    ) async -> [RepresentationRecord] {
        queryCount += 1
        return await base.records(
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
        try await base.removeAll(namespace: namespace)
    }
}
