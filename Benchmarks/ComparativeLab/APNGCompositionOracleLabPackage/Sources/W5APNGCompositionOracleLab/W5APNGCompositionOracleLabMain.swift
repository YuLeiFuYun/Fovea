import APNGKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageCraftCore
import ImageCraftImageIO
import ImageIO

private enum OracleError: Error, CustomStringConvertible {
    case invalidArguments
    case frameUnavailable(String, Int)
    case invalidTiming
    case pixelMaterializationFailed
    case reportEncodingFailed

    var description: String {
        switch self {
        case .invalidArguments: "invalid arguments"
        case .frameUnavailable(let comparator, let index):
            "frame unavailable: comparator=\(comparator) index=\(index)"
        case .invalidTiming: "invalid frame timing"
        case .pixelMaterializationFailed: "pixel materialization failed"
        case .reportEncodingFailed: "report encoding failed"
        }
    }
}

private struct Arguments {
    let fixtureID: String
    let input: URL
    let output: URL
    let sourceIdentity: URL

    init(_ values: [String]) throws {
        func value(_ option: String) -> String? {
            guard let index = values.firstIndex(of: option), index + 1 < values.count else {
                return nil
            }
            return values[index + 1]
        }
        guard let fixtureID = value("--fixture-id"),
            !fixtureID.isEmpty,
            let input = value("--input"),
            let output = value("--output"),
            let sourceIdentity = value("--source-identity")
        else { throw OracleError.invalidArguments }
        self.fixtureID = fixtureID
        self.input = URL(fileURLWithPath: input)
        self.output = URL(fileURLWithPath: output)
        self.sourceIdentity = URL(fileURLWithPath: sourceIdentity)
    }
}

private struct FrameDifferenceReport: Codable {
    let sameLength: Bool
    let differentPixelCount: Int?
    let differentPixelFraction: Double?
    let maximumChannelDifference: Int?
    let meanAbsoluteChannelDifference: Double?
}

private struct FrameRectReport: Codable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

private struct FrameReport: Codable {
    let index: Int
    let imageCraftDescriptorRect: FrameRectReport
    let imageCraftDisposal: String
    let imageCraftBlend: String
    let imageCraftSubrectRGBAByteCount: Int
    let imageCraftDecodedRGBAByteCount: Int
    let imageCraftDecodedIsFullCanvas: Bool
    let imageCraftWidth: Int
    let imageCraftHeight: Int
    let apngKitWidth: Int
    let apngKitHeight: Int
    let appleImageIOWidth: Int
    let appleImageIOHeight: Int
    let imageCraftPixelSHA256: String
    let apngKitPixelSHA256: String
    let appleImageIOPixelSHA256: String
    let imageCraftRGBAPath: String
    let apngKitRGBAPath: String
    let appleImageIORGBAPath: String
    let imageCraftVersusAPNGKit: FrameDifferenceReport
    let imageCraftVersusAppleImageIO: FrameDifferenceReport
    let apngKitVersusAppleImageIO: FrameDifferenceReport
}

private struct ComparatorTimelineReport: Codable {
    let frameCount: Int
    let normalizedAdditionalRepeatCount: UInt64?
    let frameDurationsNanoseconds: [UInt64]
    let decodePolicy: String
}

private struct ComparatorFrameReport: Codable {
    let frameCount: Int
    let decodePolicy: String
}

private struct OracleReport: Codable {
    let schemaVersion: Int
    let fixtureID: String
    let inputPath: String
    let inputByteCount: Int
    let inputSHA256: String
    let sourceIdentityPath: String
    let sourceIdentityByteCount: Int
    let sourceIdentitySHA256: String
    let imageCraft: ComparatorTimelineReport
    let apngKit: ComparatorTimelineReport
    let appleImageIO: ComparatorFrameReport
    let timelineToleranceNanoseconds: UInt64
    let timelineEligible: Bool
    let imageCraftAPNGKitAllFramesExact: Bool
    let imageCraftAppleImageIOAllFramesExact: Bool
    let apngKitAppleImageIOAllFramesExact: Bool
    let frames: [FrameReport]
    let claimBoundary: [String]
}

private struct ImageCraftPrepared {
    let canvasWidth: Int
    let canvasHeight: Int
    let frameCount: Int
    let normalizedAdditionalRepeatCount: UInt64?
    let frameDurationsNanoseconds: [UInt64]
    let descriptors: [ImageAnimationFrameDescriptor]
    let frames: [CGImage]
}

