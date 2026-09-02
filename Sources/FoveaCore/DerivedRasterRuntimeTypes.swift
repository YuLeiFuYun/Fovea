import Compression
import CryptoKit
import Foundation
import ImageCraftCore

/// 默认关闭的包内派生光栅运行参数。
///
/// 调用方必须显式提供每工件字节、创建时间和持久读取开销预算；复用次数只来自运行时真实观测；
/// 公共组合根不构造该配置，因此现有加载语义保持不变。
package struct DerivedRasterRuntimeConfiguration: Equatable, Sendable {
    package let maximumContainerBytes: Int
    package let maximumContainerToOriginalPermille: Int
    package let maximumCreationNanoseconds: UInt64
    package let estimatedPersistentReadOverheadNanoseconds: UInt64
    package let safetyMarginHits: Int
    package let maximumConcurrentCreations: Int
    package let maximumQueuedCreations: Int
    package let maximumHotContainerMemoryBytes: Int

    package init(
        maximumContainerBytes: Int,
        maximumContainerToOriginalPermille: Int,
        maximumCreationNanoseconds: UInt64,
        estimatedPersistentReadOverheadNanoseconds: UInt64,
        safetyMarginHits: Int = DerivedRasterAdmissionPolicy.defaultSafetyMarginHits,
        maximumConcurrentCreations: Int = 1,
        maximumQueuedCreations: Int = 8,
        maximumHotContainerMemoryBytes: Int = 4 * 1024 * 1024
    ) {
        self.maximumContainerBytes = min(1024 * 1024 * 1024, max(1, maximumContainerBytes))
        self.maximumContainerToOriginalPermille = min(
            10000,
            max(1, maximumContainerToOriginalPermille)
        )
        self.maximumCreationNanoseconds = maximumCreationNanoseconds
        self.estimatedPersistentReadOverheadNanoseconds =
            estimatedPersistentReadOverheadNanoseconds
        self.safetyMarginHits = max(0, safetyMarginHits)
        self.maximumConcurrentCreations = min(64, max(1, maximumConcurrentCreations))
        self.maximumQueuedCreations = min(10000, max(0, maximumQueuedCreations))
        self.maximumHotContainerMemoryBytes = min(
            64 * 1024 * 1024,
            max(1, maximumHotContainerMemoryBytes)
        )
    }
}

package struct DerivedRasterCostEstimate: Equatable, Sendable {
    package let originalDecodeNanoseconds: UInt64
    package let derivedReadNanoseconds: UInt64

    package init(originalDecodeNanoseconds: UInt64, derivedReadNanoseconds: UInt64) {
        self.originalDecodeNanoseconds = originalDecodeNanoseconds
        self.derivedReadNanoseconds = derivedReadNanoseconds
    }
}

/// 为精确 RenderKey 提供可审计成本样本；默认实现只使用本次实测值。
package protocol DerivedRasterCostEstimating: Sendable {
    func estimate(
        key: DerivedRasterArtifactKey,
        measuredOriginalDecodeNanoseconds: UInt64,
        measuredDerivedReadNanoseconds: UInt64
    ) -> DerivedRasterCostEstimate?
}

package struct LiveDerivedRasterCostEstimator: DerivedRasterCostEstimating {
    package init() {}

    package func estimate(
        key _: DerivedRasterArtifactKey,
        measuredOriginalDecodeNanoseconds: UInt64,
        measuredDerivedReadNanoseconds: UInt64
    ) -> DerivedRasterCostEstimate? {
        guard measuredOriginalDecodeNanoseconds > 0, measuredDerivedReadNanoseconds > 0 else {
            return nil
        }
        return DerivedRasterCostEstimate(
            originalDecodeNanoseconds: measuredOriginalDecodeNanoseconds,
            derivedReadNanoseconds: measuredDerivedReadNanoseconds
        )
    }
}

package struct DerivedRasterLoadedImage: Sendable {
    package let image: DecodedImage
    package let key: DerivedRasterArtifactKey
}

