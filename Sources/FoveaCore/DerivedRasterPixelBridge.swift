import CoreGraphics
import CryptoKit
import Foundation
import ImageCraftCore

/// 在版本化派生光栅容器与 ImageCraft 最终图像之间执行确定性像素转换。
package enum DerivedRasterPixelBridge {
    package static func surface(
        from image: DecodedImage,
        format: DerivedRasterFormatIdentity
    ) throws -> DerivedRasterSurface {
        guard image.pixelWidth > 0, image.pixelHeight > 0,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            DerivedRasterContainer.pixelLayout(for: format) == .rgb24,
            image.alphaMode == .none
        else { throw DerivedRasterContainerError.invalidInput }

        let stagingRowBytes = image.pixelWidth.multipliedReportingOverflow(by: 4)
        let stagingByteCount = stagingRowBytes.partialValue.multipliedReportingOverflow(
            by: image.pixelHeight
        )
        guard !stagingRowBytes.overflow, !stagingByteCount.overflow else {
            throw DerivedRasterContainerError.limitExceeded
        }
        var rgbx = Data(count: stagingByteCount.partialValue)
        let rendered = rgbx.withUnsafeMutableBytes { storage -> Bool in
            guard let address = storage.baseAddress,
                let context = CGContext(
                    data: address,
                    width: image.pixelWidth,
                    height: image.pixelHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: stagingRowBytes.partialValue,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                )
            else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(
                image.cgImage,
                in: CGRect(x: 0, y: 0, width: image.pixelWidth, height: image.pixelHeight)
            )
            return true
        }
        guard rendered else { throw DerivedRasterContainerError.invalidInput }

        let pixelCount = image.pixelWidth.multipliedReportingOverflow(by: image.pixelHeight)
        guard !pixelCount.overflow else { throw DerivedRasterContainerError.limitExceeded }
        let packedByteCount = pixelCount.partialValue.multipliedReportingOverflow(by: 3)
        guard !packedByteCount.overflow else { throw DerivedRasterContainerError.limitExceeded }
        var rgb = Data(count: packedByteCount.partialValue)
        rgb.withUnsafeMutableBytes { outputRaw in
            rgbx.withUnsafeBytes { inputRaw in
                guard let output = outputRaw.bindMemory(to: UInt8.self).baseAddress,
                    let input = inputRaw.bindMemory(to: UInt8.self).baseAddress
                else { return }
                var pixel = 0
                while pixel < pixelCount.partialValue {
                    let source = pixel * 4
                    let destination = pixel * 3
                    output[destination] = input[source]
                    output[destination + 1] = input[source + 1]
                    output[destination + 2] = input[source + 2]
                    pixel += 1
                }
            }
        }
        return DerivedRasterSurface(
            width: image.pixelWidth,
            height: image.pixelHeight,
            pixelData: rgb,
            pixelLayout: .rgb24,
            pixelDigestHex: lowercaseHexString(SHA256.hash(data: rgb))
        )
    }

    package static func validatedRGB24Geometry(
        width: Int,
        height: Int
    ) throws -> (rowBytes: Int, decodedByteCount: Int) {
        guard width > 0, height > 0 else {
            throw DerivedRasterContainerError.invalidInput
        }
        let rowBytes = width.multipliedReportingOverflow(by: 3)
        guard !rowBytes.overflow else { throw DerivedRasterContainerError.limitExceeded }
        let decodedByteCount = rowBytes.partialValue.multipliedReportingOverflow(by: height)
        guard !decodedByteCount.overflow else {
            throw DerivedRasterContainerError.limitExceeded
        }
        return (rowBytes.partialValue, decodedByteCount.partialValue)
    }

    package static func image(
        from surface: DerivedRasterSurface,
        sourceColorProfile: SourceColorProfile = .standardSRGB
    ) throws -> DecodedImage {
        guard surface.pixelLayout == .rgb24 else {
            throw DerivedRasterContainerError.invalidInput
        }
        let geometry = try validatedRGB24Geometry(width: surface.width, height: surface.height)
        guard surface.pixelData.count == geometry.decodedByteCount,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: surface.pixelData as CFData)
        else {
            throw DerivedRasterContainerError.invalidInput
        }
        let image = CGImage(
            width: surface.width,
            height: surface.height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: geometry.rowBytes,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
        guard let image else { throw DerivedRasterContainerError.invalidInput }
        return DecodedImage(cgImage: image, sourceColorProfile: sourceColorProfile)
    }

    /// 返回只持有 chunked-compressed RGB24 payload 的 display-lazy CGImage。容器身份与
    /// header 必须已由 `DerivedRasterArtifactValidator` 验证；CoreGraphics 以 byte position
    /// 随机读取，覆盖完整 chunk 时直接解压到目标缓冲，不创建整图 raw backing。
    package static func lazyImage(
        from surface: DerivedRasterCompressedSurface,
        sourceColorProfile: SourceColorProfile = .standardSRGB
    ) throws -> DecodedImage {
        try makeLazyImage(from: surface, sourceColorProfile: sourceColorProfile)
    }

    private static func makeLazyImage(
        from surface: DerivedRasterCompressedSurface,
        sourceColorProfile: SourceColorProfile
    ) throws -> DecodedImage {
        guard surface.width > 0, surface.height > 0,
            surface.pixelLayout == .rgb24,
            surface.decodedChunkByteCount > 0,
            !surface.compressedChunkRanges.isEmpty,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw DerivedRasterContainerError.invalidInput }
        let rowBytes = surface.width.multipliedReportingOverflow(by: 3)
        guard !rowBytes.overflow else { throw DerivedRasterContainerError.limitExceeded }
        let decodedBytes = rowBytes.partialValue.multipliedReportingOverflow(by: surface.height)
        guard !decodedBytes.overflow,
            decodedBytes.partialValue == surface.decodedByteCount
        else { throw DerivedRasterContainerError.invalidInput }

        let source = DerivedRasterDirectChunkSource(surface: surface)
        let retained = Unmanaged.passRetained(source)
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0,
            getBytePointer: nil,
            releaseBytePointer: nil,
            getBytesAtPosition: derivedRasterProviderGetBytesAtPosition,
            releaseInfo: derivedRasterProviderReleaseInfo
        )
        guard
            let provider = CGDataProvider(
                directInfo: retained.toOpaque(),
                size: off_t(surface.decodedByteCount),
                callbacks: &callbacks
            )
        else {
            retained.release()
            throw DerivedRasterContainerError.invalidInput
        }
        guard
            let image = CGImage(
                width: surface.width,
                height: surface.height,
                bitsPerComponent: 8,
                bitsPerPixel: 24,
                bytesPerRow: rowBytes.partialValue,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else { throw DerivedRasterContainerError.invalidInput }
        return DecodedImage(cgImage: image, sourceColorProfile: sourceColorProfile)
    }
}

