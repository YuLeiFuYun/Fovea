import CoreGraphics
import CryptoKit
import FoveaCore
import ImageCraftCore
import XCTest

final class DerivedRasterContainerTests: XCTestCase {
    func testRoundTripIsExactDeterministicAndVersioned_W11_PT_008() throws {
        let pixels = makeRGBPixels(width: 37, height: 23)
        let first = try DerivedRasterContainer.encode(
            pixelData: pixels,
            width: 37,
            height: 23
        )
        let second = try DerivedRasterContainer.encode(
            pixelData: pixels,
            width: 37,
            height: 23
        )
        let decoded = try DerivedRasterContainer.decode(
            first,
            expectedFormat: DerivedRasterContainer.formatIdentity
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(decoded.width, 37)
        XCTAssertEqual(decoded.height, 23)
        XCTAssertEqual(decoded.pixelLayout, .rgb24)
        XCTAssertEqual(decoded.pixelData, pixels)
        XCTAssertEqual(decoded.pixelDigestHex, sha256(pixels))
        XCTAssertEqual(DerivedRasterContainer.currentSchemaVersion, 7)
        XCTAssertEqual(
            DerivedRasterContainer.formatIdentity.identifier,
            "fovea-chunked-lzfse-rgb8"
        )
        XCTAssertEqual(
            DerivedRasterContainer.pixelLayout(for: DerivedRasterContainer.formatIdentity),
            .rgb24
        )
    }

    func testRGB24BridgeRejectsOverflowingSurfaceGeometry_G2_RESOURCE_001() throws {
        let normal = try DerivedRasterPixelBridge.validatedRGB24Geometry(width: 37, height: 23)
        XCTAssertEqual(normal.rowBytes, 111)
        XCTAssertEqual(normal.decodedByteCount, 2_553)

        XCTAssertThrowsError(
            try DerivedRasterPixelBridge.validatedRGB24Geometry(width: Int.max, height: 2)
        ) { error in
            XCTAssertEqual(error as? DerivedRasterContainerError, .limitExceeded)
        }
        XCTAssertThrowsError(
            try DerivedRasterPixelBridge.validatedRGB24Geometry(width: Int.max / 3, height: 4)
        ) { error in
            XCTAssertEqual(error as? DerivedRasterContainerError, .limitExceeded)
        }
    }

    func testRGB24BridgePreservesOpaqueDisplayPixels_W11_PT_058() throws {
        let image = try makeDecodedImage(
            colorSpace: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            sourceProfile: .embeddedICC
        )
        let rgbSurface = try DerivedRasterPixelBridge.surface(
            from: image,
            format: DerivedRasterContainer.formatIdentity
        )
        let rgbImage = try DerivedRasterPixelBridge.image(from: rgbSurface)

        XCTAssertEqual(rgbSurface.pixelLayout, .rgb24)
        XCTAssertEqual(rgbSurface.pixelData.count, image.pixelWidth * image.pixelHeight * 3)
        XCTAssertEqual(rgbImage.alphaMode, .none)
        XCTAssertEqual(
            try materializedRGBA(image.cgImage),
            try materializedRGBA(rgbImage.cgImage)
        )
    }

    func testLazyRGB24ProviderMaterializesExactlyAcrossRepeatedDraws_W11_PT_062() throws {
        let image = try makeDecodedImage(
            colorSpace: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            sourceProfile: .embeddedICC
        )
        let surface = try DerivedRasterPixelBridge.surface(
            from: image,
            format: DerivedRasterContainer.formatIdentity
        )
        let container = try DerivedRasterContainer.encode(
            pixelData: surface.pixelData,
            width: surface.width,
            height: surface.height
        )
        let compressed = try DerivedRasterContainer.validatedCompressedSurface(
            container,
            expectedContainerDigestHex: sha256(container),
            expectedFormat: DerivedRasterContainer.formatIdentity
        )
        let lazy = try DerivedRasterPixelBridge.lazyImage(
            from: compressed,
            sourceColorProfile: .embeddedICC
        )
        let expected = try materializedRGBA(image.cgImage)

        XCTAssertEqual(lazy.alphaMode, .none)
        XCTAssertEqual(lazy.pixelWidth, image.pixelWidth)
        XCTAssertEqual(lazy.pixelHeight, image.pixelHeight)
        XCTAssertEqual(try materializedRGBA(lazy.cgImage), expected)
        XCTAssertEqual(try materializedRGBA(lazy.cgImage), expected)
    }

    func testChunkedContainerRoundTripsAcrossMultipleIndependentChunks_W11_PT_068() throws {
        let width = 1_024
        let height = 400
        let pixels = makeRGBPixels(width: width, height: height)
        XCTAssertGreaterThan(pixels.count, DerivedRasterContainer.decodedChunkByteCount)

        let container = try DerivedRasterContainer.encode(
            pixelData: pixels,
            width: width,
            height: height
        )
        let compressed = try DerivedRasterContainer.validatedCompressedSurface(
            container,
            expectedContainerDigestHex: sha256(container),
            expectedFormat: DerivedRasterContainer.formatIdentity
        )
        let decoded = try DerivedRasterContainer.decode(
            container,
            expectedContainerDigestHex: sha256(container),
            expectedFormat: DerivedRasterContainer.formatIdentity,
            verifyDecodedPixelDigest: true
        )

        XCTAssertEqual(compressed.decodedChunkByteCount, 1_024 * 1_024)
        XCTAssertEqual(compressed.compressedChunkRanges.count, 2)
        XCTAssertEqual(decoded.pixelData, pixels)
    }

    func testLazyRGB24ProviderConcurrentDrawsRemainExact_W11_PT_067() throws {
        let width = 1_024
        let height = 400
        let pixels = makeRGBPixels(width: width, height: height)
        let container = try DerivedRasterContainer.encode(
            pixelData: pixels,
            width: width,
            height: height
        )
        let compressed = try DerivedRasterContainer.validatedCompressedSurface(
            container,
            expectedContainerDigestHex: sha256(container),
            expectedFormat: DerivedRasterContainer.formatIdentity
        )
        XCTAssertEqual(compressed.compressedChunkRanges.count, 2)
        let lazy = try DerivedRasterPixelBridge.lazyImage(from: compressed)
        let expected = rgbaFromRGB24(pixels)
        let shared = ConcurrentCGImageBox(lazy.cgImage)
        let result = ConcurrentDrawResult()

        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            for _ in 0..<2 {
                do {
                    let pixels = try Self.materializedRGBAForConcurrentDraw(shared.image)
                    if pixels != expected {
                        result.fail("pixel-mismatch")
                        return
                    }
                } catch {
                    result.fail(String(describing: error))
                    return
                }
            }
        }

        XCTAssertNil(result.failure())
    }

