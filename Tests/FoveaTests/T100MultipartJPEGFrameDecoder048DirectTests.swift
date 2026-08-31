import CoreGraphics
import Foundation
import FoveaHTTP
import ImageCraftCore
import ImageIO
import XCTest

@testable import FoveaCore

final class T100MultipartJPEGFrameDecoder048DirectTests: XCTestCase {
    func testT100_048_DIRECT_001_ordinaryTargetAndColorDecode() async throws {
        let (pipeline, _, _, _) = try await makePipeline(stubs: [])
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/t100-048-direct.mjpeg")),
            target: TargetPixels(width: 8, height: 8),
            colorPolicy: .convertToSRGB,
            appID: "t100-048-direct"
        )
        let decoder = try await makeDirectDecoder(pipeline: pipeline, request: request)
        let jpeg = try makeT100FrameDecoderJPEG(width: 16, height: 8)

        let image = try await decoder.decode(MultipartJPEGPart(index: 0, headers: [:], data: jpeg))

        XCTAssertEqual(image.pixelWidth, 8)
        XCTAssertEqual(image.pixelHeight, 4)
        XCTAssertEqual(image.colorDescription.sourceProfile, SourceColorProfile.absent)
    }

    func testT100_048_DIRECT_002_nonJPEGProbeRejection() async throws {
        let (pipeline, _, _, _) = try await makePipeline(stubs: [])
        let request = try ImageRequest.publicImage(
            url: try XCTUnwrap(URL(string: "https://example.test/t100-048-not-jpeg.mjpeg")),
            target: TargetPixels(width: 8, height: 8),
            appID: "t100-048-direct"
        )
        let decoder = try await makeDirectDecoder(pipeline: pipeline, request: request)

        do {
            _ = try await decoder.decode(
                MultipartJPEGPart(index: 0, headers: [:], data: makePNG(width: 8, height: 8))
            )
            XCTFail("FrameDecoder accepted non-JPEG bytes")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.stage, .probe)
            XCTAssertEqual(failure.reasonCode, "container-format-mismatch")
        }
    }

    func testT100_048_DIRECT_003_namespaceRevokeAfterCreation() async throws {
        let namespace = SecurityNamespaceID("t100-048-private")
        let registry = NamespaceRegistry(initialGenerations: [namespace: NamespaceGeneration(0)])
        let (pipeline, _, _, _) = try await makePipeline(stubs: [], namespaceRegistry: registry)
        let request = try ImageRequest(
            url: try XCTUnwrap(URL(string: "https://example.test/t100-048-private.mjpeg")),
            target: TargetPixels(width: 8, height: 8),
            namespace: namespace,
            authorizationContext: AuthorizationContextID("account"),
            credentialGeneration: CredentialGeneration(1)
        )
        let decoder = try await makeDirectDecoder(pipeline: pipeline, request: request)
        _ = try await registry.revoke(namespace)

        do {
            _ = try await decoder.decode(
                MultipartJPEGPart(
                    index: 0,
                    headers: [:],
                    data: try makeT100FrameDecoderJPEG(width: 8, height: 8)
                )
            )
            XCTFail("Revoked namespace accepted a later frame")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.reasonCode, "namespace-revoked")
        }
    }

    private func makeDirectDecoder(
        pipeline: FoveaPipeline,
        request: ImageRequest
    ) async throws -> PipelineMultipartJPEGFrameDecoder {
        let generation = try await pipeline.namespaceRegistry.generation(for: request.namespace)
        let decoder = PipelineMultipartJPEGFrameDecoder(
            decodeStage: pipeline.decodeStage,
            namespaceRegistry: pipeline.namespaceRegistry,
            request: request,
            generation: generation
        )
        XCTAssertEqual(decoder.generation, generation)
        return decoder
    }
}

private func makeT100FrameDecoderJPEG(width: Int, height: Int) throws -> Data {
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
    else { throw NSError(domain: "T100FrameDecoder048", code: 1) }

    let output = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        )
    else { throw NSError(domain: "T100FrameDecoder048", code: 2) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "T100FrameDecoder048", code: 3)
    }
    return output as Data
}