private struct APNGKitPrepared {
    let frameCount: Int
    let normalizedAdditionalRepeatCount: UInt64?
    let frameDurationsNanoseconds: [UInt64]
    let frames: [CGImage]
}

private struct AppleImageIOPrepared {
    let frameCount: Int
    let frames: [CGImage]
}

@main
private struct W5APNGCompositionOracleLabMain {
    @MainActor
    static func main() async {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            let data = try Data(contentsOf: arguments.input)
            let identityData = try Data(contentsOf: arguments.sourceIdentity)
            let imageCraft = try await prepareImageCraft(data)
            let apngKit = try prepareAPNGKit(data)
            let appleImageIO = try prepareAppleImageIO(data)
            guard imageCraft.frameCount == imageCraft.frames.count,
                apngKit.frameCount == apngKit.frames.count,
                appleImageIO.frameCount == appleImageIO.frames.count
            else { throw OracleError.frameUnavailable("frame-count", -1) }

            let outputDirectory = arguments.output.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            let frameCount = max(
                imageCraft.frameCount,
                apngKit.frameCount,
                appleImageIO.frameCount
            )
            let sharedFrameCount = min(
                imageCraft.frameCount,
                apngKit.frameCount,
                appleImageIO.frameCount
            )
            var frames: [FrameReport] = []
            frames.reserveCapacity(sharedFrameCount)
            for index in 0..<sharedFrameCount {
                let imageCraftFrame = imageCraft.frames[index]
                let imageCraftDescriptor = imageCraft.descriptors[index]
                let apngKitFrame = apngKit.frames[index]
                let appleImageIOFrame = appleImageIO.frames[index]
                let imageCraftRGBA = try normalizedRGBA(imageCraftFrame)
                let apngKitRGBA = try normalizedRGBA(apngKitFrame)
                let appleImageIORGBA = try normalizedRGBA(appleImageIOFrame)
                let imageCraftPath = outputDirectory.appendingPathComponent(
                    "\(arguments.fixtureID)-frame-\(String(format: "%02d", index))-ImageCraft.rgba"
                )
                let apngKitPath = outputDirectory.appendingPathComponent(
                    "\(arguments.fixtureID)-frame-\(String(format: "%02d", index))-APNGKit.rgba"
                )
                let appleImageIOPath = outputDirectory.appendingPathComponent(
                    "\(arguments.fixtureID)-frame-\(String(format: "%02d", index))-AppleImageIO.rgba"
                )
                try imageCraftRGBA.write(to: imageCraftPath, options: .atomic)
                try apngKitRGBA.write(to: apngKitPath, options: .atomic)
                try appleImageIORGBA.write(to: appleImageIOPath, options: .atomic)
                frames.append(
                    FrameReport(
                        index: index,
                        imageCraftDescriptorRect: FrameRectReport(
                            x: imageCraftDescriptor.rect.x,
                            y: imageCraftDescriptor.rect.y,
                            width: imageCraftDescriptor.rect.width,
                            height: imageCraftDescriptor.rect.height
                        ),
                        imageCraftDisposal: imageCraftDescriptor.disposal.rawValue,
                        imageCraftBlend: imageCraftDescriptor.blend.rawValue,
                        imageCraftSubrectRGBAByteCount: imageCraftDescriptor.rect.width
                            * imageCraftDescriptor.rect.height * 4,
                        imageCraftDecodedRGBAByteCount: imageCraftRGBA.count,
                        imageCraftDecodedIsFullCanvas: imageCraftFrame.width
                            == imageCraft.canvasWidth
                            && imageCraftFrame.height == imageCraft.canvasHeight,
                        imageCraftWidth: imageCraftFrame.width,
                        imageCraftHeight: imageCraftFrame.height,
                        apngKitWidth: apngKitFrame.width,
                        apngKitHeight: apngKitFrame.height,
                        appleImageIOWidth: appleImageIOFrame.width,
                        appleImageIOHeight: appleImageIOFrame.height,
                        imageCraftPixelSHA256: sha256(imageCraftRGBA),
                        apngKitPixelSHA256: sha256(apngKitRGBA),
                        appleImageIOPixelSHA256: sha256(appleImageIORGBA),
                        imageCraftRGBAPath: imageCraftPath.path,
                        apngKitRGBAPath: apngKitPath.path,
                        appleImageIORGBAPath: appleImageIOPath.path,
                        imageCraftVersusAPNGKit: difference(imageCraftRGBA, apngKitRGBA),
                        imageCraftVersusAppleImageIO: difference(
                            imageCraftRGBA, appleImageIORGBA
                        ),
                        apngKitVersusAppleImageIO: difference(apngKitRGBA, appleImageIORGBA)
                    )
                )
            }

            let tolerance: UInt64 = 1_000
            let timelineEligible =
                imageCraft.frameCount == apngKit.frameCount
                && imageCraft.frameDurationsNanoseconds.count
                    == apngKit.frameDurationsNanoseconds.count
                && zip(
                    imageCraft.frameDurationsNanoseconds,
                    apngKit.frameDurationsNanoseconds
                ).allSatisfy { absoluteDifference($0, $1) <= tolerance }
                && imageCraft.normalizedAdditionalRepeatCount
                    == apngKit.normalizedAdditionalRepeatCount
            let allFrameCountsEqual =
                imageCraft.frameCount == apngKit.frameCount
                && imageCraft.frameCount == appleImageIO.frameCount
                && frames.count == frameCount
            let imageCraftAPNGKitAllFramesExact =
                allFrameCountsEqual
                && frames.allSatisfy { $0.imageCraftPixelSHA256 == $0.apngKitPixelSHA256 }
            let imageCraftAppleImageIOAllFramesExact =
                allFrameCountsEqual
                && frames.allSatisfy {
                    $0.imageCraftPixelSHA256 == $0.appleImageIOPixelSHA256
                }
            let apngKitAppleImageIOAllFramesExact =
                allFrameCountsEqual
                && frames.allSatisfy { $0.apngKitPixelSHA256 == $0.appleImageIOPixelSHA256 }
            let report = OracleReport(
                schemaVersion: 3,
                fixtureID: arguments.fixtureID,
                inputPath: arguments.input.path,
                inputByteCount: data.count,
                inputSHA256: sha256(data),
                sourceIdentityPath: arguments.sourceIdentity.path,
                sourceIdentityByteCount: identityData.count,
                sourceIdentitySHA256: sha256(identityData),
                imageCraft: ComparatorTimelineReport(
                    frameCount: imageCraft.frameCount,
                    normalizedAdditionalRepeatCount: imageCraft.normalizedAdditionalRepeatCount,
                    frameDurationsNanoseconds: imageCraft.frameDurationsNanoseconds,
                    decodePolicy:
                        "ImageCraft requested full-canvas sRGB frames in one complete window"
                ),
                apngKit: ComparatorTimelineReport(
                    frameCount: apngKit.frameCount,
                    normalizedAdditionalRepeatCount: apngKit.normalizedAdditionalRepeatCount,
                    frameDurationsNanoseconds: apngKit.frameDurationsNanoseconds,
                    decodePolicy: "APNGKit preRenderAllFrames oracle with decoded-image cache"
                ),
                appleImageIO: ComparatorFrameReport(
                    frameCount: appleImageIO.frameCount,
                    decodePolicy: "CGImageSourceCreateImageAtIndex full-frame materialization"
                ),
                timelineToleranceNanoseconds: tolerance,
                timelineEligible: timelineEligible,
                imageCraftAPNGKitAllFramesExact: imageCraftAPNGKitAllFramesExact,
                imageCraftAppleImageIOAllFramesExact: imageCraftAppleImageIOAllFramesExact,
                apngKitAppleImageIOAllFramesExact: apngKitAppleImageIOAllFramesExact,
                frames: frames,
                claimBoundary: [
                    "correctness-only APNG disposal and blend adjudication",
                    "APNGKit preRenderAllFrames is not an equivalent performance or memory policy",
                    "Apple ImageIO is an additional system-framework comparator, not an authority by declaration",
                    "dirty unpublished ImageCraft candidate and local macOS execution",
                    "no player, energy, thermal, network or physical-device claim",
                ]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let reportData = try encoder.encode(report)
            guard !reportData.isEmpty else { throw OracleError.reportEncodingFailed }
            try reportData.write(to: arguments.output, options: .atomic)
            print(arguments.output.path)
        } catch {
            fputs("W5 APNG composition oracle failed: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func prepareImageCraft(_ data: Data) async throws -> ImageCraftPrepared {
        let asset = try await ImageIOAnimatedImageDecoder().prepareAnimation(source: .encoded(data))
        let request = ImageDecodeRequest(
            target: try TargetPixels(
                width: asset.metadata.canvasWidth,
                height: asset.metadata.canvasHeight
            ),
            colorPolicy: .convertToSRGB
        )
        let decoded = try await asset.frames(in: 0..<asset.metadata.frameCount, request: request)
        return ImageCraftPrepared(
            canvasWidth: asset.metadata.canvasWidth,
            canvasHeight: asset.metadata.canvasHeight,
            frameCount: asset.metadata.frameCount,
            normalizedAdditionalRepeatCount: asset.metadata.loopCount.additionalRepeatCount.map(
                UInt64.init
            ),
            frameDurationsNanoseconds: asset.metadata.frames.map(\.duration.roundedUpNanoseconds),
            descriptors: asset.metadata.frames,
            frames: decoded.map(\.image.cgImage)
        )
    }

    @MainActor
    private static func prepareAPNGKit(_ data: Data) throws -> APNGKitPrepared {
        let image = try APNGImage(data: data, decodingOptions: [.preRenderAllFrames])
        let view = APNGImageView(image: image, autoStartAnimating: false)
        defer { view.image = nil }
        let frames = try (0..<image.numberOfFrames).map { index -> CGImage in
            guard let frame = image.cachedFrameImage(at: index) else {
                throw OracleError.frameUnavailable("APNGKit", index)
            }
            return frame
        }
        let durations = try image.loadedFrames.map { frame in
            try secondsToNanoseconds(frame.frameControl.duration)
        }
        let additionalRepeats = image.numberOfPlays.map { plays -> UInt64 in
            plays <= 1 ? 0 : UInt64(plays - 1)
        }
        return APNGKitPrepared(
            frameCount: image.numberOfFrames,
            normalizedAdditionalRepeatCount: additionalRepeats,
            frameDurationsNanoseconds: durations,
            frames: frames
        )
    }

    private static func prepareAppleImageIO(_ data: Data) throws -> AppleImageIOPrepared {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw OracleError.frameUnavailable("AppleImageIO-source", -1)
        }
        let frameCount = CGImageSourceGetCount(source)
        let frames = try (0..<frameCount).map { index -> CGImage in
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw OracleError.frameUnavailable("AppleImageIO", index)
            }
            return frame
        }
        return AppleImageIOPrepared(frameCount: frameCount, frames: frames)
    }

