import AkashicCore
import AkashicDisk
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaStorage
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class ImagePrefetchingTests: XCTestCase {
    func testPrefetchRejectsNonpositiveConcurrencyWithoutStartingTransport() async throws {
        let body = try makePNG(width: 8, height: 8)
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [prefetchStub(body)])
        let request = try prefetchRequest(path: "invalid-concurrency")

        do {
            _ = try await pipeline.prefetch([request], maximumConcurrentRequests: 0)
            XCTFail("nonpositive prefetch concurrency must fail")
        } catch let error as ImagePrefetchError {
            XCTAssertEqual(error, .invalidMaximumConcurrentRequests)
        }
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 0)
    }

    func testPrefetchDeduplicatesDisplayIdentityBeforeStartingWork() async throws {
        let body = try makePNG(width: 8, height: 8)
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [prefetchStub(body)])
        let request = try prefetchRequest(path: "deduplicate", priority: .userInitiated)

        let result = try await pipeline.prefetch(
            [request, request, request],
            maximumConcurrentRequests: 3
        )

        XCTAssertEqual(result.requestedCount, 3)
        XCTAssertEqual(result.uniqueRequestCount, 1)
        XCTAssertEqual(result.duplicateCount, 2)
        XCTAssertEqual(result.succeededCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.cancelledCount, 0)
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testPrefetchWarmsReusableCacheForOnlyIfCachedConsumer() async throws {
        let body = try makePNG(width: 8, height: 8)
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [prefetchStub(body)])
        let request = try prefetchRequest(path: "cache-warm")

        let result = try await pipeline.prefetch([request])
        XCTAssertEqual(result.succeededCount, 1)
        let prefetchRequestCount = await transport.capturedRequests().count
        XCTAssertEqual(prefetchRequestCount, 1)

        let cachedRequest = try ImageRequest.publicImage(
            url: request.url,
            logicalSource: request.logicalSource,
            target: request.target,
            colorPolicy: request.colorPolicy,
            appID: "prefetch-tests",
            cachePolicy: .onlyIfCached
        )
        _ = try await pipeline.image(for: cachedRequest)
        let finalRequestCount = await transport.capturedRequests().count
        XCTAssertEqual(finalRequestCount, 1)
    }

    func testPrefetchIsolatesItemFailureAndCompletesRemainingRequests() async throws {
        let body = try makePNG(width: 8, height: 8)
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [
            prefetchStub(body),
            .init(
                statusCode: 404,
                headers: ["Content-Type": "image/png"],
                body: body
            ),
        ])
        let requests = try [
            prefetchRequest(path: "failure-a"),
            prefetchRequest(path: "failure-b"),
        ]

        let result = try await pipeline.prefetch(requests, maximumConcurrentRequests: 2)

        XCTAssertEqual(result.uniqueRequestCount, 2)
        XCTAssertEqual(result.succeededCount, 1)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.cancelledCount, 0)
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 2)
    }

    func testPrefetchBoundsFanoutAndForcesLowInitialTransportPriority() async throws {
        let body = try makePNG(width: 8, height: 8)
        let transport = PrefetchProbeTransport(body: body, delayNanoseconds: 25_000_000)
        let pipeline = try await makePrefetchPipeline(transport: transport)
        let requests = try (0..<6).map {
            try prefetchRequest(path: "bounded-\($0)", priority: .userInitiated)
        }

        let result = try await pipeline.prefetch(requests, maximumConcurrentRequests: 2)
        let snapshot = await transport.snapshot()

        XCTAssertEqual(result.succeededCount, 6)
        XCTAssertEqual(snapshot.requestCount, 6)
        XCTAssertLessThanOrEqual(snapshot.maximumActiveCount, 2)
        XCTAssertEqual(snapshot.maximumActiveCount, 2)
        XCTAssertEqual(snapshot.priorities, Array(repeating: .low, count: 6))
    }

    func testVisibleSubscriberPromotesSharedPrefetchTransportPriority() async throws {
        let body = try makePNG(width: 8, height: 8)
        let transport = PrefetchPriorityObservingTransport(body: body)
        let pipeline = try await makePrefetchPipeline(transport: transport)
        let request = try prefetchRequest(path: "priority-promotion", priority: .userInitiated)

        let prefetchTask = Task {
            try await pipeline.prefetch([request], maximumConcurrentRequests: 1)
        }
        await transport.waitUntilStarted()
        let visibleTask = Task { try await pipeline.image(for: request) }
        await transport.waitUntilObserved(.userInitiated)
        await transport.release()

        let prefetchResult = try await prefetchTask.value
        _ = try await visibleTask.value
        let snapshot = await transport.snapshot()
        XCTAssertEqual(prefetchResult.succeededCount, 1)
        XCTAssertEqual(snapshot.requestCount, 1)
        XCTAssertEqual(snapshot.priorities.first, .low)
        XCTAssertTrue(snapshot.priorities.contains(.userInitiated))
    }

    func testPrefetchCancellationStopsSchedulingNewItems() async throws {
        let body = try makePNG(width: 8, height: 8)
        let transport = PrefetchProbeTransport(body: body, delayNanoseconds: 2_000_000_000)
        let pipeline = try await makePrefetchPipeline(transport: transport)
        let requests = try (0..<4).map { try prefetchRequest(path: "cancel-\($0)") }
        let task = Task {
            try await pipeline.prefetch(requests, maximumConcurrentRequests: 1)
        }
        try await waitUntil("prefetch first transport starts") {
            await transport.snapshot().requestCount == 1
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled prefetch must not return a successful aggregate")
        } catch is CancellationError {
            // 预期路径：父任务 cancellation boundary 向下传播。
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.disposition, .cancelled)
        }

        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.requestCount, 1)
        XCTAssertEqual(snapshot.activeCount, 0)
    }

    func testValidatedOriginalPrefetchPersistsAfterProbeWithoutPixelDecode() async throws {
        let body = try makePNG(width: 8, height: 8)
        let (pipeline, transport, _, _) = try await makePipeline(
            stubs: [prefetchStub(body)],
            decoder: ProbeOnlyPrefetchCodec()
        )
        let request = try prefetchRequest(path: "validated-original")

        let result = try await pipeline.prefetch(
            [request],
            destination: .validatedOriginal
        )
        XCTAssertEqual(result.succeededCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        let prefetchRequestCount = await transport.capturedRequests().count
        XCTAssertEqual(prefetchRequestCount, 1)

        do {
            _ = try await pipeline.image(for: try onlyIfCachedPrefetchRequest(from: request))
            XCTFail("the probe-only codec must fail only when the later consumer decodes")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.stage, .decode)
        }
        let finalRequestCount = await transport.capturedRequests().count
        XCTAssertEqual(finalRequestCount, 1)
    }

    func testValidatedOriginalConditionalETag304RefreshesMetadataWithoutPixelDecode() async throws {
        let body = try makePNG(width: 8, height: 8)
        let etag = "\"prefetch-v1\""
        let refreshedETag = "\"prefetch-v2\""
        let (pipeline, transport, _, records) = try await makePipeline(
            stubs: [
                staleValidatedPrefetchStub(body, etag: etag),
                .init(
                    statusCode: 304,
                    headers: ["Cache-Control": "max-age=3600", "ETag": refreshedETag]
                ),
            ],
            decoder: ProbeOnlyPrefetchCodec()
        )
        let request = try prefetchRequest(path: "validated-etag-304")

        let first = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(first.succeededCount, 1)
        let before = try await storedPrefetchRecord(records, request: request)
        XCTAssertFalse(before.isFresh(at: Date()))

        let second = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(second.succeededCount, 1)
        let captured = await transport.capturedRequests()
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[1].value(forHTTPHeaderField: "If-None-Match"), etag)
        let after = try await storedPrefetchRecord(records, request: request)
        XCTAssertEqual(after.contentID, before.contentID)
        XCTAssertEqual(after.variantKeyDigest, before.variantKeyDigest)
        XCTAssertEqual(after.payloadLength, before.payloadLength)
        XCTAssertEqual(after.etag, refreshedETag)
        XCTAssertTrue(after.isFresh(at: Date()))

        let third = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(third.succeededCount, 1)
        let requestCountAfterFreshHit = await transport.capturedRequests().count
        XCTAssertEqual(requestCountAfterFreshHit, 2)
        do {
            _ = try await pipeline.image(for: try onlyIfCachedPrefetchRequest(from: request))
            XCTFail("304 validated-original prefetch must not invoke pixel decode")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.stage, .decode)
        }
        let requestCountAfterCachedDecode = await transport.capturedRequests().count
        XCTAssertEqual(requestCountAfterCachedDecode, 2)
    }

    func testValidatedOriginalConditional304UsesLastModifiedValidator() async throws {
        let body = try makePNG(width: 8, height: 8)
        let lastModified = "Sun, 06 Nov 1994 08:49:37 GMT"
        let (pipeline, transport, _, _) = try await makePipeline(
            stubs: [
                staleValidatedPrefetchStub(body, lastModified: lastModified),
                .init(statusCode: 304, headers: ["Cache-Control": "max-age=3600"]),
            ],
            decoder: ProbeOnlyPrefetchCodec()
        )
        let request = try prefetchRequest(path: "validated-last-modified-304")

        let first = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(first.succeededCount, 1)
        let second = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(second.succeededCount, 1)
        let captured = await transport.capturedRequests()
        XCTAssertEqual(captured.count, 2)
        XCTAssertNil(captured[1].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(
            captured[1].value(forHTTPHeaderField: "If-Modified-Since"),
            lastModified
        )
    }

    func testValidatedOriginal304NoStoreRevokesReusableStateWithoutDecode() async throws {
        let body = try makePNG(width: 8, height: 8)
        let etag = "\"prefetch-no-store\""
        let (pipeline, transport, _, _) = try await makePipeline(
            stubs: [
                staleValidatedPrefetchStub(body, etag: etag),
                .init(statusCode: 304, headers: ["Cache-Control": "no-store"]),
            ],
            decoder: ProbeOnlyPrefetchCodec()
        )
        let request = try prefetchRequest(path: "validated-304-no-store")

        let first = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(first.succeededCount, 1)
        let revalidated = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(revalidated.succeededCount, 0)
        XCTAssertEqual(revalidated.failedCount, 1)
        try await assertOnlyIfCachedMiss(pipeline: pipeline, request: request)
        let captured = await transport.capturedRequests()
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[1].value(forHTTPHeaderField: "If-None-Match"), etag)
    }

    func testValidatedOriginal304MissingBodyFallsBackToOneUnconditionalProbeOnly200() async throws {
        let original = try makePNG(width: 8, height: 8)
        let replacement = try makePNG(width: 9, height: 9)
        let firstETag = "\"prefetch-missing-v1\""
        let secondETag = "\"prefetch-missing-v2\""
        let (pipeline, transport, encoded, records) = try await makePipeline(
            stubs: [
                staleValidatedPrefetchStub(original, etag: firstETag),
                .init(statusCode: 304, headers: ["Cache-Control": "max-age=3600"]),
                .init(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "image/png",
                        "Cache-Control": "max-age=3600",
                        "ETag": secondETag,
                    ],
                    body: replacement
                ),
            ],
            decoder: ProbeOnlyPrefetchCodec()
        )
        let request = try prefetchRequest(path: "validated-304-missing-body")

        let first = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(first.succeededCount, 1)
        let before = try await storedPrefetchRecord(records, request: request)
        try await encoded.remove(contentID: before.contentID, namespace: request.namespace.value)

        let recovered = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(recovered.succeededCount, 1)
        let captured = await transport.capturedRequests()
        XCTAssertEqual(captured.count, 3)
        XCTAssertEqual(captured[1].value(forHTTPHeaderField: "If-None-Match"), firstETag)
        XCTAssertNil(captured[2].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertNil(captured[2].value(forHTTPHeaderField: "If-Modified-Since"))
        let after = try await storedPrefetchRecord(records, request: request)
        XCTAssertNotEqual(after.contentID, before.contentID)
        XCTAssertEqual(after.etag, secondETag)

        do {
            _ = try await pipeline.image(for: try onlyIfCachedPrefetchRequest(from: request))
            XCTFail("unconditional recovery must persist after probe without pixel decode")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.stage, .decode)
        }
        let requestCountAfterRecovery = await transport.capturedRequests().count
        XCTAssertEqual(requestCountAfterRecovery, 3)
    }

    func testValidatedOriginalResumesEligiblePartialWithExactRangeAndIfRange() async throws {
        let body = try makePNG(width: 32, height: 32)
        let prefixCount = max(1, body.count / 3)
        let transport = ResumablePrefetchTransport(
            body: body,
            prefixCount: prefixCount,
            secondResponse: .valid206
        )
        let pipeline = try await makePrefetchPipeline(
            transport: transport,
            configuration: resumablePrefetchConfiguration(),
            codec: ProbeOnlyPrefetchCodec()
        )
        let request = try prefetchRequest(path: "validated-resume-206")

        let first = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(first.failedCount, 1)
        try await assertOnlyIfCachedMiss(pipeline: pipeline, request: request)
        let second = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(second.succeededCount, 1)

        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.requests.count, 2)
        XCTAssertEqual(
            snapshot.requests[1].value(forHTTPHeaderField: "Range"),
            "bytes=\(prefixCount)-"
        )
        XCTAssertEqual(
            snapshot.requests[1].value(forHTTPHeaderField: "If-Range"),
            ResumablePrefetchTransport.validator
        )
        XCTAssertEqual(snapshot.deliveredBodyBytes, [prefixCount, body.count - prefixCount])
        XCTAssertLessThan(snapshot.deliveredBodyBytes[1], body.count)

        do {
            _ = try await pipeline.image(for: try onlyIfCachedPrefetchRequest(from: request))
            XCTFail("resumption must validate the full body without pixel decode")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.stage, .decode)
        }
        let finalRequestCount = await transport.snapshot().requests.count
        XCTAssertEqual(finalRequestCount, 2)
    }

    func testValidatedOriginalCancellationAfterPartialCanResumeSafely() async throws {
        let body = try makePNG(width: 28, height: 28)
        let prefixCount = max(1, body.count / 4)
        let transport = ResumablePrefetchTransport(
            body: body,
            prefixCount: prefixCount,
            initialFailure: .awaitCancellation,
            secondResponse: .valid206
        )
        let pipeline = try await makePrefetchPipeline(
            transport: transport,
            configuration: resumablePrefetchConfiguration(),
            codec: ProbeOnlyPrefetchCodec()
        )
        let request = try prefetchRequest(path: "validated-resume-cancel")
        let task = Task {
            try await pipeline.prefetch([request], destination: .validatedOriginal)
        }
        try await waitUntil("resumable partial is captured before cancellation") {
            await transport.snapshot().deliveredBodyBytes == [prefixCount]
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled prefetch must not return a successful aggregate")
        } catch is CancellationError {
            // 预期路径：父任务 cancellation boundary 向下传播。
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.disposition, .cancelled)
        }

        let resumed = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(resumed.succeededCount, 1)
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.requests.count, 2)
        XCTAssertEqual(
            snapshot.requests[1].value(forHTTPHeaderField: "Range"),
            "bytes=\(prefixCount)-"
        )
    }

    func testValidatedOriginalResumeFallsBackToFresh200WhenServerIgnoresRange() async throws {
        let interrupted = try makePNG(width: 24, height: 24)
        let replacement = try makePNG(width: 9, height: 11)
        let prefixCount = max(1, interrupted.count / 2)
        let transport = ResumablePrefetchTransport(
            body: interrupted,
            prefixCount: prefixCount,
            secondResponse: .full200(replacement)
        )
        let pipeline = try await makePrefetchPipeline(
            transport: transport,
            configuration: resumablePrefetchConfiguration()
        )
        let request = try prefetchRequest(path: "validated-resume-200-fallback")

        let first = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(first.failedCount, 1)
        let second = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(second.succeededCount, 1)
        let image = try await pipeline.image(for: onlyIfCachedPrefetchRequest(from: request))
        XCTAssertEqual(image.pixelWidth, 9)
        XCTAssertEqual(image.pixelHeight, 11)

        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.requests.count, 2)
        XCTAssertEqual(
            snapshot.requests[1].value(forHTTPHeaderField: "Range"),
            "bytes=\(prefixCount)-"
        )
        XCTAssertEqual(snapshot.deliveredBodyBytes[1], replacement.count)
    }

    func testValidatedOriginalRejectsMismatched206WithoutPersistentResidue() async throws {
        let body = try makePNG(width: 20, height: 20)
        let prefixCount = max(1, body.count / 3)
        let transport = ResumablePrefetchTransport(
            body: body,
            prefixCount: prefixCount,
            secondResponse: .malformed206(start: prefixCount + 1)
        )
        let pipeline = try await makePrefetchPipeline(
            transport: transport,
            configuration: resumablePrefetchConfiguration(),
            codec: ProbeOnlyPrefetchCodec()
        )
        let request = try prefetchRequest(path: "validated-resume-malformed-206")

        let first = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(first.failedCount, 1)
        let resumed = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(resumed.failedCount, 1)
        try await assertOnlyIfCachedMiss(pipeline: pipeline, request: request)
        let finalRequestCount = await transport.snapshot().requests.count
        XCTAssertEqual(finalRequestCount, 2)
    }

    func testValidatedOriginalResumeCandidateDoesNotCrossRequestIdentity() async throws {
        let body = try makePNG(width: 20, height: 20)
        let prefixCount = max(1, body.count / 3)
        let transport = ResumablePrefetchTransport(
            body: body,
            prefixCount: prefixCount,
            secondResponse: .full200(body)
        )
        let pipeline = try await makePrefetchPipeline(
            transport: transport,
            configuration: resumablePrefetchConfiguration()
        )
        let firstRequest = try prefetchRequest(path: "validated-resume-identity-a")
        let secondRequest = try prefetchRequest(path: "validated-resume-identity-b")

        let first = try await pipeline.prefetch([firstRequest], destination: .validatedOriginal)
        XCTAssertEqual(first.failedCount, 1)
        let second = try await pipeline.prefetch([secondRequest], destination: .validatedOriginal)
        XCTAssertEqual(second.succeededCount, 1)
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.requests.count, 2)
        XCTAssertNil(snapshot.requests[1].value(forHTTPHeaderField: "Range"))
        XCTAssertNil(snapshot.requests[1].value(forHTTPHeaderField: "If-Range"))
    }

    func testValidatedOriginalResumeStoreBoundsBytesEntriesAndGeneration() async throws {
        let store = ValidatedOriginalResumeStore(maximumTotalBytes: 10, maximumEntryCount: 2)
        let namespace = SecurityNamespaceID.publicNamespace(appID: "resume-store-tests")
        let first = ValidatedOriginalResumeKey(
            executionDigest: "first",
            namespace: namespace,
            generation: NamespaceGeneration(0)
        )
        let second = ValidatedOriginalResumeKey(
            executionDigest: "second",
            namespace: namespace,
            generation: NamespaceGeneration(0)
        )
        let nextGeneration = ValidatedOriginalResumeKey(
            executionDigest: "second",
            namespace: namespace,
            generation: NamespaceGeneration(1)
        )
        await store.store(resumeCandidate(byte: 1, count: 6), for: first)
        await store.store(resumeCandidate(byte: 2, count: 6), for: second)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.entryCount, 1)
        XCTAssertEqual(snapshot.totalBytes, 6)
        let evicted = await store.take(first)
        let wrongGeneration = await store.take(nextGeneration)
        let retained = await store.take(second)
        XCTAssertNil(evicted)
        XCTAssertNil(wrongGeneration)
        XCTAssertEqual(retained?.prefix, Data(repeating: 2, count: 6))
    }

    func testValidatedOriginalResumeValidatorRejectsWeakETagForIfRange() throws {
        let lastModified = "Sun, 06 Nov 1994 08:49:37 GMT"
        let weakWithDate = try TransportResponseHead(
            statusCode: 200,
            headers: ["ETag": "W/\"weak\"", "Last-Modified": lastModified],
            url: nil
        )
        let weakOnly = try TransportResponseHead(
            statusCode: 200,
            headers: ["ETag": "W/\"weak\""],
            url: nil
        )
        let strong = try TransportResponseHead(
            statusCode: 200,
            headers: ["ETag": "\"strong\""],
            url: nil
        )

        XCTAssertEqual(ValidatedOriginalResumeValidator.value(in: weakWithDate), lastModified)
        XCTAssertNil(ValidatedOriginalResumeValidator.value(in: weakOnly))
        XCTAssertEqual(ValidatedOriginalResumeValidator.value(in: strong), "\"strong\"")
    }

    func testValidatedOriginalContentRangeParserFailsClosed() {
        let candidate = resumeCandidate(byte: 7, count: 4, expectedTotalBytes: 10)
        let valid = ValidatedOriginalContentRange.parse("bytes 4-9/10")
        XCTAssertEqual(valid, ValidatedOriginalContentRange(start: 4, end: 9, total: 10))
        XCTAssertTrue(valid?.exactlyCompletes(candidate) == true)
        for invalid in [
            "items 4-9/10",
            "bytes 4-8/10",
            "bytes 5-9/10",
            "bytes 4-9/*",
            "bytes -1-9/10",
            "bytes 4-10/10",
            "bytes 9-4/10",
        ] {
            let parsed = ValidatedOriginalContentRange.parse(invalid)
            XCTAssertFalse(parsed?.exactlyCompletes(candidate) == true, invalid)
        }
    }

    func testValidatedOriginalRejectsNoStoreWithoutPersistentResidue() async throws {
        let body = try makePNG(width: 8, height: 8)
        let noStore = FakeHTTPTransport.Stub(
            statusCode: 200,
            headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
            body: body
        )
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [noStore])
        let request = try prefetchRequest(path: "validated-no-store")

        let result = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(result.succeededCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        try await assertOnlyIfCachedMiss(pipeline: pipeline, request: request)
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testValidatedOriginalRejectsInvalidProbeWithoutPersistentResidue() async throws {
        let body = try makePNG(width: 8, height: 8)
        let (pipeline, transport, _, _) = try await makePipeline(
            stubs: [prefetchStub(body)],
            decoder: RejectingPrefetchCodec()
        )
        let request = try prefetchRequest(path: "validated-invalid-probe")

        let result = try await pipeline.prefetch([request], destination: .validatedOriginal)
        XCTAssertEqual(result.succeededCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        try await assertOnlyIfCachedMiss(pipeline: pipeline, request: request)
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testValidatedOriginalRequiresCrossRequestReuseBeforeTransport() async throws {
        let body = try makePNG(width: 8, height: 8)
        let transport = PrefetchProbeTransport(
            body: body,
            delayNanoseconds: 0,
            reusePolicy: .taskLocal
        )
        let pipeline = try await makePrefetchPipeline(transport: transport)
        let request = try prefetchRequest(path: "validated-task-local")

        let result = try await pipeline.prefetch([request], destination: .validatedOriginal)
        let snapshot = await transport.snapshot()
        XCTAssertEqual(result.succeededCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(snapshot.requestCount, 0)
    }

    func testPrefetchDoesNotDeduplicateAcrossSecurityNamespaces() async throws {
        let body = try makePNG(width: 8, height: 8)
        let (pipeline, transport, _, _) = try await makePipeline(stubs: [
            prefetchStub(body), prefetchStub(body),
        ])
        let url = try XCTUnwrap(URL(string: "https://example.test/namespace.png"))
        let target = try TargetPixels(width: 16, height: 16)
        let first = try ImageRequest.publicImage(url: url, target: target, appID: "prefetch-a")
        let second = try ImageRequest.publicImage(url: url, target: target, appID: "prefetch-b")

        let result = try await pipeline.prefetch([first, second], maximumConcurrentRequests: 2)

        XCTAssertEqual(result.requestedCount, 2)
        XCTAssertEqual(result.uniqueRequestCount, 2)
        XCTAssertEqual(result.succeededCount, 2)
        let requestCount = await transport.capturedRequests().count
        XCTAssertEqual(requestCount, 2)
    }
}

private func onlyIfCachedPrefetchRequest(from request: ImageRequest) throws -> ImageRequest {
    try ImageRequest.publicImage(
        url: request.url,
        logicalSource: request.logicalSource,
        target: request.target,
        colorPolicy: request.colorPolicy,
        appID: "prefetch-tests",
        cachePolicy: .onlyIfCached
    )
}

private func assertOnlyIfCachedMiss(
    pipeline: FoveaPipeline,
    request: ImageRequest
) async throws {
    do {
        _ = try await pipeline.image(for: onlyIfCachedPrefetchRequest(from: request))
        XCTFail("validated-original failure must not leave reusable cache residue")
    } catch let failure as PipelineFailure {
        XCTAssertEqual(failure.reasonCode, "only-if-cached-miss")
        XCTAssertEqual(failure.stage, .cacheLookup)
    }
}

private struct ProbeOnlyPrefetchCodec: TestImageCodec {
    func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
        try ImageIOImageDecoder().probe(data: data, limits: limits)
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

private struct RejectingPrefetchCodec: TestImageCodec {
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

private func prefetchRequest(
    path: String,
    priority: ImageRequestPriority = .normal
) throws -> ImageRequest {
    try ImageRequest.publicImage(
        url: XCTUnwrap(URL(string: "https://example.test/\(path).png")),
        target: TargetPixels(width: 16, height: 16),
        appID: "prefetch-tests",
        priority: priority
    )
}

private func prefetchStub(_ body: Data) -> FakeHTTPTransport.Stub {
    .init(
        statusCode: 200,
        headers: [
            "Content-Type": "image/png",
            "Cache-Control": "max-age=3600",
        ],
        body: body
    )
}

private func staleValidatedPrefetchStub(
    _ body: Data,
    etag: String? = nil,
    lastModified: String? = nil
) -> FakeHTTPTransport.Stub {
    var headers = [
        "Content-Type": "image/png",
        "Cache-Control": "max-age=0",
    ]
    if let etag { headers["ETag"] = etag }
    if let lastModified { headers["Last-Modified"] = lastModified }
    return .init(statusCode: 200, headers: headers, body: body)
}

private func storedPrefetchRecord(
    _ store: RepresentationRecordStore,
    request: ImageRequest
) async throws -> RepresentationRecord {
    let records = await store.records(
        for: request.fetchBaseDigest,
        namespace: request.namespace.value,
        namespaceGeneration: 0
    )
    return try XCTUnwrap(records.first)
}

private func makePrefetchPipeline(
    transport: any HTTPTransporting,
    configuration: PipelineConfiguration = PipelineConfiguration(),
    codec: any ImageCodec = ImageIOImageDecoder()
) async throws -> FoveaPipeline {
    let root = try makeTemporaryDirectory()
    let encoded = try await AkashicOriginalEncodedStore.open(
        root: root.appendingPathComponent("encoded")
    )
    let records = try await RepresentationRecordStore.open(
        root: root.appendingPathComponent("records")
    )
    return FoveaPipeline(
        configuration: configuration,
        transport: transport,
        encodedStore: encoded,
        recordStore: records,
        profileAccessPolicy: .unrestricted,
        codec: codec
    )
}

private func resumablePrefetchConfiguration() -> PipelineConfiguration {
    PipelineConfiguration(
        transportRetryPolicy: TransportRetryPolicy(maximumAttempts: 1)
    )
}

private func resumeCandidate(
    byte: UInt8,
    count: Int,
    expectedTotalBytes: Int = 12
) -> ValidatedOriginalResumeCandidate {
    ValidatedOriginalResumeCandidate(
        prefix: Data(repeating: byte, count: count),
        validator: "\"resume-candidate\"",
        expectedTotalBytes: expectedTotalBytes
    )
}

private actor ResumablePrefetchTransport: HTTPTransporting, TransportProgressObservationSupporting {
    static let validator = "\"resume-v1\""

    enum InitialFailure: Sendable {
        case networkLost
        case awaitCancellation
    }

    enum SecondResponse: Sendable {
        case valid206
        case full200(Data)
        case malformed206(start: Int)
    }

    struct Snapshot: Sendable {
        let requests: [URLRequest]
        let deliveredBodyBytes: [Int]
    }

    nonisolated let reusePolicy = TransportReusePolicy.reusable(
        contextIdentifier: "resumable-prefetch-v1"
    )

    private let body: Data
    private let prefixCount: Int
    private let initialFailure: InitialFailure
    private let secondResponse: SecondResponse
    private var requests: [URLRequest] = []
    private var deliveredBodyBytes: [Int] = []

    init(
        body: Data,
        prefixCount: Int,
        initialFailure: InitialFailure = .networkLost,
        secondResponse: SecondResponse
    ) {
        self.body = body
        self.prefixCount = min(max(1, prefixCount), max(1, body.count - 1))
        self.initialFailure = initialFailure
        self.secondResponse = secondResponse
    }

    func execute(_ request: TransportRequest) async throws -> TransportResponse {
        requests.append(request.request)
        if requests.count == 1 {
            return try await failInitialRequest(request)
        }
        switch secondResponse {
        case .valid206:
            return try complete206(request, rangeStart: prefixCount)
        case .full200(let replacement):
            return try complete200(request, body: replacement)
        case .malformed206(let start):
            return try complete206(request, rangeStart: start)
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(requests: requests, deliveredBodyBytes: deliveredBodyBytes)
    }

    private func failInitialRequest(_ request: TransportRequest) async throws -> TransportResponse {
        let head = try responseHead(
            statusCode: 200,
            headers: [
                "Content-Type": "image/png",
                "Cache-Control": "max-age=3600",
                "Accept-Ranges": "bytes",
                "Content-Length": String(body.count),
                "ETag": Self.validator,
            ],
            request: request
        )
        let prefix = Data(body.prefix(prefixCount))
        request.progressObserver?(.response(head))
        request.progressObserver?(.data(prefix, cumulativeByteCount: prefix.count))
        deliveredBodyBytes.append(prefix.count)
        switch initialFailure {
        case .networkLost:
            throw URLError(.networkConnectionLost)
        case .awaitCancellation:
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw URLError(.timedOut)
        }
    }

    private func complete206(
        _ request: TransportRequest,
        rangeStart: Int
    ) throws -> TransportResponse {
        let suffix = Data(body.dropFirst(prefixCount))
        let head = try responseHead(
            statusCode: 206,
            headers: [
                "Content-Type": "image/png",
                "Cache-Control": "max-age=3600",
                "Content-Length": String(suffix.count),
                "Content-Range": "bytes \(rangeStart)-\(body.count - 1)/\(body.count)",
                "ETag": Self.validator,
            ],
            request: request
        )
        return complete(request, head: head, body: suffix)
    }

    private func complete200(
        _ request: TransportRequest,
        body: Data
    ) throws -> TransportResponse {
        let head = try responseHead(
            statusCode: 200,
            headers: [
                "Content-Type": "image/png",
                "Cache-Control": "max-age=3600",
                "Accept-Ranges": "bytes",
                "Content-Length": String(body.count),
                "ETag": "\"resume-v2\"",
            ],
            request: request
        )
        return complete(request, head: head, body: body)
    }

    private func complete(
        _ request: TransportRequest,
        head: TransportResponseHead,
        body: Data
    ) -> TransportResponse {
        let response = TransportResponse(
            head: head,
            body: body,
            metrics: TransportMetrics(receivedBytes: body.count, spilledToDisk: false)
        )
        request.progressObserver?(.response(head))
        request.progressObserver?(.data(body, cumulativeByteCount: body.count))
        request.progressObserver?(
            .complete(digestHex: response.digestHex, byteCount: body.count)
        )
        deliveredBodyBytes.append(body.count)
        return response
    }

    private func responseHead(
        statusCode: Int,
        headers: [String: String],
        request: TransportRequest
    ) throws -> TransportResponseHead {
        try TransportResponseHead(
            statusCode: statusCode,
            headers: headers,
            url: request.request.url
        )
    }
}

private actor PrefetchProbeTransport: HTTPTransporting {
    nonisolated let reusePolicy: TransportReusePolicy

    struct Snapshot: Sendable {
        let requestCount: Int
        let activeCount: Int
        let maximumActiveCount: Int
        let priorities: [TransportPriority]
    }

    private let body: Data
    private let delayNanoseconds: UInt64
    private var requestCount = 0
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var priorities: [TransportPriority] = []

    init(
        body: Data,
        delayNanoseconds: UInt64,
        reusePolicy: TransportReusePolicy = .reusable(
            contextIdentifier: "prefetch-probe-v1"
        )
    ) {
        self.body = body
        self.delayNanoseconds = delayNanoseconds
        self.reusePolicy = reusePolicy
    }

    func execute(_ request: TransportRequest) async throws -> TransportResponse {
        requestCount += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        priorities.append(request.priority)
        defer { activeCount -= 1 }

        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        try Task.checkCancellation()
        return TransportResponse(
            head: try TransportResponseHead(
                statusCode: 200,
                headers: [
                    "Content-Type": "image/png",
                    "Cache-Control": "max-age=3600",
                ],
                url: request.request.url
            ),
            body: body,
            metrics: TransportMetrics(receivedBytes: body.count, spilledToDisk: false)
        )
    }

    func snapshot() -> Snapshot {
        Snapshot(
            requestCount: requestCount,
            activeCount: activeCount,
            maximumActiveCount: maximumActiveCount,
            priorities: priorities
        )
    }
}

private actor PrefetchPriorityObservingTransport: HTTPTransporting {
    nonisolated let reusePolicy = TransportReusePolicy.reusable(
        contextIdentifier: "prefetch-priority-observer-v1"
    )

    struct Snapshot: Sendable {
        let requestCount: Int
        let priorities: [TransportPriority]
    }

    private let body: Data
    private var started = false
    private var released = false
    private var requestCount = 0
    private var priorities: [TransportPriority] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var priorityWaiters: [(TransportPriority, CheckedContinuation<Void, Never>)] = []

    init(body: Data) {
        self.body = body
    }

    func execute(_ request: TransportRequest) async throws -> TransportResponse {
        requestCount += 1
        observe(request.priority)
        let observer = Task { [weak self] in
            guard let controller = request.priorityController else { return }
            let updates = await controller.updates()
            for await priority in updates {
                await self?.observe(priority)
            }
        }
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        observer.cancel()
        try Task.checkCancellation()
        return TransportResponse(
            head: try TransportResponseHead(
                statusCode: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                url: request.request.url
            ),
            body: body,
            metrics: TransportMetrics(receivedBytes: body.count, spilledToDisk: false)
        )
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilObserved(_ priority: TransportPriority) async {
        guard !priorities.contains(priority) else { return }
        await withCheckedContinuation { priorityWaiters.append((priority, $0)) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }

    func snapshot() -> Snapshot {
        Snapshot(requestCount: requestCount, priorities: priorities)
    }

    private func observe(_ priority: TransportPriority) {
        guard priorities.last != priority else { return }
        priorities.append(priority)
        var remaining: [(TransportPriority, CheckedContinuation<Void, Never>)] = []
        for waiter in priorityWaiters {
            if waiter.0 == priority {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        priorityWaiters = remaining
    }
}
