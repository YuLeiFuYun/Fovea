import Compression
import CoreGraphics
import CryptoKit
import Foundation
import ImageCraftCore

package enum DerivedRasterContainerError: Error, Equatable, Sendable {
    case invalidInput
    case unsupportedSchema
    case unsupportedFormat
    case limitExceeded
    case integrityMismatch
    case compressionFailed
}

/// 在任何派生光栅分配前执行的宿主侧硬限制。
package struct DerivedRasterContainerLimits: Equatable, Sendable {
    package let maximumContainerBytes: Int
    package let maximumDimension: Int
    package let maximumPixelCount: Int
    package let maximumDecodedBytes: Int

    package init(
        maximumContainerBytes: Int = 64 * 1_024 * 1_024,
        maximumDimension: Int = 16_384,
        maximumPixelCount: Int = 100_000_000,
        maximumDecodedBytes: Int = 300_000_000
    ) {
        self.maximumContainerBytes = min(1_024 * 1_024 * 1_024, max(1, maximumContainerBytes))
        self.maximumDimension = min(65_536, max(1, maximumDimension))
        self.maximumPixelCount = min(1_000_000_000, max(1, maximumPixelCount))
        self.maximumDecodedBytes = min(3_000_000_000, max(1, maximumDecodedBytes))
    }
}

/// 当前派生光栅只保留一种像素布局：tightly packed opaque sRGB RGB8。
/// Alpha 不进入持久字节流，因此 `.none` 是结构语义而不是需要运行时证明的属性。
package enum DerivedRasterPixelLayout: UInt16, Equatable, Sendable {
    case rgb24 = 4

    package var bytesPerPixel: Int { 3 }
}

/// 从当前派生光栅容器恢复出的精确归一化像素表面。
package struct DerivedRasterSurface: Equatable, Sendable {
    package let width: Int
    package let height: Int
    package let pixelData: Data
    package let pixelLayout: DerivedRasterPixelLayout
    package let pixelDigestHex: String
}

/// 已完成容器身份、header、几何、长度和压缩载荷完整性验证，但尚未展开像素的当前表面。
/// 当前格式把像素拆成独立 LZFSE chunk，使 direct `CGDataProvider` 可以按 byte position
/// 无共享游标地随机读取；表面只持有压缩容器和有界 chunk range 索引。
package struct DerivedRasterCompressedSurface: Sendable {
    package let width: Int
    package let height: Int
    package let pixelLayout: DerivedRasterPixelLayout
    package let pixelDigestHex: String
    package let decodedByteCount: Int
    package let decodedChunkByteCount: Int
    package let container: Data
    package let compressedChunkRanges: [Range<Int>]

    package var residentByteCount: Int {
        container.count + compressedChunkRanges.count * MemoryLayout<Range<Int>>.stride
    }

    package func decodedRange(forChunkAt index: Int) -> Range<Int>? {
        guard index >= 0, index < compressedChunkRanges.count else { return nil }
        let start = index.multipliedReportingOverflow(by: decodedChunkByteCount)
        guard !start.overflow, start.partialValue < decodedByteCount else { return nil }
        return start.partialValue..<min(decodedByteCount, start.partialValue + decodedChunkByteCount)
    }
}