// 低层 container framing 与压缩机制放在 format facade 之外，使高层 container policy 可独立于 byte-stream plumbing 审查。
enum DerivedRasterContainerCodec {
    private struct BlockDescriptor {
        let decodedByteCount: Int
        let encodedByteCount: Int
    }

    private static let maximumLZFSEBlockCountPerChunk = 4_096
    private static let lzfseV1HeaderByteCount = 772
    private static let lzfseV2FixedHeaderByteCount = 32
    private static let lzfseV2MaximumHeaderByteCount = 752
    private static let lzfseEndOfStreamBlockMagic: UInt32 = 0x2478_7662  // bvx$
    private static let lzfseUncompressedBlockMagic: UInt32 = 0x2d78_7662  // bvx-
    private static let lzfseCompressedV1BlockMagic: UInt32 = 0x3178_7662  // bvx1
    private static let lzfseCompressedV2BlockMagic: UInt32 = 0x3278_7662  // bvx2
    private static let lzfseCompressedLZVNBlockMagic: UInt32 = 0x6e78_7662  // bvxn
    static func validateLZFSEFrame(
        in data: UnsafeRawBufferPointer,
        range: Range<Int>,
        expectedDecodedByteCount: Int
    ) throws {
        guard !range.isEmpty, expectedDecodedByteCount > 0 else {
            throw DerivedRasterContainerError.compressionFailed
        }
        var offset = range.lowerBound
        var decodedByteCount = 0
        var blockCount = 0

        while true {
            let magic = try readLittleEndianUInt32(data, at: offset, limit: range.upperBound)
            if magic == lzfseEndOfStreamBlockMagic {
                try validateEndOfStream(
                    offset: offset,
                    range: range,
                    blockCount: blockCount,
                    decodedByteCount: decodedByteCount,
                    expectedDecodedByteCount: expectedDecodedByteCount
                )
                return
            }

            blockCount += 1
            guard blockCount <= maximumLZFSEBlockCountPerChunk else {
                throw DerivedRasterContainerError.compressionFailed
            }
            let descriptor = try blockDescriptor(
                magic: magic,
                data: data,
                offset: offset,
                limit: range.upperBound
            )
            decodedByteCount = try addingDecodedBytes(
                descriptor.decodedByteCount,
                to: decodedByteCount,
                maximum: expectedDecodedByteCount
            )
            offset = try addingEncodedBytes(
                descriptor.encodedByteCount,
                to: offset,
                limit: range.upperBound
            )
        }
    }

    private static func validateEndOfStream(
        offset: Int,
        range: Range<Int>,
        blockCount: Int,
        decodedByteCount: Int,
        expectedDecodedByteCount: Int
    ) throws {
        let end = offset.addingReportingOverflow(4)
        guard blockCount > 0,
            !end.overflow,
            end.partialValue == range.upperBound,
            decodedByteCount == expectedDecodedByteCount
        else { throw DerivedRasterContainerError.compressionFailed }
    }

    private static func blockDescriptor(
        magic: UInt32,
        data: UnsafeRawBufferPointer,
        offset: Int,
        limit: Int
    ) throws -> BlockDescriptor {
        switch magic {
        case lzfseUncompressedBlockMagic:
            return try uncompressedDescriptor(data: data, offset: offset, limit: limit)
        case lzfseCompressedLZVNBlockMagic:
            return try lzvnDescriptor(data: data, offset: offset, limit: limit)
        case lzfseCompressedV1BlockMagic:
            return try v1Descriptor(data: data, offset: offset, limit: limit)
        case lzfseCompressedV2BlockMagic:
            return try v2Descriptor(data: data, offset: offset, limit: limit)
        default:
            throw DerivedRasterContainerError.compressionFailed
        }
    }

    private static func uncompressedDescriptor(
        data: UnsafeRawBufferPointer,
        offset: Int,
        limit: Int
    ) throws -> BlockDescriptor {
        let decoded = Int(try readLittleEndianUInt32(data, at: offset + 4, limit: limit))
        let size = 8.addingReportingOverflow(decoded)
        guard decoded > 0, !size.overflow else {
            throw DerivedRasterContainerError.compressionFailed
        }
        return BlockDescriptor(decodedByteCount: decoded, encodedByteCount: size.partialValue)
    }

