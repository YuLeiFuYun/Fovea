import Compression
import CoreGraphics
import CryptoKit
import Foundation
import FoveaCore
import ImageCraftCore
import ImageIO
import UniformTypeIdentifiers

/// 仅 lab 使用的 control：把当前 RGB24 storage 展开为 opaque premultiplied RGBA，使 RGB24 成为现行实现后仍可比较 CoreGraphics layout conversion 机制。
func opaquePremultipliedImage(from surface: DerivedRasterSurface) throws -> CGImage {
    guard surface.width > 0, surface.height > 0,
        surface.pixelLayout == .rgb24,
        surface.pixelData.count == surface.width * surface.height * 3,
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    else { throw LabError.pixelConversionFailed }
    var rgba = Data(count: surface.width * surface.height * 4)
    rgba.withUnsafeMutableBytes { outputRaw in
        surface.pixelData.withUnsafeBytes { inputRaw in
            guard let output = outputRaw.bindMemory(to: UInt8.self).baseAddress,
                let input = inputRaw.bindMemory(to: UInt8.self).baseAddress
            else { return }
            for pixel in 0..<(surface.width * surface.height) {
                let source = pixel * 3
                let destination = pixel * 4
                output[destination] = input[source]
                output[destination + 1] = input[source + 1]
                output[destination + 2] = input[source + 2]
                output[destination + 3] = 0xff
            }
        }
    }
    guard let provider = CGDataProvider(data: rgba as CFData),
        let image = CGImage(
            width: surface.width,
            height: surface.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: surface.width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    else { throw LabError.pixelConversionFailed }
    return image
}

func packedRGB24Data(from surface: DerivedRasterSurface) throws -> Data {
    guard surface.width > 0, surface.height > 0,
        surface.pixelLayout == .rgb24,
        surface.pixelData.count == surface.width * surface.height * 3
    else { throw LabError.pixelConversionFailed }
    return surface.pixelData
}

/// raw packed-RGB control 保持 `alphaInfo == .none`，因此与 premultiplied-RGBA probe 不同，仍维持 public `DecodedImage.alphaMode` 契约。
/// 调用方传入预打包字节，使每次 timed iteration 都能创建新的 provider/CGImage，而不重复 repack。
func packedRGB24Image(
    pixelData: Data,
    width: Int,
    height: Int
) throws -> CGImage {
    guard width > 0, height > 0 else { throw LabError.pixelConversionFailed }
    let pixelCount = width.multipliedReportingOverflow(by: height)
    guard !pixelCount.overflow else { throw LabError.pixelConversionFailed }
    let expectedBytes = pixelCount.partialValue.multipliedReportingOverflow(by: 3)
    guard !expectedBytes.overflow, pixelData.count == expectedBytes.partialValue,
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let provider = CGDataProvider(data: pixelData as CFData),
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: width * 3,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ),
        image.alphaInfo == .none
    else { throw LabError.pixelConversionFailed }
    return image
}

let packedRGB24DecodedChunkByteCount = 1_024 * 1_024

struct PackedRGB24CompressedSurface {
    let width: Int
    let height: Int
    let decodedByteCount: Int
    let decodedChunkByteCount: Int
    let compressedChunks: [Data]

    func decodedRange(forChunkAt index: Int) -> Range<Int>? {
        guard index >= 0, index < compressedChunks.count else { return nil }
        let start = index.multipliedReportingOverflow(by: decodedChunkByteCount)
        guard !start.overflow, start.partialValue < decodedByteCount else { return nil }
        let end = min(decodedByteCount, start.partialValue + decodedChunkByteCount)
        return start.partialValue..<end
    }
}

