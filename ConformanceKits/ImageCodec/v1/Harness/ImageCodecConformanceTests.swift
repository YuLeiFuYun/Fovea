import CoreGraphics
import Foundation
import ImageCraftCore
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class ImageCodecConformanceTests: XCTestCase {
    func testDescriptorIsStableCurrentAndNonEmpty_ICT_001() throws {
        let codec = CodecUnderTest.make()
        let first = codec.codecDescriptor
        let second = CodecUnderTest.make().codecDescriptor

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.contractVersion, ImageCodecDescriptor.currentContractVersion)
        XCTAssertFalse(
            first.identifier.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertLessThanOrEqual(first.identifier.rawValue.utf8.count, 256)
        XCTAssertGreaterThan(first.implementationVersion, 0)
        XCTAssertFalse(first.capabilities.formats.isEmpty)
        XCTAssertFalse(first.capabilities.deliveryModes.isEmpty)
        XCTAssertTrue(
            first.capabilities.progressiveFormats.isSubset(of: first.capabilities.formats))
        if first.capabilities.progressiveFormats.isEmpty {
            XCTAssertFalse(
                first.capabilities.deliveryModes.contains(.progressiveGenerations),
                "progressive delivery without any supported format is an unusable capability"
            )
        } else {
            XCTAssertTrue(first.capabilities.deliveryModes.contains(.progressiveGenerations))
            let progressive = try XCTUnwrap(codec as? any ProgressiveImageDecoding)
            let request = ImageDecodeRequest(
                target: try TargetPixels(width: 1, height: 1),
                contentMode: .fit,
                colorPolicy: .preserveSource
            )
            for format in first.capabilities.progressiveFormats.sorted(by: formatOrder) {
                let session = try progressive.makeProgressiveSession(
                    format: format,
                    request: request,
                    limits: fixtureLimits()
                )
                session.cancel()
            }
        }
        XCTAssertFalse(first.capabilities.trackModes.isEmpty)
        XCTAssertFalse(first.capabilities.dynamicRanges.isEmpty)
        XCTAssertFalse(first.capabilities.outputRepresentations.isEmpty)
        XCTAssertEqual(first.cacheFingerprint, second.cacheFingerprint)
    }

    func testFiniteCapabilityDomainMatchesIndependentOracle_ICT_002() throws {
        let descriptor = CodecUnderTest.make().codecDescriptor
        var checked = 0

        for request in finiteRequests() {
            let expected = independentSupport(descriptor.capabilities, request)
            let failure = descriptor.supportFailure(for: request)
            XCTAssertEqual(descriptor.supports(request), expected)
            XCTAssertEqual(failure == nil, expected)
            if expected {
                XCTAssertNoThrow(try descriptor.requireSupport(request))
            } else {
                let expectedFailure = try XCTUnwrap(failure)
                XCTAssertThrowsError(try descriptor.requireSupport(request)) { error in
                    XCTAssertEqual(
                        error as? ImageCodecContractError,
                        .unsupportedCapability(expectedFailure)
                    )
                }
            }
            checked += 1
        }
        XCTAssertEqual(checked, 3_072)
    }

    func testAdvertisedFormatsProbeDeterministically_ICT_003() throws {
        let codec = CodecUnderTest.make()
        for format in codec.codecDescriptor.capabilities.formats.sorted(by: formatOrder) {
            let data = try fixtureData(for: format)
            let first = try codec.probe(data: data, limits: fixtureLimits())
            let second = try codec.probe(data: data, limits: fixtureLimits())

            XCTAssertEqual(first, second)
            XCTAssertEqual(first.format, format)
            XCTAssertEqual(first.pixelWidth, 2)
            XCTAssertEqual(first.pixelHeight, 2)
            XCTAssertGreaterThanOrEqual(first.frameCount, 1)
            XCTAssertTrue(
                codec.codecDescriptor.supports(
                    ImageDecodeCapabilityRequest(format: format)
                )
            )
        }
    }

    func testAdvertisedFormatsDecodeReferenceStillImage_ICT_004() throws {
        let codec = CodecUnderTest.make()
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 1, height: 1),
            contentMode: .fit,
            colorPolicy: .convertToSRGB
        )
        for format in codec.codecDescriptor.capabilities.formats.sorted(by: formatOrder) {
            let data = try fixtureData(for: format)
            let probe = try codec.probe(data: data, limits: fixtureLimits())
            let first = try codec.decode(
                data: data,
                probe: probe,
                request: request,
                limits: fixtureLimits()
            )
            let second = try codec.decode(
                data: data,
                probe: probe,
                request: request,
                limits: fixtureLimits()
            )

            XCTAssertEqual(first.pixelWidth, 1)
            XCTAssertEqual(first.pixelHeight, 1)
            XCTAssertEqual(second.pixelWidth, first.pixelWidth)
            XCTAssertEqual(second.pixelHeight, first.pixelHeight)
            XCTAssertGreaterThan(first.pixelFormat.bitsPerComponent, 0)
            XCTAssertGreaterThan(first.pixelFormat.bitsPerPixel, 0)
            XCTAssertGreaterThan(first.pixelFormat.bytesPerRow, 0)
            XCTAssertGreaterThan(first.estimatedByteCost, 0)
            XCTAssertFalse(first.colorDescription.outputColorSpaceName.isEmpty)
        }
    }

    func testResourceEstimatesArePositiveDeterministicAndComposable_ICT_005() throws {
        let codec = CodecUnderTest.make()
        let requests = [
            ImageDecodeRequest(
                target: try TargetPixels(width: 1, height: 1),
                contentMode: .fit,
                colorPolicy: .preserveSource
            ),
            ImageDecodeRequest(
                target: try TargetPixels(width: 3, height: 1),
                contentMode: .fill,
                colorPolicy: .convertToSRGB
            ),
        ]
        for format in codec.codecDescriptor.capabilities.formats.sorted(by: formatOrder) {
            let data = try fixtureData(for: format)
            let probe = try codec.probe(data: data, limits: fixtureLimits())
            for request in requests {
                let first = try codec.resourceEstimate(probe: probe, request: request)
                let second = try codec.resourceEstimate(probe: probe, request: request)
                let generic = genericWorkingSetEstimate(probe: probe, request: request)
                let composed = try ImageDecodeResourceEstimate.conservativeMaximum(
                    genericBytes: generic,
                    backendBytes: first.workingSetBytes
                )

                XCTAssertEqual(first, second)
                XCTAssertGreaterThan(first.workingSetBytes, 0)
                XCTAssertGreaterThanOrEqual(composed.workingSetBytes, generic)
                XCTAssertGreaterThanOrEqual(
                    composed.workingSetBytes,
                    first.workingSetBytes
                )
            }
        }
    }

    func testProbeHardLimitsFailClosed_ICT_006() throws {
        let codec = CodecUnderTest.make()
        let format = try XCTUnwrap(
            codec.codecDescriptor.capabilities.formats.sorted(by: formatOrder).first
        )
        let data = try fixtureData(for: format)

        assertProbeFailure(
            codec,
            data: data,
            limits: DecodeLimits(
                maximumEncodedBytes: data.count - 1,
                maximumFrameCount: 8
            ),
            expected: .encodedBytesExceeded
        )
        assertProbeFailure(
            codec,
            data: data,
            limits: DecodeLimits(
                maximumFrameCount: 8,
                allowedFormats: Set(EncodedImageFormat.allCases).subtracting([format])
            ),
            expected: .unsupportedFormat
        )
        assertProbeFailure(
            codec,
            data: data,
            limits: DecodeLimits(
                maximumDimension: 1,
                maximumFrameCount: 8
            ),
            expected: .dimensionLimitExceeded
        )
        assertProbeFailure(
            codec,
            data: data,
            limits: DecodeLimits(
                maximumPixelCount: 1,
                maximumFrameCount: 8
            ),
            expected: .pixelLimitExceeded
        )
    }

    private func assertProbeFailure(
        _ codec: any ImageCodec,
        data: Data,
        limits: DecodeLimits,
        expected: ImageCraftError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try codec.probe(data: data, limits: limits),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? ImageCraftError, expected, file: file, line: line)
        }
    }

    private func fixtureLimits() -> DecodeLimits {
        DecodeLimits(maximumFrameCount: 8)
    }

    private func finiteRequests() -> [ImageDecodeCapabilityRequest] {
        var requests: [ImageDecodeCapabilityRequest] = []
        for format in EncodedImageFormat.allCases {
            for delivery in ImageDecodeDeliveryMode.allCases {
                for track in ImageDecodeTrackMode.allCases {
                    for metadata in allSubsets(ImageDecodeMetadataCapability.allCases) {
                        for range in ImageDecodeDynamicRange.allCases {
                            for output in ImageDecodeOutputRepresentation.allCases {
                                for cancellation in ImageDecodeCancellationMode.allCases {
                                    requests.append(
                                        ImageDecodeCapabilityRequest(
                                            format: format,
                                            deliveryMode: delivery,
                                            trackMode: track,
                                            requiredMetadata: metadata,
                                            dynamicRange: range,
                                            outputRepresentation: output,
                                            cancellationMode: cancellation
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        return requests
    }

    private func allSubsets<Element: Hashable>(_ values: [Element]) -> [Set<Element>] {
        (0..<(1 << values.count)).map { mask in
            Set(
                values.enumerated().compactMap { index, value in
                    mask & (1 << index) == 0 ? nil : value
                }
            )
        }
    }

    private func independentSupport(
        _ capabilities: ImageCodecCapabilities,
        _ request: ImageDecodeCapabilityRequest
    ) -> Bool {
        capabilities.formats.contains(request.format)
            && capabilities.deliveryModes.contains(request.deliveryMode)
            && (request.deliveryMode != .progressiveGenerations
                || capabilities.progressiveFormats.contains(request.format))
            && capabilities.trackModes.contains(request.trackMode)
            && request.requiredMetadata.isSubset(of: capabilities.metadata)
            && capabilities.dynamicRanges.contains(request.dynamicRange)
            && capabilities.outputRepresentations.contains(request.outputRepresentation)
            && capabilities.cancellationMode.rawValue >= request.cancellationMode.rawValue
    }

    private func fixtureData(for format: EncodedImageFormat) throws -> Data {
        let type: CFString =
            switch format {
            case .png: UTType.png.identifier as CFString
            case .jpeg: UTType.jpeg.identifier as CFString
            case .gif: UTType.gif.identifier as CFString
            }
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, type, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func genericWorkingSetEstimate(
        probe: ImageProbe,
        request: ImageDecodeRequest
    ) -> Int {
        let widthScale = Double(request.target.width) / Double(probe.pixelWidth)
        let heightScale = Double(request.target.height) / Double(probe.pixelHeight)
        let requestedScale =
            request.contentMode == .fit
            ? min(widthScale, heightScale)
            : max(widthScale, heightScale)
        let scale = min(1, max(0, requestedScale))
        let thumbnailWidth = max(
            1,
            min(probe.pixelWidth, Int(ceil(Double(probe.pixelWidth) * scale)))
        )
        let thumbnailHeight = max(
            1,
            min(probe.pixelHeight, Int(ceil(Double(probe.pixelHeight) * scale)))
        )
        let thumbnailBytes = saturatedProduct([thumbnailWidth, thumbnailHeight, 4])
        let outputBytes = saturatedProduct([
            min(thumbnailWidth, request.target.width),
            min(thumbnailHeight, request.target.height),
            4,
        ])
        return saturatedSum([thumbnailBytes, thumbnailBytes, outputBytes])
    }

    private func saturatedProduct(_ values: [Int]) -> Int {
        values.reduce(1) { partial, value in
            let (result, overflow) = partial.multipliedReportingOverflow(by: value)
            return overflow ? Int.max : result
        }
    }

    private func saturatedSum(_ values: [Int]) -> Int {
        values.reduce(0) { partial, value in
            let (result, overflow) = partial.addingReportingOverflow(value)
            return overflow ? Int.max : result
        }
    }

    private func formatOrder(
        _ lhs: EncodedImageFormat,
        _ rhs: EncodedImageFormat
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
