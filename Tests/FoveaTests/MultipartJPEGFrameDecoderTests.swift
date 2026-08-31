import CoreGraphics
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaSystem
import ImageCraftCore
import ImageIO
import XCTest

final class MultipartJPEGFrameDecoderTests: XCTestCase {
    func testPipelineFrameDecoderUsesOrdinaryTargetAndColorDecode_W5_PT_073() async throws {
        let (pipeline, _, _, _) = try await makePipeline(stubs: [])
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/live.mjpeg")),
            target: TargetPixels(width: 8, height: 8),
            colorPolicy: .convertToSRGB,
            appID: "mjpeg-frame-decoder"
        )
        let decoder = try await pipeline.makeMultipartJPEGFrameDecoder(for: request)
        let jpeg = try makeFrameDecoderJPEG(width: 16, height: 8)

        let image = try await decoder.decode(MultipartJPEGPart(index: 0, headers: [:], data: jpeg))

        XCTAssertEqual(image.pixelWidth, 8)
        XCTAssertEqual(image.pixelHeight, 4)
        XCTAssertEqual(image.colorDescription.sourceProfile, SourceColorProfile.absent)
    }

    func testFrameDecoderRejectsNonJPEGEvenWhenCodecSupportsIt_W5_PT_074() async throws {
        let (pipeline, _, _, _) = try await makePipeline(stubs: [])
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/not-jpeg.mjpeg")),
            target: TargetPixels(width: 8, height: 8),
            appID: "mjpeg-frame-decoder"
        )
        let decoder = try await pipeline.makeMultipartJPEGFrameDecoder(for: request)

        do {
            _ = try await decoder.decode(
                MultipartJPEGPart(index: 0, headers: [:], data: makePNG(width: 8, height: 8))
            )
            XCTFail("MJPEG frame decoder accepted non-JPEG bytes")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.stage, .probe)
            XCTAssertEqual(failure.reasonCode, "container-format-mismatch")
        }
    }

    func testFrameDecoderFailsAfterNamespaceGenerationChanges_W5_PT_075() async throws {
        let namespace = SecurityNamespaceID("mjpeg-private")
        let registry = NamespaceRegistry(initialGenerations: [namespace: NamespaceGeneration(0)])
        let (pipeline, _, _, _) = try await makePipeline(
            stubs: [],
            namespaceRegistry: registry
        )
        let request = try ImageRequest(
            url: try XCTUnwrap(URL(string: "https://example.test/private.mjpeg")),
            target: TargetPixels(width: 8, height: 8),
            namespace: namespace,
            authorizationContext: AuthorizationContextID("account"),
            credentialGeneration: CredentialGeneration(1)
        )
        let decoder = try await pipeline.makeMultipartJPEGFrameDecoder(for: request)
        _ = try await registry.revoke(namespace)

        do {
            _ = try await decoder.decode(
                MultipartJPEGPart(
                    index: 0,
                    headers: [:],
                    data: try makeFrameDecoderJPEG(width: 8, height: 8)
                )
            )
            XCTFail("Revoked namespace accepted a later MJPEG frame")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.reasonCode, "namespace-revoked")
        }
    }

    func testSystemPublicOnlyProfileRejectsPrivateMJPEGDecoder_W5_PT_076() async throws {
        let system = try await FoveaSystemPipeline.open(
            cacheRoot: try makeTemporaryDirectory("mjpeg-private-profile")
        )
        let request = try ImageRequest(
            url: try XCTUnwrap(URL(string: "https://example.test/private.mjpeg")),
            target: TargetPixels(width: 8, height: 8),
            namespace: SecurityNamespaceID("private-account"),
            authorizationContext: AuthorizationContextID("account"),
            credentialGeneration: CredentialGeneration(1)
        )

        do {
            _ = try await system.pipeline.makeMultipartJPEGFrameDecoder(for: request)
            XCTFail("Public-only system created a private MJPEG decoder")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.reasonCode, "profile-access-denied")
        }
        await system.invalidateAndCancel()
    }

    func testFrameDecoderRejectsMissingAuthorizationContext_W5_PT_077() async throws {
        let (pipeline, _, _, _) = try await makePipeline(stubs: [])
        let request = try ImageRequest(
            url: try XCTUnwrap(URL(string: "https://example.test/credentialed.mjpeg")),
            target: TargetPixels(width: 8, height: 8),
            namespace: SecurityNamespaceID("credentialed"),
            headers: ["Authorization": "Bearer secret"]
        )

        do {
            _ = try await pipeline.makeMultipartJPEGFrameDecoder(for: request)
            XCTFail("Credentialed MJPEG decoder lacked authorization context")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.reasonCode, "missing-authorization-context")
        }
    }
}

private func makeFrameDecoderJPEG(width: Int, height: Int) throws -> Data {
    let bytesPerRow = width * 4
    let pixels = Data(repeating: 0x7f, count: bytesPerRow * height)
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
    else { throw NSError(domain: "MJPEGFrameTests", code: 1) }

    let output = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        )
    else { throw NSError(domain: "MJPEGFrameTests", code: 2) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "MJPEGFrameTests", code: 3)
    }
    return output as Data
}
