import AkashicDisk
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class PipelineFailureTests: XCTestCase {
    func testInternalFailureUsesStableSanitizedContract() {
        let failure = PipelineFailure.internalFailure(stage: .pipeline)
        XCTAssertEqual(failure.category, .internalFailure)
        XCTAssertEqual(failure.stage, .pipeline)
        XCTAssertEqual(failure.disposition, .terminal)
        XCTAssertEqual(failure.reasonCode, "internal-failure")
        XCTAssertNil(failure.statusCode)
    }

    func testPublicFailureContractSanitizesInvalidFields_ERR_PT_010() throws {
        let direct = PipelineFailure(
            category: .transport,
            stage: .transport,
            disposition: .terminal,
            reasonCode: "https://example.test/image?token=secret",
            statusCode: 999
        )
        XCTAssertEqual(direct.reasonCode, "invalid-reason-code")
        XCTAssertNil(direct.statusCode)

        let serialized = Data(
            #"{"category":"http","stage":"responseValidation","disposition":"terminal","reasonCode":"Server said: token=secret","statusCode":42}"#
                .utf8
        )
        let decoded = try JSONDecoder().decode(PipelineFailure.self, from: serialized)
        XCTAssertEqual(decoded.reasonCode, "invalid-reason-code")
        XCTAssertNil(decoded.statusCode)

        let roundTrip = try JSONDecoder().decode(
            PipelineFailure.self,
            from: JSONEncoder().encode(
                PipelineFailure(
                    category: .http,
                    stage: .responseValidation,
                    disposition: .retryable,
                    reasonCode: "unsupported-http-status",
                    statusCode: 503
                )
            )
        )
        XCTAssertEqual(roundTrip.reasonCode, "unsupported-http-status")
        XCTAssertEqual(roundTrip.statusCode, 503)
    }

    func testInsecureRedirectIsTerminalSecurityPolicyFailure_SEC_CASE_033() {
        let failure = PipelineFailure.transport(TransportError.insecureRedirect)

        XCTAssertEqual(failure.category, .securityPolicy)
        XCTAssertEqual(failure.stage, .transport)
        XCTAssertEqual(failure.disposition, .terminal)
        XCTAssertEqual(failure.reasonCode, "insecure-redirect")
    }

    func testEveryTransportErrorHasStableStructuredMapping() {
        let cases:
            [(
                error: TransportError,
                category: PipelineFailure.Category,
                stage: PipelineFailure.Stage,
                disposition: PipelineFailure.Disposition,
                reasonCode: String
            )] = [
                (.nonHTTPResponse, .http, .transport, .terminal, "non-http-response"),
                (
                    .bodyTooLarge, .securityLimit, .transport, .terminal,
                    "encoded-body-limit-exceeded"
                ),
                (
                    .invalidRequestLimits, .resourceLimit, .requestValidation, .terminal,
                    "invalid-transport-limits"
                ),
                (
                    .invalidCredentialHeaderMetadata, .securityLimit, .requestValidation, .terminal,
                    "invalid-credential-header-metadata"
                ),
                (
                    .invalidResponseStatus, .http, .responseValidation, .terminal,
                    "invalid-http-status"
                ),
                (
                    .invalidResponseURL, .securityPolicy, .responseValidation, .terminal,
                    "invalid-response-url"
                ),
                (
                    .invalidResponseHeader, .http, .responseValidation, .terminal,
                    "invalid-response-header"
                ),
                (
                    .responseHeadersTooLarge, .securityLimit, .responseValidation, .terminal,
                    "response-header-limit-exceeded"
                ),
                (
                    .invalidContentLength, .http, .responseValidation, .terminal,
                    "invalid-content-length"
                ),
                (.incompleteBody, .transport, .transport, .retryable, "incomplete-response-body"),
                (.insecureRedirect, .securityPolicy, .transport, .terminal, "insecure-redirect"),
                (
                    .destinationDisallowed, .securityPolicy, .transport, .terminal,
                    "destination-disallowed"
                ),
                (
                    .proxyMetricsUnavailable, .securityPolicy, .transport, .terminal,
                    "proxy-metrics-unavailable"
                ),
                (
                    .proxyConnectionDisallowed, .securityPolicy, .transport, .terminal,
                    "proxy-connection-disallowed"
                ),
            ]

        for item in cases {
            let failure = PipelineFailure.transport(item.error)
            XCTAssertEqual(failure.category, item.category, String(describing: item.error))
            XCTAssertEqual(failure.stage, item.stage, String(describing: item.error))
            XCTAssertEqual(failure.disposition, item.disposition, String(describing: item.error))
            XCTAssertEqual(failure.reasonCode, item.reasonCode, String(describing: item.error))
            XCTAssertNil(failure.statusCode, String(describing: item.error))
        }
    }

    func testCancelledSubscriberCannotSurfaceConcurrentHTTPFailure_SCHED_PT_023() {
        let underlying = PipelineFailure(
            category: .http,
            stage: .transport,
            disposition: .terminal,
            reasonCode: "non-http-response"
        )

        let normalized = FetchSubscriptionFailureNormalizer.normalize(
            underlying,
            namespaceIsActive: true,
            callerIsCancelled: true
        )
        let failure = normalized as? PipelineFailure
        XCTAssertEqual(failure?.category, .cancelled)
        XCTAssertEqual(failure?.stage, .transport)
        XCTAssertEqual(failure?.disposition, .cancelled)

        let revoked =
            FetchSubscriptionFailureNormalizer.normalize(
                underlying,
                namespaceIsActive: false,
                callerIsCancelled: true
            ) as? PipelineFailure
        XCTAssertEqual(revoked?.category, .namespaceRevoked)
    }

    func testURLSessionErrorsHaveStableRetryClassification() {
        let cancelled = PipelineFailure.transport(URLError(.cancelled))
        XCTAssertEqual(cancelled.category, .cancelled)
        XCTAssertEqual(cancelled.disposition, .cancelled)

        for code in [
            URLError.Code.timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .resourceUnavailable,
            .backgroundSessionWasDisconnected,
        ] {
            let failure = PipelineFailure.transport(URLError(code))
            XCTAssertEqual(failure.category, .transport, String(describing: code))
            XCTAssertEqual(failure.stage, .transport, String(describing: code))
            XCTAssertEqual(failure.disposition, .retryable, String(describing: code))
            XCTAssertEqual(failure.reasonCode, "url-session-transport", String(describing: code))
        }

        let terminal = PipelineFailure.transport(URLError(.userAuthenticationRequired))
        XCTAssertEqual(terminal.category, .transport)
        XCTAssertEqual(terminal.disposition, .terminal)
        XCTAssertEqual(terminal.reasonCode, "url-session-terminal")

        let unclassified = PipelineFailure.transport(TestUnclassifiedFailure())
        XCTAssertEqual(unclassified.category, .transport)
        XCTAssertEqual(unclassified.disposition, .terminal)
        XCTAssertEqual(unclassified.reasonCode, "unclassified-transport-failure")
    }

    func testTargetGeometryLimitHasStableStructuredMapping() {
        let failure = PipelineFailure.imageCraft(
            TargetGeometryError.limitExceeded,
            stage: .decode
        )
        XCTAssertEqual(failure.category, .securityLimit)
        XCTAssertEqual(failure.stage, .requestValidation)
        XCTAssertEqual(failure.reasonCode, "target-limit-exceeded")
    }

    func testEveryImageCraftErrorHasStableStructuredMapping() {
        let cases:
            [(
                error: ImageCraftError,
                stage: PipelineFailure.Stage,
                category: PipelineFailure.Category,
                expectedStage: PipelineFailure.Stage,
                reasonCode: String
            )] = [
                (
                    .invalidTarget, .decode, .securityLimit, .requestValidation,
                    "invalid-target-pixels"
                ),
                (
                    .encodedBytesExceeded, .probe, .securityLimit, .probe,
                    "encoded-bytes-limit-exceeded"
                ),
                (
                    .unsupportedOrCorruptImage, .decode, .probe, .probe,
                    "unsupported-or-corrupt-image"
                ),
                (.unsupportedFormat, .decode, .securityLimit, .probe, "unsupported-image-format"),
                (.formatMismatch, .decode, .securityLimit, .probe, "container-format-mismatch"),
                (
                    .metadataLimitExceeded, .decode, .securityLimit, .probe,
                    "metadata-limit-exceeded"
                ),
                (
                    .auxiliaryAttachmentLimitExceeded, .decode, .securityLimit, .probe,
                    "auxiliary-attachment-limit-exceeded"
                ),
                (
                    .dimensionLimitExceeded, .decode, .securityLimit, .decode,
                    "dimension-limit-exceeded"
                ),
                (.pixelLimitExceeded, .decode, .securityLimit, .decode, "pixel-limit-exceeded"),
                (.frameLimitExceeded, .decode, .securityLimit, .decode, "frame-limit-exceeded"),
                (.probeMismatch, .decode, .probe, .probe, "probe-does-not-match-bitstream"),
                (.decodeFailed, .probe, .decode, .decode, "decode-failed"),
            ]

        for item in cases {
            let failure = PipelineFailure.imageCraft(item.error, stage: item.stage)
            XCTAssertEqual(failure.category, item.category, String(describing: item.error))
            XCTAssertEqual(failure.stage, item.expectedStage, String(describing: item.error))
            XCTAssertEqual(failure.disposition, .terminal, String(describing: item.error))
            XCTAssertEqual(failure.reasonCode, item.reasonCode, String(describing: item.error))
        }

        let probeFallback = PipelineFailure.imageCraft(TestUnclassifiedFailure(), stage: .probe)
        XCTAssertEqual(probeFallback.category, .probe)
        XCTAssertEqual(probeFallback.reasonCode, "probe-failure")
        let decodeFallback = PipelineFailure.imageCraft(TestUnclassifiedFailure(), stage: .decode)
        XCTAssertEqual(decodeFallback.category, .decode)
        XCTAssertEqual(decodeFallback.reasonCode, "decode-failure")
    }

    func testTransportFailureIsNormalizedAndRetryable_ERR_PT_009() async throws {
        let diagnostics = BoundedDiagnosticsSink()
        let (pipeline, _, _, _) = try await makePipeline(stubs: [], diagnostics: diagnostics)
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(
                URL(string: "https://private.example.test/image.png?signature=secret")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )

        do {
            _ = try await pipeline.image(for: request)
            XCTFail("Expected normalized transport failure")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .transport)
            XCTAssertEqual(failure.stage, .transport)
            XCTAssertEqual(failure.disposition, .retryable)
            XCTAssertEqual(failure.reasonCode, "url-session-transport")
        }

        let events = await diagnostics.snapshot().map(\.event)
        let failed = try XCTUnwrap(events.first { $0.kind == .pipelineFailed })
        XCTAssertEqual(failed.failureCategory, .transport)
        XCTAssertEqual(failed.failureStage, .transport)
        XCTAssertEqual(failed.failureDisposition, .retryable)
        XCTAssertEqual(failed.reason, "url-session-transport")
        XCTAssertFalse(events.contains { $0.reason?.contains("signature=secret") == true })
    }

    func testMissingContentTypeIsObservableButValidImageStillLoads() async throws {
        let diagnostics = BoundedDiagnosticsSink()
        let (pipeline, _, _, _) = try await makePipeline(
            stubs: [
                .init(statusCode: 200, headers: ["Cache-Control": "no-store"], body: try makePNG())
            ],
            diagnostics: diagnostics
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/missing-content-type.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )

        _ = try await pipeline.image(for: request)

        let events = await diagnostics.snapshot().map(\.event)
        XCTAssertTrue(
            events.contains {
                $0.kind == .responseAnomaly && $0.reason == "missing-content-type"
            }
        )
    }

    func testProbeFailureIsNormalizedAndTerminal() async throws {
        let (pipeline, _, _, _) = try await makePipeline(
            stubs: [
                .init(
                    statusCode: 200,
                    headers: ["Content-Type": "image/png", "Cache-Control": "no-store"],
                    body: Data("not-an-image".utf8)
                )
            ]
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/corrupt.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )

        do {
            _ = try await pipeline.image(for: request)
            XCTFail("Expected structured probe failure")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .securityLimit)
            XCTAssertEqual(failure.stage, .probe)
            XCTAssertEqual(failure.disposition, .terminal)
            XCTAssertEqual(failure.reasonCode, "unsupported-image-format")
        }
    }

    func testHTTPStatusDispositionIsStable() async throws {
        let (pipeline, _, _, _) = try await makePipeline(
            stubs: [.init(statusCode: 503, headers: [:], body: Data())],
            configuration: PipelineConfiguration(
                transportRetryPolicy: TransportRetryPolicy(maximumAttempts: 1)
            )
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/unavailable.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )

        do {
            _ = try await pipeline.image(for: request)
            XCTFail("Expected structured HTTP failure")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .http)
            XCTAssertEqual(failure.stage, .responseValidation)
            XCTAssertEqual(failure.disposition, .retryable)
            XCTAssertEqual(failure.reasonCode, "unsupported-http-status")
            XCTAssertEqual(failure.statusCode, 503)
        }
    }
}

