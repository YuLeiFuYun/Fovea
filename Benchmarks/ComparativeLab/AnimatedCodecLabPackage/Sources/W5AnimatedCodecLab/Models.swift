import Foundation

package enum LabComparator: String, Codable {
    case imageCraft = "ImageCraft"
    case sdWebImage = "SDWebImage"
    case pinRemoteImage = "PINRemoteImage"
}

package enum LabFormat: String, Codable {
    case gif
    case apng
}

package enum LabError: Error {
    case invalidArguments
    case preparationFailed
    case frameUnavailable
    case invalidTiming
    case pixelMaterializationFailed
}

package struct TimingReport: Codable {
    package let medianNanoseconds: UInt64
    package let p95Nanoseconds: UInt64
    package let samplesNanoseconds: [UInt64]
}

package struct ComparatorIdentityReport: Codable, Equatable {
    package let name: String
    package let version: String
    package let headCommit: String
    package let workingTree: String
    package let dirty: Bool
}

package struct AnimatedCodecReport: Codable {
    package let schemaVersion: Int
    package let comparator: ComparatorIdentityReport
    package let format: LabFormat
    package let inputPath: String
    package let inputByteCount: Int
    package let inputSHA256: String
    package let frameCount: Int
    package let rawLoopCount: UInt64
    package let normalizedAdditionalRepeatCount: UInt64?
    package let frameDurationsNanoseconds: [UInt64]
    package let selectedFrameIndex: Int
    package let selectedFrameWidth: Int
    package let selectedFrameHeight: Int
    package let selectedFramePixelSHA256: String
    package let selectedFrameRGBAPath: String
    package let prepare: TimingReport
    package let selectedFrame: TimingReport
    package let sequentialAllFrames: TimingReport
    package let frameCachePolicy: String
    package let sourceReusePolicy: String
}

package struct Arguments {
    package let comparator: LabComparator
    package let format: LabFormat
    package let input: URL
    package let output: URL
    package let selectedFrameIndex: Int
    package let iterations: Int
    package let warmups: Int
    package let comparatorIdentity: ComparatorIdentityReport

    package init(_ values: [String]) throws {
        func value(_ name: String) -> String? {
            guard let index = values.firstIndex(of: name), index + 1 < values.count else {
                return nil
            }
            return values[index + 1]
        }
        guard let comparator = value("--comparator").flatMap(LabComparator.init(rawValue:)),
            let format = value("--format").flatMap(LabFormat.init(rawValue:)),
            let input = value("--input"),
            let output = value("--output"),
            let selectedFrameIndex = value("--frame-index").flatMap(Int.init),
            let iterations = value("--iterations").flatMap(Int.init),
            let warmups = value("--warmups").flatMap(Int.init),
            let comparatorVersion = value("--comparator-version"),
            let sourceHead = value("--source-head"),
            let sourceTree = value("--source-tree"),
            let sourceDirty = value("--source-dirty").flatMap(Self.parseBoolean),
            selectedFrameIndex >= 0,
            iterations > 0,
            warmups >= 0,
            !comparatorVersion.isEmpty,
            Self.isGitObjectID(sourceHead),
            Self.isGitObjectID(sourceTree)
        else { throw LabError.invalidArguments }
        self.comparator = comparator
        self.format = format
        self.input = URL(fileURLWithPath: input)
        self.output = URL(fileURLWithPath: output)
        self.selectedFrameIndex = selectedFrameIndex
        self.iterations = iterations
        self.warmups = warmups
        comparatorIdentity = ComparatorIdentityReport(
            name: comparator.rawValue,
            version: comparatorVersion,
            headCommit: sourceHead,
            workingTree: sourceTree,
            dirty: sourceDirty
        )
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value {
        case "true": true
        case "false": false
        default: nil
        }
    }

    private static func isGitObjectID(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