    private static func lzvnDescriptor(
        data: UnsafeRawBufferPointer,
        offset: Int,
        limit: Int
    ) throws -> BlockDescriptor {
        let decoded = Int(try readLittleEndianUInt32(data, at: offset + 4, limit: limit))
        let payload = Int(try readLittleEndianUInt32(data, at: offset + 8, limit: limit))
        let size = 12.addingReportingOverflow(payload)
        guard decoded > 0, payload > 0, !size.overflow else {
            throw DerivedRasterContainerError.compressionFailed
        }
        return BlockDescriptor(decodedByteCount: decoded, encodedByteCount: size.partialValue)
    }

    private static func v1Descriptor(
        data: UnsafeRawBufferPointer,
        offset: Int,
        limit: Int
    ) throws -> BlockDescriptor {
        let decoded = Int(try readLittleEndianUInt32(data, at: offset + 4, limit: limit))
        let payload = Int(try readLittleEndianUInt32(data, at: offset + 8, limit: limit))
        let literals = Int(try readLittleEndianUInt32(data, at: offset + 20, limit: limit))
        let lmd = Int(try readLittleEndianUInt32(data, at: offset + 24, limit: limit))
        let payloadSum = literals.addingReportingOverflow(lmd)
        let size = lzfseV1HeaderByteCount.addingReportingOverflow(payload)
        guard decoded > 0, !payloadSum.overflow, payload == payloadSum.partialValue,
            !size.overflow
        else { throw DerivedRasterContainerError.compressionFailed }
        return BlockDescriptor(decodedByteCount: decoded, encodedByteCount: size.partialValue)
    }

    private static func v2Descriptor(
        data: UnsafeRawBufferPointer,
        offset: Int,
        limit: Int
    ) throws -> BlockDescriptor {
        let decoded = Int(try readLittleEndianUInt32(data, at: offset + 4, limit: limit))
        let packed0 = try readLittleEndianUInt64(data, at: offset + 8, limit: limit)
        let packed1 = try readLittleEndianUInt64(data, at: offset + 16, limit: limit)
        let packed2 = try readLittleEndianUInt64(data, at: offset + 24, limit: limit)
        let header = Int(UInt32(truncatingIfNeeded: packed2))
        let payload = Int((packed0 >> 20) & 0x000f_ffff).addingReportingOverflow(
            Int((packed1 >> 40) & 0x000f_ffff)
        )
        guard decoded > 0,
            header >= lzfseV2FixedHeaderByteCount,
            header <= lzfseV2MaximumHeaderByteCount,
            !payload.overflow
        else { throw DerivedRasterContainerError.compressionFailed }
        let size = header.addingReportingOverflow(payload.partialValue)
        guard !size.overflow else { throw DerivedRasterContainerError.compressionFailed }
        return BlockDescriptor(decodedByteCount: decoded, encodedByteCount: size.partialValue)
    }

    private static func addingDecodedBytes(
        _ count: Int,
        to current: Int,
        maximum: Int
    ) throws -> Int {
        let next = current.addingReportingOverflow(count)
        guard !next.overflow, next.partialValue <= maximum else {
            throw DerivedRasterContainerError.compressionFailed
        }
        return next.partialValue
    }

    private static func addingEncodedBytes(_ count: Int, to offset: Int, limit: Int) throws -> Int {
        let next = offset.addingReportingOverflow(count)
        guard !next.overflow, next.partialValue <= limit else {
            throw DerivedRasterContainerError.compressionFailed
        }
        return next.partialValue
    }