    private static func secondsToNanoseconds(_ seconds: TimeInterval) throws -> UInt64 {
        guard seconds.isFinite,
            seconds >= 0,
            seconds <= Double(UInt64.max) / 1_000_000_000
        else { throw OracleError.invalidTiming }
        return UInt64((seconds * 1_000_000_000).rounded())
    }

    private static func absoluteDifference(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }

    private static func normalizedRGBA(_ image: CGImage) throws -> Data {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw OracleError.pixelMaterializationFailed
        }
        let rowBytes = image.width.multipliedReportingOverflow(by: 4)
        let total = rowBytes.partialValue.multipliedReportingOverflow(by: image.height)
        guard !rowBytes.overflow, !total.overflow else {
            throw OracleError.pixelMaterializationFailed
        }
        var pixels = Data(count: total.partialValue)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let address = raw.baseAddress,
                let context = CGContext(
                    data: address,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: rowBytes.partialValue,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                )
            else { return false }
            context.setBlendMode(.copy)
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        guard rendered else { throw OracleError.pixelMaterializationFailed }
        return pixels
    }

    private static func difference(_ lhs: Data, _ rhs: Data) -> FrameDifferenceReport {
        guard lhs.count == rhs.count else {
            return FrameDifferenceReport(
                sameLength: false,
                differentPixelCount: nil,
                differentPixelFraction: nil,
                maximumChannelDifference: nil,
                meanAbsoluteChannelDifference: nil
            )
        }
        var differentPixels = 0
        var maximumDifference = 0
        var totalDifference = 0
        for offset in stride(from: 0, to: lhs.count, by: 4) {
            var pixelDiffers = false
            for channel in 0..<4 {
                let difference = abs(Int(lhs[offset + channel]) - Int(rhs[offset + channel]))
                maximumDifference = max(maximumDifference, difference)
                totalDifference += difference
                pixelDiffers = pixelDiffers || difference != 0
            }
            differentPixels += pixelDiffers ? 1 : 0
        }
        let pixelCount = lhs.count / 4
        return FrameDifferenceReport(
            sameLength: true,
            differentPixelCount: differentPixels,
            differentPixelFraction: Double(differentPixels) / Double(pixelCount),
            maximumChannelDifference: maximumDifference,
            meanAbsoluteChannelDifference: Double(totalDifference) / Double(lhs.count)
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