    func testEncodeRejectsMismatchedGeometryAndBudgets_W11_PT_009() throws {
        let pixels = makeRGBPixels(width: 8, height: 8)
        XCTAssertThrowsError(
            try DerivedRasterContainer.encode(
                pixelData: Data(pixels.dropLast()),
                width: 8,
                height: 8
            )
        ) { error in
            XCTAssertEqual(error as? DerivedRasterContainerError, .invalidInput)
        }
        XCTAssertThrowsError(
            try DerivedRasterContainer.encode(
                pixelData: pixels,
                width: 8,
                height: 8,
                limits: DerivedRasterContainerLimits(maximumContainerBytes: 120)
            )
        )
        XCTAssertThrowsError(
            try DerivedRasterContainer.encode(
                pixelData: pixels,
                width: 8,
                height: 8,
                limits: DerivedRasterContainerLimits(maximumDimension: 7)
            )
        )
    }

    func testRGB24RejectsFourBytePixelPayload_W11_PT_071() throws {
        let rgb = makeRGBPixels(width: 19, height: 17)
        let rgba = rgbaFromRGB24(rgb)
        XCTAssertEqual(rgba.count, 19 * 17 * 4)
        XCTAssertThrowsError(
            try DerivedRasterContainer.encode(pixelData: rgba, width: 19, height: 17)
        ) { error in
            XCTAssertEqual(error as? DerivedRasterContainerError, .invalidInput)
        }
        XCTAssertNoThrow(
            try DerivedRasterContainer.encode(pixelData: rgb, width: 19, height: 17)
        )
    }