extension PipelineFailureTests {
    func testMetadataSecurityFailurePublishesNoReusableStateSecCase004() async throws {
        let body = try makePNGWithOversizedTextMetadata(payloadBytes: 1_024)
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
            root: root.appendingPathComponent("records")
        )
        let pipeline = FoveaPipeline(
            configuration: PipelineConfiguration(
                decodeLimits: DecodeLimits(maximumMetadataBytes: 128)
            ),
            transport: transport,
            encodedStore: encoded,
            recordStore: records,
            profileAccessPolicy: .unrestricted,
            codec: ImageIOImageDecoder()
        )
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/metadata-limit.png")),
            target: try TargetPixels(width: 20, height: 20),
            appID: "tests"
        )

        do {
            _ = try await pipeline.image(for: request)
            XCTFail("Oversized metadata must be rejected")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .securityLimit)
            XCTAssertEqual(failure.stage, .probe)
            XCTAssertEqual(failure.reasonCode, "metadata-limit-exceeded")
        }

        let candidates = await records.records(
            for: request.fetchBaseKey.digestHex,
            namespace: request.namespace.value,
            namespaceGeneration: 0
        )
        let physicalID = await encoded.physicalID(
            contentID: ContentID(data: body).description,
            namespace: request.namespace.value
        )
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertNil(physicalID)
    }
}

private func makePNGWithOversizedTextMetadata(payloadBytes: Int) throws -> Data {
    var data = try makePNG(width: 10, height: 10)
    let iendSignature = Data([0, 0, 0, 0, 73, 69, 78, 68])
    guard let iend = data.range(of: iendSignature)?.lowerBound else {
        throw NSError(domain: "FoveaTests", code: 5)
    }
    var chunk = Data()
    let length = UInt32(payloadBytes).bigEndian
    withUnsafeBytes(of: length) { chunk.append(contentsOf: $0) }
    chunk.append(contentsOf: Data("tEXt".utf8))
    chunk.append(Data(repeating: 65, count: payloadBytes))
    chunk.append(Data(repeating: 0, count: 4))
    data.insert(contentsOf: chunk, at: iend)
    return data
}

private struct TestUnclassifiedFailure: Error {}