/// 仅机制比较的 schema6 候选：packed RGB24、相同 1 MiB decoded chunk、独立 LZFSE chunk，并使用与生产 RGBX provider 相同 one-chunk memo 形态的 direct random-access provider。
/// compression 在 measurement loop 外只做一次，因此每次 timed iteration 都能基于同一不可变 payload 创建新的 provider/CGImage。
func makePackedRGB24CompressedSurface(
    pixelData: Data,
    width: Int,
    height: Int
) throws -> PackedRGB24CompressedSurface {
    guard width > 0, height > 0 else { throw LabError.pixelConversionFailed }
    let pixelCount = width.multipliedReportingOverflow(by: height)
    guard !pixelCount.overflow else { throw LabError.pixelConversionFailed }
    let expectedBytes = pixelCount.partialValue.multipliedReportingOverflow(by: 3)
    guard !expectedBytes.overflow, pixelData.count == expectedBytes.partialValue else {
        throw LabError.pixelConversionFailed
    }

    var compressedChunks: [Data] = []
    compressedChunks.reserveCapacity(
        (pixelData.count + packedRGB24DecodedChunkByteCount - 1)
            / packedRGB24DecodedChunkByteCount
    )
    try pixelData.withUnsafeBytes { inputRaw in
        guard let inputBase = inputRaw.bindMemory(to: UInt8.self).baseAddress else {
            throw LabError.pixelConversionFailed
        }
        var offset = 0
        while offset < pixelData.count {
            let end = min(pixelData.count, offset + packedRGB24DecodedChunkByteCount)
            let sourceCount = end - offset
            let capacity = max(256, sourceCount * 2)
            var encoded = Data(count: capacity)
            let written = encoded.withUnsafeMutableBytes { outputRaw -> Int in
                guard let output = outputRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    output,
                    capacity,
                    inputBase.advanced(by: offset),
                    sourceCount,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
            guard written > 0 else { throw LabError.pixelConversionFailed }
            encoded.removeSubrange(written..<encoded.count)
            compressedChunks.append(encoded)
            offset = end
        }
    }
    guard !compressedChunks.isEmpty else { throw LabError.pixelConversionFailed }
    return PackedRGB24CompressedSurface(
        width: width,
        height: height,
        decodedByteCount: pixelData.count,
        decodedChunkByteCount: packedRGB24DecodedChunkByteCount,
        compressedChunks: compressedChunks
    )
}

func packedRGB24CompressedImage(
    from surface: PackedRGB24CompressedSurface
) throws -> CGImage {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw LabError.pixelConversionFailed
    }
    let source = PackedRGB24DirectChunkSource(surface: surface)
    let retained = Unmanaged.passRetained(source)
    var callbacks = CGDataProviderDirectCallbacks(
        version: 0,
        getBytePointer: nil,
        releaseBytePointer: nil,
        getBytesAtPosition: packedRGB24ProviderGetBytesAtPosition,
        releaseInfo: packedRGB24ProviderReleaseInfo
    )
    guard
        let provider = CGDataProvider(
            directInfo: retained.toOpaque(),
            size: off_t(surface.decodedByteCount),
            callbacks: &callbacks
        )
    else {
        retained.release()
        throw LabError.pixelConversionFailed
    }
    guard
        let image = CGImage(
            width: surface.width,
            height: surface.height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: surface.width * 3,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ), image.alphaInfo == .none
    else { throw LabError.pixelConversionFailed }
    return image
}

final class PackedRGB24DirectChunkSource: @unchecked Sendable {
    final class DecodedChunk {
        let pointer: UnsafeMutableRawPointer
        let count: Int

        init(count: Int) {
            self.count = count
            pointer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        }

        deinit { pointer.deallocate() }
    }

    let surface: PackedRGB24CompressedSurface
    let lock = NSLock()
    var cachedChunkIndex: Int?
    var cachedChunk: DecodedChunk?