/// 当前目标派生光栅容器。
///
/// Schema 7 只接受 independently chunked LZFSE + tightly packed opaque RGB24。Alpha 不进入
/// 持久字节流，因此 `.none` 是格式的结构语义；旧 schema、旧 RGBA/RGBX、旧 framed LZ4、
/// row-filtered payload 与历史 identity 都不再读取。固定头绑定尺寸、精确解码长度、chunk
/// 形状、压缩长度、像素 SHA-256 与完整 encoded-region SHA-256；Akashic 还可验证整个容器摘要。
package enum DerivedRasterContainer {
    private struct ParsedContainer {
        let surface: DerivedRasterCompressedSurface
        let expectedPixelDigest: Data
        let outerContentDigestVerified: Bool
    }

    private struct EncodedChunks {
        let table: Data
        let payload: Data
        let count: Int
        let totalByteCount: Int
    }

    private struct ParsedHeader {
        let width: Int
        let height: Int
        let rowByteCount: Int
        let decodedByteCount: Int
        let chunkCount: Int
        let payloadByteCount: Int
        let expectedPixelDigest: Data
        let expectedEncodedRegionDigest: Data
        let layout: DerivedRasterPixelLayout
    }
    package static let formatIdentity = DerivedRasterFormatIdentity(
        identifier: "fovea-chunked-lzfse-rgb8",
        semanticVersion: 7,
        pixelLayoutFingerprint: "rgb8-srgb-tight-chunked-1m-lzfse-v7"
    )!

    private static let preserveSourceEmbeddedICCFormatIdentity = DerivedRasterFormatIdentity(
        identifier: "fovea-chunked-lzfse-rgb8-preserve-srgb-embedded-icc",
        semanticVersion: 7,
        pixelLayoutFingerprint: "rgb8-srgb-tight-chunked-1m-lzfse-v7"
    )!
    private static let preserveSourceStandardSRGBFormatIdentity = DerivedRasterFormatIdentity(
        identifier: "fovea-chunked-lzfse-rgb8-preserve-srgb-standard-srgb",
        semanticVersion: 7,
        pixelLayoutFingerprint: "rgb8-srgb-tight-chunked-1m-lzfse-v7"
    )!
    private static let preserveSourceAbsentFormatIdentity = DerivedRasterFormatIdentity(
        identifier: "fovea-chunked-lzfse-rgb8-preserve-srgb-absent",
        semanticVersion: 7,
        pixelLayoutFingerprint: "rgb8-srgb-tight-chunked-1m-lzfse-v7"
    )!
    private static let preserveSourceUnknownFormatIdentity = DerivedRasterFormatIdentity(
        identifier: "fovea-chunked-lzfse-rgb8-preserve-srgb-unknown",
        semanticVersion: 7,
        pixelLayoutFingerprint: "rgb8-srgb-tight-chunked-1m-lzfse-v7"
    )!

    package static let currentSchemaVersion: UInt16 = 7
    package static let headerByteCount = 120
    package static let decodedChunkByteCount = 1_024 * 1_024

    package static func isCompatible(with key: DerivedRasterArtifactKey) -> Bool {
        switch key.renderKey.decodeKey.colorPolicy {
        case .convertToSRGB:
            key.format == formatIdentity
        case .preserveSource:
            sourceColorProfile(forPreserveSourceSRGBFormat: key.format) != nil
        }
    }

    package static func lookupFormatIdentities(
        for colorPolicy: ImageColorPolicy
    ) -> [DerivedRasterFormatIdentity] {
        switch colorPolicy {
        case .convertToSRGB:
            [formatIdentity]
        case .preserveSource:
            [
                preserveSourceEmbeddedICCFormatIdentity,
                preserveSourceStandardSRGBFormatIdentity,
                preserveSourceAbsentFormatIdentity,
                preserveSourceUnknownFormatIdentity,
            ]
        }
    }

    package static func creationFormatIdentity(
        for image: DecodedImage,
        colorPolicy: ImageColorPolicy
    ) -> DerivedRasterFormatIdentity? {
        guard image.colorDescription.outputColorSpaceName == CGColorSpace.sRGB as String else {
            return nil
        }
        switch colorPolicy {
        case .convertToSRGB:
            return formatIdentity
        case .preserveSource:
            switch image.colorDescription.sourceProfile {
            case .embeddedICC:
                return preserveSourceEmbeddedICCFormatIdentity
            case .standardSRGB:
                return preserveSourceStandardSRGBFormatIdentity
            case .absent:
                return preserveSourceAbsentFormatIdentity
            case .unknown:
                return preserveSourceUnknownFormatIdentity
            }
        }
    }

    package static func sourceColorProfile(
        for format: DerivedRasterFormatIdentity
    ) -> SourceColorProfile? {
        if format == formatIdentity { return .standardSRGB }
        return sourceColorProfile(forPreserveSourceSRGBFormat: format)
    }

    private static func sourceColorProfile(
        forPreserveSourceSRGBFormat format: DerivedRasterFormatIdentity
    ) -> SourceColorProfile? {
        if format == preserveSourceEmbeddedICCFormatIdentity { return .embeddedICC }
        if format == preserveSourceStandardSRGBFormatIdentity { return .standardSRGB }
        if format == preserveSourceAbsentFormatIdentity { return .absent }
        if format == preserveSourceUnknownFormatIdentity { return .unknown }
        return nil
    }

    private static let magic = Data([0x46, 0x56, 0x44, 0x52, 0x41, 0x53, 0x54, 0x37])
    private static let formatCode: UInt16 = 7

    package static func pixelLayout(
        for format: DerivedRasterFormatIdentity
    ) -> DerivedRasterPixelLayout? {
        guard format == formatIdentity
            || format == preserveSourceEmbeddedICCFormatIdentity
            || format == preserveSourceStandardSRGBFormatIdentity
            || format == preserveSourceAbsentFormatIdentity
            || format == preserveSourceUnknownFormatIdentity
        else { return nil }
        return .rgb24
    }

    package static func encode(
        pixelData: Data,
        width: Int,
        height: Int,
        format: DerivedRasterFormatIdentity = formatIdentity,
        limits: DerivedRasterContainerLimits = DerivedRasterContainerLimits()
    ) throws -> Data {
        guard let layout = pixelLayout(for: format) else {
            throw DerivedRasterContainerError.unsupportedFormat
        }
        let geometry = try DerivedRasterContainerCodec.validatedGeometry(
            width: width,
            height: height,
            decodedByteCount: pixelData.count,
            bytesPerPixel: layout.bytesPerPixel,
            limits: limits
        )
        let chunks = try encodeChunks(pixelData: pixelData, limits: limits)
        return makeContainer(
            pixelData: pixelData,
            width: width,
            height: height,
            rowByteCount: geometry.rowByteCount,
            layout: layout,
            chunks: chunks
        )
    }

    private static func encodeChunks(
        pixelData: Data,
        limits: DerivedRasterContainerLimits
    ) throws -> EncodedChunks {
        let chunkCountAddition = pixelData.count.addingReportingOverflow(decodedChunkByteCount - 1)
        guard !chunkCountAddition.overflow else {
            throw DerivedRasterContainerError.limitExceeded
        }
        let chunkCount = chunkCountAddition.partialValue / decodedChunkByteCount
        guard chunkCount > 0, chunkCount <= Int(UInt32.max) else {
            throw DerivedRasterContainerError.limitExceeded
        }
        let tableBytes = chunkCount.multipliedReportingOverflow(by: MemoryLayout<UInt32>.size)
        guard !tableBytes.overflow else { throw DerivedRasterContainerError.limitExceeded }
        let fixedBytes = headerByteCount.addingReportingOverflow(tableBytes.partialValue)
        guard !fixedBytes.overflow, fixedBytes.partialValue < limits.maximumContainerBytes else {
            throw DerivedRasterContainerError.limitExceeded
        }
        var chunkTable = Data()
        chunkTable.reserveCapacity(tableBytes.partialValue)
        var payload = Data()
        for chunkIndex in 0..<chunkCount {
            let start = chunkIndex * decodedChunkByteCount
            let end = min(pixelData.count, start + decodedChunkByteCount)
            let remainingBudget = limits.maximumContainerBytes - fixedBytes.partialValue - payload.count
            guard remainingBudget > 0 else { throw DerivedRasterContainerError.limitExceeded }
            let compressed = try DerivedRasterContainerCodec.compress(
                Data(pixelData[start..<end]),
                maximumOutputBytes: remainingBudget
            )
            guard compressed.count > 0, compressed.count <= Int(UInt32.max) else {
                throw DerivedRasterContainerError.limitExceeded
            }
            chunkTable.appendBigEndian(UInt32(compressed.count))
            payload.append(compressed)
        }
        let tableAndPayload = chunkTable.count.addingReportingOverflow(payload.count)
        guard !tableAndPayload.overflow else { throw DerivedRasterContainerError.limitExceeded }
        let total = headerByteCount.addingReportingOverflow(tableAndPayload.partialValue)
        guard !total.overflow, total.partialValue <= limits.maximumContainerBytes else {
            throw DerivedRasterContainerError.limitExceeded
        }
        return EncodedChunks(
            table: chunkTable,
            payload: payload,
            count: chunkCount,
            totalByteCount: total.partialValue
        )
    }

    private static func makeContainer(
        pixelData: Data,
        width: Int,
        height: Int,
        rowByteCount: Int,
        layout: DerivedRasterPixelLayout,
        chunks: EncodedChunks
    ) -> Data {
        var encodedRegionHasher = SHA256()
        encodedRegionHasher.update(data: chunks.table)
        encodedRegionHasher.update(data: chunks.payload)
        let encodedRegionDigest = encodedRegionHasher.finalize()
        var container = Data()
        container.reserveCapacity(chunks.totalByteCount)
        container.append(magic)
        container.appendBigEndian(currentSchemaVersion)
        container.appendBigEndian(formatCode)
        container.appendBigEndian(layout.rawValue)
        container.appendBigEndian(UInt16(0))
        container.appendBigEndian(UInt32(headerByteCount))
        container.appendBigEndian(UInt32(width))
        container.appendBigEndian(UInt32(height))
        container.appendBigEndian(UInt32(rowByteCount))
        container.appendBigEndian(UInt64(pixelData.count))
        container.appendBigEndian(UInt32(decodedChunkByteCount))
        container.appendBigEndian(UInt32(chunks.count))
        container.appendBigEndian(UInt64(chunks.payload.count))
        container.append(contentsOf: SHA256.hash(data: pixelData))
        container.append(contentsOf: encodedRegionDigest)
        precondition(container.count == headerByteCount)
        container.append(chunks.table)
        container.append(chunks.payload)
        return container
    }

    package static func decode(
        _ container: Data,
        expectedContainerDigestHex: String? = nil,
        containerContentDigestAlreadyVerified: Bool = false,
        expectedFormat: DerivedRasterFormatIdentity? = nil,
        verifyDecodedPixelDigest: Bool = false,
        limits: DerivedRasterContainerLimits = DerivedRasterContainerLimits()
    ) throws -> DerivedRasterSurface {
        let parsed = try parse(
            container,
            expectedContainerDigestHex: expectedContainerDigestHex,
            containerContentDigestAlreadyVerified: containerContentDigestAlreadyVerified,
            expectedFormat: expectedFormat,
            limits: limits
        )
        let compressed = parsed.surface
        var pixelData = Data(count: compressed.decodedByteCount)
        try pixelData.withUnsafeMutableBytes { output in
            for chunkIndex in compressed.compressedChunkRanges.indices {
                guard let decodedRange = compressed.decodedRange(forChunkAt: chunkIndex),
                    let base = output.baseAddress
                else { throw DerivedRasterContainerError.compressionFailed }
                let destination = UnsafeMutableRawBufferPointer(
                    start: base.advanced(by: decodedRange.lowerBound),
                    count: decodedRange.count
                )
                try decodeChunk(compressed, chunkIndex: chunkIndex, into: destination)
            }
        }
        guard pixelData.count == compressed.decodedByteCount else {
            throw DerivedRasterContainerError.integrityMismatch
        }
        // Creation/standalone validation has no authenticated outer content identity, so prove
        // the decoded bytes as well. Record-backed loads already authenticate the full container.
        if (verifyDecodedPixelDigest || !parsed.outerContentDigestVerified),
            Data(SHA256.hash(data: pixelData)) != parsed.expectedPixelDigest
        {
            throw DerivedRasterContainerError.integrityMismatch
        }
        return DerivedRasterSurface(
            width: compressed.width,
            height: compressed.height,
            pixelData: pixelData,
            pixelLayout: compressed.pixelLayout,
            pixelDigestHex: compressed.pixelDigestHex
        )
    }

    package static func validatedCompressedSurface(
        _ container: Data,
        expectedContainerDigestHex: String? = nil,
        containerContentDigestAlreadyVerified: Bool = false,
        expectedFormat: DerivedRasterFormatIdentity? = nil,
        limits: DerivedRasterContainerLimits = DerivedRasterContainerLimits()
    ) throws -> DerivedRasterCompressedSurface {
        try parse(
            container,
            expectedContainerDigestHex: expectedContainerDigestHex,
            containerContentDigestAlreadyVerified: containerContentDigestAlreadyVerified,
            expectedFormat: expectedFormat,
            limits: limits
        ).surface
    }

    private static func parse(
        _ container: Data,
        expectedContainerDigestHex: String?,
        containerContentDigestAlreadyVerified: Bool,
        expectedFormat: DerivedRasterFormatIdentity?,
        limits: DerivedRasterContainerLimits
    ) throws -> ParsedContainer {
        guard container.count >= headerByteCount,
            container.count <= limits.maximumContainerBytes
        else { throw DerivedRasterContainerError.limitExceeded }
        let outerContentDigestVerified = try DerivedRasterContainerCodec.outerDigestVerified(
            container,
            expectedDigestHex: expectedContainerDigestHex,
            contentDigestAlreadyVerified: containerContentDigestAlreadyVerified
        )
        var cursor = DerivedRasterByteCursor(data: container)
        let header = try readHeader(&cursor, expectedFormat: expectedFormat)
        let tableByteCount = try validateHeader(
            header,
            containerByteCount: container.count,
            limits: limits
        )
        try DerivedRasterContainerCodec.validateEncodedRegionDigest(
            container,
            expectedDigest: header.expectedEncodedRegionDigest,
            outerContentDigestVerified: outerContentDigestVerified,
            headerByteCount: headerByteCount
        )
        let compressedChunkRanges = try DerivedRasterContainerCodec.readChunkRanges(
            &cursor,
            chunkCount: header.chunkCount,
            payloadByteCount: header.payloadByteCount,
            tableByteCount: tableByteCount,
            containerByteCount: container.count,
            headerByteCount: headerByteCount
        )
        try DerivedRasterContainerCodec.validateChunkFrames(
            container,
            ranges: compressedChunkRanges,
            decodedByteCount: header.decodedByteCount,
            decodedChunkByteCount: decodedChunkByteCount
        )
        let compressed = DerivedRasterCompressedSurface(
            width: header.width,
            height: header.height,
            pixelLayout: header.layout,
            pixelDigestHex: lowercaseHexString(header.expectedPixelDigest),
            decodedByteCount: header.decodedByteCount,
            decodedChunkByteCount: decodedChunkByteCount,
            container: container,
            compressedChunkRanges: compressedChunkRanges
        )
        return ParsedContainer(
            surface: compressed,
            expectedPixelDigest: header.expectedPixelDigest,
            outerContentDigestVerified: outerContentDigestVerified
        )
    }


    private static func readHeader(
        _ cursor: inout DerivedRasterByteCursor,
        expectedFormat: DerivedRasterFormatIdentity?
    ) throws -> ParsedHeader {
        guard try cursor.readData(count: magic.count) == magic else {
            throw DerivedRasterContainerError.unsupportedFormat
        }
        guard try cursor.readUInt16() == currentSchemaVersion else {
            throw DerivedRasterContainerError.unsupportedSchema
        }
        let storedFormatCode = try cursor.readUInt16()
        let storedLayoutCode = try cursor.readUInt16()
        let layout = DerivedRasterPixelLayout.rgb24
        guard storedFormatCode == formatCode, storedLayoutCode == layout.rawValue else {
            throw DerivedRasterContainerError.unsupportedFormat
        }
        if let expectedFormat, pixelLayout(for: expectedFormat) != layout {
            throw DerivedRasterContainerError.unsupportedFormat
        }
        guard try cursor.readUInt16() == 0,
            try cursor.readUInt32() == UInt32(headerByteCount)
        else { throw DerivedRasterContainerError.unsupportedFormat }
        let header = ParsedHeader(
            width: try cursor.readBoundedInt32(),
            height: try cursor.readBoundedInt32(),
            rowByteCount: try cursor.readBoundedInt32(),
            decodedByteCount: try cursor.readBoundedInt64(),
            chunkCount: try readStoredChunkShape(&cursor),
            payloadByteCount: try cursor.readBoundedInt64(),
            expectedPixelDigest: try cursor.readData(count: SHA256.byteCount),
            expectedEncodedRegionDigest: try cursor.readData(count: SHA256.byteCount),
            layout: layout
        )
        guard cursor.offset == headerByteCount else {
            throw DerivedRasterContainerError.unsupportedFormat
        }
        return header
    }

    private static func readStoredChunkShape(_ cursor: inout DerivedRasterByteCursor) throws -> Int {
        guard try cursor.readBoundedInt32() == decodedChunkByteCount else {
            throw DerivedRasterContainerError.unsupportedFormat
        }
        return try cursor.readBoundedInt32()
    }

    private static func validateHeader(
        _ header: ParsedHeader,
        containerByteCount: Int,
        limits: DerivedRasterContainerLimits
    ) throws -> Int {
        let geometry = try DerivedRasterContainerCodec.validatedGeometry(
            width: header.width,
            height: header.height,
            decodedByteCount: header.decodedByteCount,
            bytesPerPixel: header.layout.bytesPerPixel,
            limits: limits
        )
        guard header.rowByteCount == geometry.rowByteCount else {
            throw DerivedRasterContainerError.integrityMismatch
        }
        let expectedCount = header.decodedByteCount.addingReportingOverflow(
            decodedChunkByteCount - 1
        )
        guard !expectedCount.overflow else { throw DerivedRasterContainerError.limitExceeded }
        guard header.chunkCount == expectedCount.partialValue / decodedChunkByteCount,
            header.chunkCount > 0
        else { throw DerivedRasterContainerError.integrityMismatch }
        guard header.payloadByteCount > 0 else { throw DerivedRasterContainerError.limitExceeded }
        let tableBytes = header.chunkCount.multipliedReportingOverflow(
            by: MemoryLayout<UInt32>.size
        )
        guard !tableBytes.overflow else { throw DerivedRasterContainerError.limitExceeded }
        let encodedBytes = tableBytes.partialValue.addingReportingOverflow(header.payloadByteCount)
        guard !encodedBytes.overflow else { throw DerivedRasterContainerError.limitExceeded }
        let total = headerByteCount.addingReportingOverflow(encodedBytes.partialValue)
        guard !total.overflow, total.partialValue == containerByteCount else {
            throw DerivedRasterContainerError.integrityMismatch
        }
        return tableBytes.partialValue
    }




    /// Validates only LZFSE's outer block framing; it intentionally does not expand pixels.
    ///
    /// The authenticated chunk range must contain one or more non-empty blocks followed by a
    /// `bvx$` marker that lands exactly on the range end. For V1/V2 blocks, the encoded block
    /// size is the header plus literal and L/M/D payload byte counts. Payload semantics remain
    /// the Compression decoder's responsibility; this parser exists so its permissive handling
    /// of bytes after `bvx$` cannot weaken the container's canonical exact-input contract.





    /// 把一个已经通过外层 LZFSE frame canonicality 验证的独立 chunk 单步解码到
    /// 调用方最终目标 buffer。frame parser 证明 EOS 恰好落在 chunk 末尾；这里要求
    /// buffer API 写出精确 decoded bytes。direct provider 和 eager 自验证共用同一实现。
    package static func decodeChunk(
        _ surface: DerivedRasterCompressedSurface,
        chunkIndex: Int,
        into destination: UnsafeMutableRawBufferPointer
    ) throws {
        try DerivedRasterContainerCodec.decodeChunk(
            surface,
            chunkIndex: chunkIndex,
            into: destination
        )
    }
}