    func testDecodeRejectsUnknownSchemaFormatAndHeaderShape_W11_PT_010() throws {
        let original = try makeContainer()
        for (offset, replacement, expected) in [
            (0, UInt8(0), DerivedRasterContainerError.unsupportedFormat),
            (7, UInt8(0x31), DerivedRasterContainerError.unsupportedFormat),
            (9, UInt8(3), DerivedRasterContainerError.unsupportedSchema),
            (9, UInt8(8), DerivedRasterContainerError.unsupportedSchema),
            (11, UInt8(3), DerivedRasterContainerError.unsupportedFormat),
            (13, UInt8(1), DerivedRasterContainerError.unsupportedFormat),
            (15, UInt8(1), DerivedRasterContainerError.unsupportedFormat),
            (19, UInt8(119), DerivedRasterContainerError.unsupportedFormat),
        ] {
            var mutated = original
            mutated[offset] = replacement
            XCTAssertThrowsError(try DerivedRasterContainer.decode(mutated)) { error in
                XCTAssertEqual(error as? DerivedRasterContainerError, expected)
            }
        }
    }

    func testDecodeRejectsTruncationTrailingBytesAndDigestTampering_W11_PT_011() throws {
        let original = try makeContainer()
        XCTAssertThrowsError(try DerivedRasterContainer.decode(original.dropLast()))

        var trailing = original
        trailing.append(0)
        XCTAssertThrowsError(try DerivedRasterContainer.decode(trailing)) { error in
            XCTAssertEqual(error as? DerivedRasterContainerError, .integrityMismatch)
        }

        var payloadTampered = original
        payloadTampered[payloadTampered.count - 1] ^= 0xff
        XCTAssertThrowsError(try DerivedRasterContainer.decode(payloadTampered)) { error in
            XCTAssertEqual(error as? DerivedRasterContainerError, .integrityMismatch)
        }

        var pixelDigestTampered = original
        pixelDigestTampered[56] ^= 0xff
        XCTAssertThrowsError(try DerivedRasterContainer.decode(pixelDigestTampered)) { error in
            XCTAssertEqual(error as? DerivedRasterContainerError, .integrityMismatch)
        }
    }

    func testDecodeRejectsHostileDimensionsBeforeAllocation_W11_PT_012() throws {
        var container = try makeContainer()
        writeUInt32(UInt32.max, to: &container, at: 20)
        XCTAssertThrowsError(
            try DerivedRasterContainer.decode(
                container,
                limits: DerivedRasterContainerLimits(maximumDimension: 16_384)
            )
        ) { error in
            XCTAssertEqual(error as? DerivedRasterContainerError, .limitExceeded)
        }
    }

    func testDecodeRejectsAuthenticatedTrailingCompressedBytes_W11_PT_014() throws {
        var container = try makeContainer()
        let chunkTableStart = DerivedRasterContainer.headerByteCount
        let payloadStart = chunkTableStart + MemoryLayout<UInt32>.size
        var chunk = Data(container[payloadStart...])
        chunk.append(0)
        writeUInt32(UInt32(chunk.count), to: &container, at: chunkTableStart)
        writeUInt64(UInt64(chunk.count), to: &container, at: 48)
        container.replaceSubrange(payloadStart..<container.count, with: chunk)
        let encodedRegion = Data(container[chunkTableStart...])
        let encodedRegionDigest = Data(SHA256.hash(data: encodedRegion))
        container.replaceSubrange(88..<120, with: encodedRegionDigest)

        let authenticatedTamperedDigest = sha256(container)
        XCTAssertThrowsError(
            try DerivedRasterContainer.decode(
                container,
                expectedContainerDigestHex: authenticatedTamperedDigest,
                containerContentDigestAlreadyVerified: true
            )
        ) { error in
            XCTAssertEqual(error as? DerivedRasterContainerError, .compressionFailed)
        }
    }