    init(surface: PackedRGB24CompressedSurface) {
        self.surface = surface
    }

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
                guard let decodedRange = surface.decodedRange(forChunkAt: chunkIndex) else {
                    throw LabError.pixelConversionFailed
                }
                let overlap =
                    max(
                        decodedOffset, decodedRange.lowerBound)..<min(
                        end,
                        decodedRange.upperBound
                    )
                guard !overlap.isEmpty else { throw LabError.pixelConversionFailed }
                let chunk = try decodedChunk(at: chunkIndex, decodedRange: decodedRange)
                let offsetInChunk = overlap.lowerBound - decodedRange.lowerBound
                buffer.advanced(by: destinationOffset).copyMemory(
                    from: chunk.pointer.advanced(by: offsetInChunk),
                    byteCount: overlap.count
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

    func decodedChunk(
        at index: Int,
        decodedRange: Range<Int>
    ) throws -> DecodedChunk {
        if let cached = cachedChunkIfPresent(at: index, decodedRange: decodedRange) {
            return cached
        }
        guard index >= 0, index < surface.compressedChunks.count else {
            throw LabError.pixelConversionFailed
        }
        let next = DecodedChunk(count: decodedRange.count)
        let compressed = surface.compressedChunks[index]
        let written = compressed.withUnsafeBytes { inputRaw -> Int in
            guard let input = inputRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(
                next.pointer.assumingMemoryBound(to: UInt8.self),
                decodedRange.count,
                input,
                compressed.count,
                nil,
                COMPRESSION_LZFSE
            )
        }
        guard written == decodedRange.count else { throw LabError.pixelConversionFailed }

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

    func cachedChunkIfPresent(
        at index: Int,
        decodedRange: Range<Int>
    ) -> DecodedChunk? {
        lock.lock()
        defer { lock.unlock() }
        guard cachedChunkIndex == index,
            let cachedChunk,
            cachedChunk.count == decodedRange.count
        else { return nil }
        return cachedChunk
    }

    func clearCachedChunk() {
        lock.lock()
        cachedChunkIndex = nil
        cachedChunk = nil
        lock.unlock()
    }
}

func packedRGB24ProviderGetBytesAtPosition(
    info: UnsafeMutableRawPointer?,
    buffer: UnsafeMutableRawPointer,
    position: off_t,
    count: Int
) -> Int {
    guard let info else { return 0 }
    return Unmanaged<PackedRGB24DirectChunkSource>.fromOpaque(info)
        .takeUnretainedValue()
        .getBytes(buffer, position: position, count: count)
}

func packedRGB24ProviderReleaseInfo(_ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<PackedRGB24DirectChunkSource>.fromOpaque(info).release()
}

/// 与 ComparativeLab W2 的 materialization boundary 对齐：同尺寸 sRGB draw 到 premultiplied-last 32-bit buffer，然后只触碰输出首尾字节。
func w2MaterializePixels(_ image: CGImage) throws -> UInt8 {
    guard image.width > 0, image.height > 0,
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    else { throw LabError.pixelConversionFailed }
    let bytesPerRow = image.width * 4
    var pixels = Data(count: bytesPerRow * image.height)
    let drew = pixels.withUnsafeMutableBytes { storage -> Bool in
        guard let baseAddress = storage.baseAddress,
            let context = CGContext(
                data: baseAddress,
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
    guard drew else { throw LabError.pixelConversionFailed }
    return pixels.withUnsafeBytes { storage in
        guard let first = storage.first, let last = storage.last else { return 0 }
        return first &+ last
    }
}

func measure(_ operation: () throws -> Void) rethrows -> UInt64 {
    let started = DispatchTime.now().uptimeNanoseconds
    try autoreleasepool(invoking: operation)
    return DispatchTime.now().uptimeNanoseconds &- started
}

func summary(_ samples: [UInt64]) -> DurationSummary {
    precondition(!samples.isEmpty)
    let sorted = samples.sorted()
    let middle = sorted.count / 2
    let median: UInt64
    if sorted.count.isMultiple(of: 2) {
        median =
            sorted[middle - 1] / 2 + sorted[middle] / 2
            + (sorted[middle - 1] % 2 + sorted[middle] % 2) / 2
    } else {
        median = sorted[middle]
    }
    let p95Index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1))
    return DurationSummary(
        medianNanoseconds: median,
        p95Nanoseconds: sorted[p95Index],
        samplesNanoseconds: samples
    )
}

func rgbData(from image: CGImage) throws -> Data {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw LabError.pixelConversionFailed
    }
    let bytesPerRow = image.width * 4
    var rgba = Data(count: bytesPerRow * image.height)
    let created = rgba.withUnsafeMutableBytes { bytes -> Bool in
        guard let baseAddress = bytes.baseAddress,
            let context = CGContext(
                data: baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            )
        else { return false }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard created else { throw LabError.pixelConversionFailed }
    var rgb = Data(capacity: image.width * image.height * 3)
    for offset in stride(from: 0, to: rgba.count, by: 4) {
        rgb.append(rgba[offset])
        rgb.append(rgba[offset + 1])
        rgb.append(rgba[offset + 2])
    }
    return rgb
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func pngData(from image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else { throw LabError.pixelConversionFailed }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw LabError.pixelConversionFailed
    }
    return data as Data
}

func image(fromPNGData data: Data) throws -> CGImage {
    guard
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        CGImageSourceGetCount(source) == 1,
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw LabError.pixelConversionFailed }
    return image
}

func runtimeFingerprint() -> RuntimeFingerprint {
    #if arch(arm64)
        let architecture = "arm64"
    #elseif arch(x86_64)
        let architecture = "x86_64"
    #else
        let architecture = "other"
    #endif
    let info = ProcessInfo.processInfo
    let imageIOVersion =
        Bundle(identifier: "com.apple.ImageIO")?
        .object(forInfoDictionaryKey: "CFBundleVersion") as? String
    return RuntimeFingerprint(
        operatingSystemVersion: info.operatingSystemVersionString,
        processArchitecture: architecture,
        processorCount: info.processorCount,
        activeProcessorCount: info.activeProcessorCount,
        physicalMemoryBytes: info.physicalMemory,
        imageIOBundleVersion: imageIOVersion
    )
}