    static func outerDigestVerified(
        _ container: Data,
        expectedDigestHex: String?,
        contentDigestAlreadyVerified: Bool
    ) throws -> Bool {
        guard let expectedDigestHex else { return false }
        guard expectedDigestHex.utf8.count == 64,
            expectedDigestHex.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            })
        else { throw DerivedRasterContainerError.integrityMismatch }
        if !contentDigestAlreadyVerified {
            guard container.sha256Hex == expectedDigestHex else {
                throw DerivedRasterContainerError.integrityMismatch
            }
        }
        return true
    }
    static func validateEncodedRegionDigest(
        _ container: Data,
        expectedDigest: Data,
        outerContentDigestVerified: Bool,
        headerByteCount: Int
    ) throws {
        guard !outerContentDigestVerified else { return }
        let encodedRegion = container[headerByteCount..<container.count]
        guard Data(SHA256.hash(data: encodedRegion)) == expectedDigest else {
            throw DerivedRasterContainerError.integrityMismatch
        }
    }
    static func readChunkRanges(
        _ cursor: inout DerivedRasterByteCursor,
        chunkCount: Int,
        payloadByteCount: Int,
        tableByteCount: Int,
        containerByteCount: Int,
        headerByteCount: Int
    ) throws -> [Range<Int>] {
        var byteCounts: [Int] = []
        byteCounts.reserveCapacity(chunkCount)
        var accumulated = 0
        for _ in 0..<chunkCount {
            let count = try cursor.readBoundedInt32()
            guard count >= 4 else { throw DerivedRasterContainerError.compressionFailed }
            let next = accumulated.addingReportingOverflow(count)
            guard !next.overflow, next.partialValue <= payloadByteCount else {
                throw DerivedRasterContainerError.integrityMismatch
            }
            accumulated = next.partialValue
            byteCounts.append(count)
        }
        guard cursor.offset == headerByteCount + tableByteCount,
            accumulated == payloadByteCount
        else { throw DerivedRasterContainerError.integrityMismatch }
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(chunkCount)
        for count in byteCounts { ranges.append(try cursor.readRange(count: count)) }
        guard cursor.offset == containerByteCount else {
            throw DerivedRasterContainerError.integrityMismatch
        }
        return ranges
    }
    static func validateChunkFrames(
        _ container: Data,
        ranges: [Range<Int>],
        decodedByteCount: Int,
        decodedChunkByteCount: Int
    ) throws {
        try container.withUnsafeBytes { bytes in
            for (chunkIndex, range) in ranges.enumerated() {
                let decodedStart = chunkIndex.multipliedReportingOverflow(by: decodedChunkByteCount)
                guard !decodedStart.overflow, decodedStart.partialValue < decodedByteCount else {
                    throw DerivedRasterContainerError.integrityMismatch
                }
                try validateLZFSEFrame(
                    in: bytes,
                    range: range,
                    expectedDecodedByteCount: min(
                        decodedChunkByteCount,
                        decodedByteCount - decodedStart.partialValue
                    )
                )
            }
        }
    }
    static func validatedGeometry(
        width: Int,
        height: Int,
        decodedByteCount: Int,
        bytesPerPixel: Int,
        limits: DerivedRasterContainerLimits
    ) throws -> (rowByteCount: Int, pixelCount: Int) {
        guard width > 0, height > 0, bytesPerPixel > 0,
            width <= limits.maximumDimension,
            height <= limits.maximumDimension,
            decodedByteCount > 0,
            decodedByteCount <= limits.maximumDecodedBytes
        else { throw DerivedRasterContainerError.limitExceeded }

        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow, pixels.partialValue <= limits.maximumPixelCount else {
            throw DerivedRasterContainerError.limitExceeded
        }
        let rowBytes = width.multipliedReportingOverflow(by: bytesPerPixel)
        guard !rowBytes.overflow else { throw DerivedRasterContainerError.limitExceeded }
        let expectedBytes = rowBytes.partialValue.multipliedReportingOverflow(by: height)
        guard !expectedBytes.overflow,
            expectedBytes.partialValue == decodedByteCount
        else { throw DerivedRasterContainerError.invalidInput }
        return (rowBytes.partialValue, pixels.partialValue)
    }
    static func decodeChunk(
        _ surface: DerivedRasterCompressedSurface,
        chunkIndex: Int,
        into destination: UnsafeMutableRawBufferPointer
    ) throws {
        guard let decodedRange = surface.decodedRange(forChunkAt: chunkIndex),
            chunkIndex >= 0,
            chunkIndex < surface.compressedChunkRanges.count,
            destination.count == decodedRange.count,
            destination.count > 0,
            let output = destination.bindMemory(to: UInt8.self).baseAddress
        else { throw DerivedRasterContainerError.invalidInput }
        let compressedRange = surface.compressedChunkRanges[chunkIndex]
        guard !compressedRange.isEmpty else {
            throw DerivedRasterContainerError.compressionFailed
        }

        let written = surface.container.withUnsafeBytes { inputRaw -> Int in
            guard let inputBase = inputRaw.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            let input = inputBase.advanced(by: compressedRange.lowerBound)
            return compression_decode_buffer(
                output,
                destination.count,
                input,
                compressedRange.count,
                nil,
                COMPRESSION_LZFSE
            )
        }
        guard written == destination.count else {
            throw DerivedRasterContainerError.compressionFailed
        }
    }

    private static func readLittleEndianUInt32(
        _ data: UnsafeRawBufferPointer,
        at offset: Int,
        limit: Int
    ) throws -> UInt32 {
        guard offset >= 0, limit <= data.count, offset <= limit, limit - offset >= 4 else {
            throw DerivedRasterContainerError.compressionFailed
        }
        let value = data.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        return UInt32(littleEndian: value)
    }
    private static func readLittleEndianUInt64(
        _ data: UnsafeRawBufferPointer,
        at offset: Int,
        limit: Int
    ) throws -> UInt64 {
        guard offset >= 0, limit <= data.count, offset <= limit, limit - offset >= 8 else {
            throw DerivedRasterContainerError.compressionFailed
        }
        let value = data.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        return UInt64(littleEndian: value)
    }
    static func compress(
        _ source: Data,
        maximumOutputBytes: Int
    ) throws -> Data {
        guard !source.isEmpty, maximumOutputBytes > 0 else {
            throw DerivedRasterContainerError.limitExceeded
        }
        let initialGrowth = max(4_096, source.count / 8)
        let initial = source.count.addingReportingOverflow(initialGrowth)
        guard !initial.overflow else { throw DerivedRasterContainerError.limitExceeded }
        var capacity = min(maximumOutputBytes, max(256, initial.partialValue))

        while capacity > 0, capacity <= maximumOutputBytes {
            var destination = Data(count: capacity)
            let written = destination.withUnsafeMutableBytes { outputRaw in
                source.withUnsafeBytes { inputRaw in
                    guard let output = outputRaw.bindMemory(to: UInt8.self).baseAddress,
                        let input = inputRaw.bindMemory(to: UInt8.self).baseAddress
                    else { return 0 }
                    return compression_encode_buffer(
                        output,
                        capacity,
                        input,
                        source.count,
                        nil,
                        COMPRESSION_LZFSE
                    )
                }
            }
            if written > 0 {
                destination.removeSubrange(written..<destination.count)
                return destination
            }
            guard capacity < maximumOutputBytes else { break }
            let doubled = capacity.multipliedReportingOverflow(by: 2)
            capacity =
                doubled.overflow
                ? maximumOutputBytes
                : min(maximumOutputBytes, max(capacity + 1, doubled.partialValue))
        }
        throw DerivedRasterContainerError.compressionFailed
    }
}

struct DerivedRasterByteCursor {
    let data: Data
    private(set) var offset = 0

    mutating func readRange(count: Int) throws -> Range<Int> {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw DerivedRasterContainerError.integrityMismatch
        }
        let range = offset..<(offset + count)
        offset += count
        return range
    }

    mutating func readData(count: Int) throws -> Data {
        data[try readRange(count: count)]
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readData(count: 2)
        return bytes.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(count: 8)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readBoundedInt32() throws -> Int {
        Int(try readUInt32())
    }

    mutating func readBoundedInt64() throws -> Int {
        let value = try readUInt64()
        guard value <= UInt64(Int.max) else { throw DerivedRasterContainerError.limitExceeded }
        return Int(value)
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            append(UInt8((value >> UInt32(shift)) & 0xff))
        }
    }

    mutating func appendBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }
}