    func testDecodeRejectsAuthenticatedChunkTableBoundaryTampering_W11_PT_069() throws {
        var container = try makeContainer()
        let chunkTableStart = DerivedRasterContainer.headerByteCount
        let originalChunkByteCount = readUInt32(container, at: chunkTableStart)
        writeUInt32(originalChunkByteCount + 1, to: &container, at: chunkTableStart)
        let encodedRegion = Data(container[chunkTableStart...])
        container.replaceSubrange(
            88..<120,
            with: Data(SHA256.hash(data: encodedRegion))
        )
        let authenticatedTamperedDigest = sha256(container)

        XCTAssertThrowsError(
            try DerivedRasterContainer.decode(
                container,
                expectedContainerDigestHex: authenticatedTamperedDigest,
                containerContentDigestAlreadyVerified: true
            )
        ) { error in
            XCTAssertEqual(error as? DerivedRasterContainerError, .integrityMismatch)
        }
    }

    func testDecodeRejectsAuthenticatedLZFSEBlockMagicTampering_W11_PT_070() throws {
        var container = try makeContainer()
        let chunkTableStart = DerivedRasterContainer.headerByteCount
        let payloadStart = chunkTableStart + MemoryLayout<UInt32>.size
        XCTAssertEqual(Array(container[payloadStart..<(payloadStart + 3)]), [0x62, 0x76, 0x78])
        container[payloadStart] ^= 0xff

        let encodedRegion = Data(container[chunkTableStart...])
        container.replaceSubrange(
            88..<120,
            with: Data(SHA256.hash(data: encodedRegion))
        )
        let authenticatedTamperedDigest = sha256(container)

        XCTAssertThrowsError(
            try DerivedRasterContainer.decode(
                container,
                expectedContainerDigestHex: authenticatedTamperedDigest,
                containerContentDigestAlreadyVerified: true
            )
        ) { error in
            XCTAssertEqual(error as? DerivedRasterContainerError, .compressionFailed)
        }
    }

    func testDecodeRejectsContainerLargerThanHostBudget_W11_PT_013() throws {
        let container = try makeContainer()
        XCTAssertThrowsError(
            try DerivedRasterContainer.decode(
                container,
                limits: DerivedRasterContainerLimits(
                    maximumContainerBytes: container.count - 1
                )
            )
        ) { error in
            XCTAssertEqual(error as? DerivedRasterContainerError, .limitExceeded)
        }
    }

    func testPreserveSourceSRGBFormatSelectionBindsSourceProfile_W11_PT_053() throws {
        let profiles: [SourceColorProfile] = [.embeddedICC, .standardSRGB, .absent, .unknown]
        var selectedFormats = Set<DerivedRasterFormatIdentity>()

        for profile in profiles {
            let image = try makeDecodedImage(
                colorSpace: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                sourceProfile: profile
            )
            let format = try XCTUnwrap(
                DerivedRasterContainer.creationFormatIdentity(
                    for: image,
                    colorPolicy: .preserveSource
                )
            )
            XCTAssertEqual(DerivedRasterContainer.sourceColorProfile(for: format), profile)
            XCTAssertTrue(
                DerivedRasterContainer.lookupFormatIdentities(for: .preserveSource).contains(format)
            )
            selectedFormats.insert(format)
        }

        XCTAssertEqual(selectedFormats.count, profiles.count)
        let convertImage = try makeDecodedImage(
            colorSpace: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            sourceProfile: .standardSRGB
        )
        XCTAssertEqual(
            DerivedRasterContainer.creationFormatIdentity(
                for: convertImage,
                colorPolicy: .convertToSRGB
            ),
            DerivedRasterContainer.formatIdentity
        )
        XCTAssertEqual(
            DerivedRasterContainer.lookupFormatIdentities(for: .convertToSRGB),
            [DerivedRasterContainer.formatIdentity]
        )
    }

