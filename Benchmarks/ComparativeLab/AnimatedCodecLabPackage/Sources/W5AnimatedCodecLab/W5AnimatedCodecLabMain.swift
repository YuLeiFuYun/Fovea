import Foundation

@main
private struct W5AnimatedCodecLab {
    static func main() async throws {
        let arguments = try Arguments(CommandLine.arguments)
        let data = try Data(contentsOf: arguments.input)
        let factory = try CodecFactory(
            comparator: arguments.comparator,
            format: arguments.format,
            identity: arguments.comparatorIdentity
        )
        let prepared = try await factory.prepare(data)
        guard prepared.frameCount > 1,
            prepared.frameCount == prepared.frameDurationsNanoseconds.count,
            prepared.frameCount > arguments.selectedFrameIndex
        else { throw LabError.preparationFailed }

        for _ in 0..<arguments.warmups {
            _ = try await factory.prepare(data)
            let frame = try await prepared.frame(at: arguments.selectedFrameIndex)
            _ = try normalizedRGBA(frame)
            let frames = try await prepared.allFrames()
            for image in frames { _ = try normalizedRGBA(image) }
        }

        let prepareSamples = try await measure(count: arguments.iterations) {
            _ = try await factory.prepare(data)
        }
        let selectedSamples = try await measure(count: arguments.iterations) {
            let frame = try await prepared.frame(at: arguments.selectedFrameIndex)
            _ = try normalizedRGBA(frame)
        }
        let sequentialSamples = try await measure(count: arguments.iterations) {
            let frames = try await prepared.allFrames()
            for image in frames { _ = try normalizedRGBA(image) }
        }
        let selectedFrame = try await prepared.frame(at: arguments.selectedFrameIndex)
        let selectedRGBA = try normalizedRGBA(selectedFrame)
        let rgbaURL = arguments.output
            .deletingPathExtension()
            .appendingPathExtension("rgba")
        try selectedRGBA.write(to: rgbaURL, options: .atomic)
        let report = AnimatedCodecReport(
            schemaVersion: 2,
            comparator: factory.identity,
            format: arguments.format,
            inputPath: arguments.input.path,
            inputByteCount: data.count,
            inputSHA256: sha256(data),
            frameCount: prepared.frameCount,
            rawLoopCount: prepared.rawLoopCount,
            normalizedAdditionalRepeatCount: prepared.normalizedAdditionalRepeatCount,
            frameDurationsNanoseconds: prepared.frameDurationsNanoseconds,
            selectedFrameIndex: arguments.selectedFrameIndex,
            selectedFrameWidth: selectedFrame.width,
            selectedFrameHeight: selectedFrame.height,
            selectedFramePixelSHA256: sha256(selectedRGBA),
            selectedFrameRGBAPath: rgbaURL.path,
            prepare: timing(prepareSamples),
            selectedFrame: timing(selectedSamples),
            sequentialAllFrames: timing(sequentialSamples),
            frameCachePolicy: "disabled-or-not-provided",
            sourceReusePolicy: "one-retained-provider-per-report"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: arguments.output, options: .atomic)
        print(arguments.output.path)
    }
}
