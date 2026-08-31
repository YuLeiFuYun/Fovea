import CoreGraphics
import Foundation
import ImageCraftCore
import ImageCraftImageIO
import PINRemoteImage
import SDWebImage

package protocol PreparedAnimatedCodec: Sendable {
    var frameCount: Int { get }
    var rawLoopCount: UInt64 { get }
    var normalizedAdditionalRepeatCount: UInt64? { get }
    var frameDurationsNanoseconds: [UInt64] { get }
    func frame(at index: Int) async throws -> CGImage
    func allFrames() async throws -> [CGImage]
}

package struct CodecFactory: Sendable {
    package let comparator: LabComparator
    package let format: LabFormat
    package let identity: ComparatorIdentityReport

    package init(
        comparator: LabComparator,
        format: LabFormat,
        identity: ComparatorIdentityReport
    ) throws {
        guard identity.name == comparator.rawValue else { throw LabError.invalidArguments }
        self.comparator = comparator
        self.format = format
        self.identity = identity
    }

    package func prepare(_ data: Data) async throws -> any PreparedAnimatedCodec {
        switch comparator {
        case .imageCraft:
            return try await ImageCraftPreparedCodec(data: data)
        case .sdWebImage:
            return try SDPreparedCodec(data: data)
        case .pinRemoteImage:
            return try PINPreparedCodec(data: data, format: format)
        }
    }
}

private final class ImageCraftPreparedCodec: PreparedAnimatedCodec, @unchecked Sendable {
    private let asset: AnimatedImageAsset
    let frameCount: Int
    let rawLoopCount: UInt64
    let normalizedAdditionalRepeatCount: UInt64?
    let frameDurationsNanoseconds: [UInt64]
    private let request: ImageDecodeRequest

    init(data: Data) async throws {
        asset = try await ImageIOAnimatedImageDecoder().prepareAnimation(source: .encoded(data))
        frameCount = asset.metadata.frameCount
        normalizedAdditionalRepeatCount = asset.metadata.loopCount.additionalRepeatCount.map(
            UInt64.init)
        rawLoopCount = normalizedAdditionalRepeatCount ?? 0
        frameDurationsNanoseconds = asset.metadata.frames.map(\.duration.roundedUpNanoseconds)
        request = ImageDecodeRequest(
            target: try TargetPixels(
                width: asset.metadata.canvasWidth,
                height: asset.metadata.canvasHeight
            ),
            colorPolicy: .convertToSRGB
        )
    }

    func frame(at index: Int) async throws -> CGImage {
        let frame = try await asset.frame(at: index, request: request)
        return frame.image.cgImage
    }

    func allFrames() async throws -> [CGImage] {
        var result: [CGImage] = []
        result.reserveCapacity(frameCount)
        var lower = 0
        while lower < frameCount {
            let upper = min(frameCount, lower + 8)
            let window = try await asset.frames(in: lower..<upper, request: request)
            result.append(contentsOf: window.map(\.image.cgImage))
            lower = upper
        }
        return result
    }
}

private final class SDPreparedCodec: PreparedAnimatedCodec, @unchecked Sendable {
    private let provider: SDAnimatedImage
    let frameCount: Int
    let rawLoopCount: UInt64
    let normalizedAdditionalRepeatCount: UInt64?
    let frameDurationsNanoseconds: [UInt64]

    init(data: Data) throws {
        guard let provider = SDAnimatedImage(data: data, scale: 1, options: nil) else {
            throw LabError.preparationFailed
        }
        self.provider = provider
        frameCount = Int(provider.animatedImageFrameCount)
        rawLoopCount = UInt64(provider.animatedImageLoopCount)
        normalizedAdditionalRepeatCount = rawLoopCount == 0 ? nil : rawLoopCount - 1
        frameDurationsNanoseconds = try (0..<frameCount).map {
            try secondsToNanoseconds(provider.animatedImageDuration(at: UInt($0)))
        }
    }

    func frame(at index: Int) async throws -> CGImage {
        guard let image = provider.animatedImageFrame(at: UInt(index)) else {
            throw LabError.frameUnavailable
        }
        return try platformCGImage(image)
    }

    func allFrames() async throws -> [CGImage] {
        var result: [CGImage] = []
        result.reserveCapacity(frameCount)
        for index in 0..<frameCount { result.append(try await frame(at: index)) }
        return result
    }
}

private final class PINPreparedCodec: PreparedAnimatedCodec, @unchecked Sendable {
    private let imageOperation: (UInt) -> CGImage?
    let frameCount: Int
    let rawLoopCount: UInt64
    let normalizedAdditionalRepeatCount: UInt64?
    let frameDurationsNanoseconds: [UInt64]

    init(data: Data, format: LabFormat) throws {
        let durationOperation: (UInt) -> TimeInterval
        let noCache: (any PINCachedAnimatedFrameProvider)? = nil
        switch format {
        case .gif:
            guard let provider = PINGIFAnimatedImage(animatedImageData: data) else {
                throw LabError.preparationFailed
            }
            frameCount = Int(provider.frameCount)
            rawLoopCount = UInt64(provider.loopCount)
            durationOperation = { index in provider.duration(at: index) }
            imageOperation = { index in
                provider.image(at: index, cacheProvider: noCache)?.takeUnretainedValue()
            }
        case .apng:
            guard let provider = PINAPNGAnimatedImage(animatedImageData: data) else {
                throw LabError.preparationFailed
            }
            frameCount = Int(provider.frameCount)
            rawLoopCount = UInt64(provider.loopCount)
            durationOperation = { index in provider.duration(at: index) }
            imageOperation = { index in
                provider.image(at: index, cacheProvider: noCache)?.takeUnretainedValue()
            }
        }
        normalizedAdditionalRepeatCount = rawLoopCount == 0 ? nil : rawLoopCount - 1
        frameDurationsNanoseconds = try (0..<frameCount).map {
            try secondsToNanoseconds(durationOperation(UInt($0)))
        }
    }

    func frame(at index: Int) async throws -> CGImage {
        guard index >= 0,
            index < frameCount,
            let image = imageOperation(UInt(index))
        else { throw LabError.frameUnavailable }
        return image
    }

    func allFrames() async throws -> [CGImage] {
        var result: [CGImage] = []
        result.reserveCapacity(frameCount)
        for index in 0..<frameCount { result.append(try await frame(at: index)) }
        return result
    }
}

private func secondsToNanoseconds(_ seconds: TimeInterval) throws -> UInt64 {
    guard seconds.isFinite,
        seconds >= 0,
        seconds <= Double(UInt64.max) / 1_000_000_000
    else { throw LabError.invalidTiming }
    return UInt64((seconds * 1_000_000_000).rounded())
}