    func testPreserveSourceWideGamutHasNoSRGBDerivedCreationFormat_W11_PT_054() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let image = try makeDecodedImage(colorSpace: p3, sourceProfile: .embeddedICC)

        XCTAssertNil(
            DerivedRasterContainer.creationFormatIdentity(
                for: image,
                colorPolicy: .preserveSource
            )
        )
        XCTAssertNil(
            DerivedRasterContainer.creationFormatIdentity(
                for: image,
                colorPolicy: .convertToSRGB
            )
        )
    }

    private func makeContainer() throws -> Data {
        try DerivedRasterContainer.encode(
            pixelData: makeRGBPixels(width: 19, height: 17),
            width: 19,
            height: 17
        )
    }

    private func makeDecodedImage(
        colorSpace: CGColorSpace,
        sourceProfile: SourceColorProfile
    ) throws -> DecodedImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(red: 0.15, green: 0.45, blue: 0.75, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return DecodedImage(
            cgImage: try XCTUnwrap(context.makeImage()),
            sourceColorProfile: sourceProfile
        )
    }

    private func makeRGBPixels(width: Int, height: Int) -> Data {
        var data = Data(count: width * height * 3)
        for pixel in 0..<(width * height) {
            let offset = pixel * 3
            data[offset] = UInt8(truncatingIfNeeded: pixel * 17 + 3)
            data[offset + 1] = UInt8(truncatingIfNeeded: pixel * 31 + 7)
            data[offset + 2] = UInt8(truncatingIfNeeded: pixel * 47 + 11)
        }
        return data
    }

    private func rgbaFromRGB24(_ rgb: Data) -> Data {
        precondition(rgb.count.isMultiple(of: 3))
        var rgba = Data(count: rgb.count / 3 * 4)
        for pixel in 0..<(rgb.count / 3) {
            let source = pixel * 3
            let destination = pixel * 4
            rgba[destination] = rgb[source]
            rgba[destination + 1] = rgb[source + 1]
            rgba[destination + 2] = rgb[source + 2]
            rgba[destination + 3] = 0xff
        }
        return rgba
    }

    private func materializedRGBA(_ image: CGImage) throws -> Data {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bytesPerRow = image.width * 4
        var pixels = Data(count: bytesPerRow * image.height)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let base = storage.baseAddress,
                let context = CGContext(
                    data: base,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                )
            else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        XCTAssertTrue(rendered)
        return pixels
    }

    private static func materializedRGBAForConcurrentDraw(_ image: CGImage) throws -> Data {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ConcurrentDrawError.unavailable
        }
        let bytesPerRow = image.width * 4
        var pixels = Data(count: bytesPerRow * image.height)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let base = storage.baseAddress,
                let context = CGContext(
                    data: base,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                )
            else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        guard rendered else { throw ConcurrentDrawError.unavailable }
        return pixels
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writeUInt64(_ value: UInt64, to data: inout Data, at offset: Int) {
        for index in 0..<8 {
            let shift = UInt64((7 - index) * 8)
            data[offset + index] = UInt8((value >> shift) & 0xff)
        }
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value = (value << 8) | UInt32(data[offset + index])
        }
        return value
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 24) & 0xff)
        data[offset + 1] = UInt8((value >> 16) & 0xff)
        data[offset + 2] = UInt8((value >> 8) & 0xff)
        data[offset + 3] = UInt8(value & 0xff)
    }
}

private enum ConcurrentDrawError: Error {
    case unavailable
}

private final class ConcurrentCGImageBox: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

private final class ConcurrentDrawResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailure: String?

    func fail(_ failure: String) {
        lock.lock()
        if storedFailure == nil { storedFailure = failure }
        lock.unlock()
    }

    func failure() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }
}