private final class DerivedRasterDirectChunkSource: @unchecked Sendable {
    private final class DecodedChunkScratch {
        let pointer: UnsafeMutableRawPointer
        let count: Int

        init(count: Int) {
            self.count = count
            pointer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        }

        deinit { pointer.deallocate() }
    }

    private let surface: DerivedRasterCompressedSurface
    private let lock = NSLock()
    private var cachedChunkIndex: Int?
    private var cachedChunk: DecodedChunkScratch?

    init(surface: DerivedRasterCompressedSurface) {
        self.surface = surface
    }

    /// 完全由显式 position 决定输出，不持有 decoder cursor。锁只保护一个有界的已解压
    /// chunk memo；它不参与定位语义。CoreGraphics 对同一 chunk 的连续小 range 请求因此只
    /// 解压一次，而并发调用仍由各自的 `(position, count)` 决定返回字节。
    func getBytes(
        _ buffer: UnsafeMutableRawPointer,
        position: off_t,
        count: Int
    ) -> Int {
        guard position >= 0, count > 0 else { return 0 }
        let start = Int(position)
        guard start >= 0, start < surface.decodedByteCount else { return 0 }
        let requestedEnd = start.addingReportingOverflow(count)
        guard !requestedEnd.overflow else { return 0 }
        let end = min(surface.decodedByteCount, requestedEnd.partialValue)
        var decodedOffset = start
        var destinationOffset = 0
        do {
            while decodedOffset < end {
                let chunkIndex = decodedOffset / surface.decodedChunkByteCount
                guard let chunkDecodedRange = surface.decodedRange(forChunkAt: chunkIndex) else {
                    throw DerivedRasterContainerError.compressionFailed
                }
                let overlap =
                    max(
                        decodedOffset, chunkDecodedRange.lowerBound)..<min(
                        end,
                        chunkDecodedRange.upperBound
                    )
                guard !overlap.isEmpty else {
                    throw DerivedRasterContainerError.compressionFailed
                }
                try copyDecodedRange(
                    overlap,
                    fullChunkRange: chunkDecodedRange,
                    chunkIndex: chunkIndex,
                    into: buffer.advanced(by: destinationOffset)
                )
                decodedOffset = overlap.upperBound
                destinationOffset += overlap.count
            }
            if end == surface.decodedByteCount {
                clearCachedChunk()
            }
            return destinationOffset
        } catch {
            clearCachedChunk()
            return 0
        }
    }

    private func copyDecodedRange(
        _ requestedRange: Range<Int>,
        fullChunkRange: Range<Int>,
        chunkIndex: Int,
        into destination: UnsafeMutableRawPointer
    ) throws {
        if requestedRange == fullChunkRange,
            let cached = cachedChunkIfPresent(at: chunkIndex, decodedRange: fullChunkRange)
        {
            destination.copyMemory(from: cached.pointer, byteCount: requestedRange.count)
            return
        }
        if requestedRange == fullChunkRange {
            try DerivedRasterContainer.decodeChunk(
                surface,
                chunkIndex: chunkIndex,
                into: UnsafeMutableRawBufferPointer(
                    start: destination,
                    count: fullChunkRange.count
                )
            )
            return
        }
        let scratch = try decodedChunk(at: chunkIndex, decodedRange: fullChunkRange)
        let offsetInChunk = requestedRange.lowerBound - fullChunkRange.lowerBound
        destination.copyMemory(
            from: scratch.pointer.advanced(by: offsetInChunk),
            byteCount: requestedRange.count
        )
    }

    /// cached chunk 发布后不可变，锁只保护引用；解压与字节复制有意在锁外执行，避免并发 draw 串行在 source-wide 临界区。
    private func decodedChunk(
        at index: Int,
        decodedRange: Range<Int>
    ) throws -> DecodedChunkScratch {
        if let cached = cachedChunkIfPresent(at: index, decodedRange: decodedRange) {
            return cached
        }

        let next = DecodedChunkScratch(count: decodedRange.count)
        try DerivedRasterContainer.decodeChunk(
            surface,
            chunkIndex: index,
            into: UnsafeMutableRawBufferPointer(
                start: next.pointer,
                count: decodedRange.count
            )
        )
        lock.lock()
        if cachedChunkIndex == index,
            let cachedChunk,
            cachedChunk.count == decodedRange.count
        {
            lock.unlock()
            return cachedChunk
        }
        cachedChunkIndex = index
        cachedChunk = next
        lock.unlock()
        return next
    }

    private func cachedChunkIfPresent(
        at index: Int,
        decodedRange: Range<Int>
    ) -> DecodedChunkScratch? {
        lock.lock()
        let result: DecodedChunkScratch?
        if cachedChunkIndex == index,
            let cachedChunk,
            cachedChunk.count == decodedRange.count
        {
            result = cachedChunk
        } else {
            result = nil
        }
        lock.unlock()
        return result
    }

    private func clearCachedChunk() {
        lock.lock()
        cachedChunkIndex = nil
        cachedChunk = nil
        lock.unlock()
    }

}

private func derivedRasterProviderGetBytesAtPosition(
    info: UnsafeMutableRawPointer?,
    buffer: UnsafeMutableRawPointer,
    position: off_t,
    count: Int
) -> Int {
    guard let info else { return 0 }
    return Unmanaged<DerivedRasterDirectChunkSource>.fromOpaque(info)
        .takeUnretainedValue()
        .getBytes(buffer, position: position, count: count)
}

private func derivedRasterProviderReleaseInfo(_ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<DerivedRasterDirectChunkSource>.fromOpaque(info).release()
}
