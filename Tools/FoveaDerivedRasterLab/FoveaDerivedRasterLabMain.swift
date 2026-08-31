import Dispatch
import Foundation
import FoveaCore
import FoveaPersistence
import FoveaStorage

enum LabError: Error, CustomStringConvertible {
    case invalidArguments
    case pixelConversionFailed
    case outputMismatch
    case storageMiss

    var description: String {
        switch self {
        case .invalidArguments: "invalid arguments"
        case .pixelConversionFailed: "pixel conversion failed"
        case .outputMismatch: "derived output differs from direct decode"
        case .storageMiss: "derived store returned a miss"
        }
    }
}

struct Options {
    let input: URL
    let output: URL
    let targetWidth: Int
    let targetHeight: Int
    let iterations: Int

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count, arguments[index].hasPrefix("--") else {
                throw LabError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let input = values["--input"],
            let output = values["--output"],
            let targetWidth = values["--target-width"].flatMap(Int.init),
            let targetHeight = values["--target-height"].flatMap(Int.init),
            let iterations = values["--iterations"].flatMap(Int.init),
            (1...16_384).contains(targetWidth),
            (1...16_384).contains(targetHeight),
            (1...100).contains(iterations)
        else { throw LabError.invalidArguments }
        self.input = URL(fileURLWithPath: input)
        self.output = URL(fileURLWithPath: output)
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.iterations = iterations
    }
}

struct DurationSummary: Codable {
    let medianNanoseconds: UInt64
    let p95Nanoseconds: UInt64
    let samplesNanoseconds: [UInt64]
}

struct RuntimeFingerprint: Codable {
    let operatingSystemVersion: String
    let processArchitecture: String
    let processorCount: Int
    let activeProcessorCount: Int
    let physicalMemoryBytes: UInt64
    let imageIOBundleVersion: String?
}

struct Report: Codable {
    let schemaVersion: UInt16
    let evidenceVersion: String
    let runtime: RuntimeFingerprint
    let inputPathBasename: String
    let inputByteCount: Int
    let inputSHA256: String
    let targetWidth: Int
    let targetHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let outputRGBSHA256: String
    let containerByteCount: Int
    let containerSHA256: String
    let pngByteCount: Int
    let pngSHA256: String
    let warmupIterations: Int
    let measuredIterations: Int
    let orderCounts: [String: Int]
    let directDecode: DurationSummary
    let directDecodeAndRGBMaterialization: DurationSummary
    let containerEncodeFromSurface: DurationSummary
    let containerMaterializeAndEncode: DurationSummary
    let containerCreationFromOriginal: DurationSummary
    let containerValidateAndDecode: DurationSummary
    let trustedContainerDecode: DurationSummary
    let trustedContainerDecodeAndBridge: DurationSummary
    let executorTrustedContainerDecodeAndBridge: DurationSummary
    let rawSurfaceBridgeConstruction: DurationSummary
    let rawSurfaceBridgeDisplayReady: DurationSummary
    let rawSurfaceBridgeW2Materialization: DurationSummary
    let opaquePremultipliedRawSurfaceW2Materialization: DurationSummary
    let packedRGB24RawSurfaceW2Materialization: DurationSummary
    let packedRGB24LazyCompressedBridgeW2Materialization: DurationSummary
    let lazyCompressedBridgeConstruction: DurationSummary
    let lazyCompressedBridgeDisplayReady: DurationSummary
    let lazyCompressedBridgeW2Materialization: DurationSummary
    let opaquePremultipliedLazyCompressedBridgeW2Materialization: DurationSummary
    let containerDecodeVerifiedBytes: DurationSummary
    let containerDecodeAndDisplayReady: DurationSummary
    let fileBlobPhysicalIDLookup: DurationSummary
    let directBlobFileRead: DurationSummary
    let directBlobFileReadAndDigest: DurationSummary
    let fileBlobStoreRead: DurationSummary
    let akashicLoadAndDecode: DurationSummary
    let akashicLoadDecodeAndDisplayReady: DurationSummary
    let pngCreationFromOriginal: DurationSummary
    let pngDecodeAndDisplayReady: DurationSummary
}

struct DerivedRasterBenchmarkOperations {
    let context: DerivedRasterBenchmarkContext
    typealias Operation = () async throws -> UInt64

    func table() -> [String: Operation] {
        [
            "direct": { try await directDecode() },
            "direct-materialized": { try await directMaterialized() },
            "encode-surface": { try await encodeFromSurface() },
            "materialize-encode": { try await materializeAndEncode() },
            "creation": { try await creation() },
            "container": { try await containerRead() },
            "container-display-ready": { try await containerDisplayReady() },
            "raw-bridge": { try await rawBridgeConstruction() },
            "raw-bridge-display-ready": { try await rawBridgeDisplayReady() },
            "raw-bridge-w2-materialization": { try await rawBridgeW2Materialization() },
            "opaque-premultiplied-raw-w2-materialization": {
                try await opaquePremultipliedRawW2Materialization()
            },
            "packed-rgb24-raw-w2-materialization": { try await packedRGB24RawW2Materialization() },
            "packed-rgb24-lazy-w2-materialization": {
                try await packedRGB24LazyW2Materialization()
            },
            "lazy-bridge": { try await lazyBridgeConstruction() },
            "lazy-bridge-display-ready": { try await lazyBridgeDisplayReady() },
            "lazy-bridge-w2-materialization": { try await lazyBridgeW2Materialization() },
            "opaque-premultiplied-lazy-w2-materialization": {
                try await opaquePremultipliedLazyW2Materialization()
            },
            "file-blob-physical-id": { try await fileBlobPhysicalLookup() },
            "direct-blob-file": { try await directBlobFileRead() },
            "direct-blob-file-digest": { try await directBlobFileReadAndDigest() },
            "file-blob": { try await fileBlobRead() },
            "store": { try await storeRead() },
            "store-display-ready": { try await storeDisplayReady() },
            "png-creation": { try await pngCreation() },
            "png-display-ready": { try await pngDisplayReady() },
            "validate-decode": { try await validateDecode() },
            "trusted-decode": { try await trustedDecode() },
            "trusted-decode-bridge": { try await trustedDecodeAndBridge() },
            "executor-trusted-decode-bridge": { try await executorTrustedDecodeAndBridge() },
        ]
    }

    private var r: DerivedRasterReferenceFixture { context.reference }

    private func directDecode() async throws -> UInt64 {
        try measure {
            _ = try r.decode.decoder.decode(
                data: r.decode.input, probe: r.decode.probe, request: r.decode.request,
                limits: r.decode.limits
            )
        }
    }

    private func directMaterialized() async throws -> UInt64 {
        try measure {
            let image = try r.decode.decoder.decode(
                data: r.decode.input, probe: r.decode.probe, request: r.decode.request,
                limits: r.decode.limits
            )
            guard sha256(try rgbData(from: image.cgImage)) == r.displayDigest else {
                throw LabError.outputMismatch
            }
        }
    }

    private func encodeFromSurface() async throws -> UInt64 {
        try measure {
            let value = try DerivedRasterContainer.encode(
                pixelData: r.storagePixels,
                width: r.decode.reference.pixelWidth,
                height: r.decode.reference.pixelHeight,
                format: r.format
            )
            guard sha256(value) == r.containerDigest else { throw LabError.outputMismatch }
        }
    }

    private func materializeAndEncode() async throws -> UInt64 {
        try measure {
            let surface = try DerivedRasterPixelBridge.surface(
                from: r.decode.reference, format: r.format)
            let value = try DerivedRasterContainer.encode(
                pixelData: surface.pixelData,
                width: r.decode.reference.pixelWidth,
                height: r.decode.reference.pixelHeight,
                format: r.format
            )
            guard sha256(value) == r.containerDigest else { throw LabError.outputMismatch }
        }
    }

    private func creation() async throws -> UInt64 {
        try measure {
            let image = try r.decode.decoder.decode(
                data: r.decode.input, probe: r.decode.probe, request: r.decode.request,
                limits: r.decode.limits
            )
            let surface = try DerivedRasterPixelBridge.surface(from: image, format: r.format)
            let value = try DerivedRasterContainer.encode(
                pixelData: surface.pixelData,
                width: image.pixelWidth,
                height: image.pixelHeight,
                format: r.format
            )
            guard value.count > DerivedRasterContainer.headerByteCount else {
                throw LabError.outputMismatch
            }
        }
    }

    private func containerRead() async throws -> UInt64 {
        try measure {
            let value = try DerivedRasterContainer.decode(r.container, expectedFormat: r.format)
            guard value.pixelDigestHex == r.storageDigest else { throw LabError.outputMismatch }
        }
    }

    private func containerDisplayReady() async throws -> UInt64 {
        try measure {
            let surface = try DerivedRasterContainer.decode(r.container)
            let image = try DerivedRasterPixelBridge.image(from: surface)
            guard sha256(try rgbData(from: image.cgImage)) == r.displayDigest else {
                throw LabError.outputMismatch
            }
        }
    }

    private func rawBridgeConstruction() async throws -> UInt64 {
        try measure {
            let image = try DerivedRasterPixelBridge.image(from: r.surface)
            guard image.pixelWidth == r.decode.reference.pixelWidth,
                image.pixelHeight == r.decode.reference.pixelHeight
            else { throw LabError.outputMismatch }
        }
    }

    private func rawBridgeDisplayReady() async throws -> UInt64 {
        try measure {
            let image = try DerivedRasterPixelBridge.image(from: r.surface)
            guard sha256(try rgbData(from: image.cgImage)) == r.displayDigest else {
                throw LabError.outputMismatch
            }
        }
    }

    private func lazyBridgeConstruction() async throws -> UInt64 {
        try measure {
            let image = try DerivedRasterPixelBridge.lazyImage(from: r.compressedSurface)
            guard image.pixelWidth == r.decode.reference.pixelWidth,
                image.pixelHeight == r.decode.reference.pixelHeight
            else { throw LabError.outputMismatch }
        }
    }

    private func lazyBridgeDisplayReady() async throws -> UInt64 {
        try measure {
            let image = try DerivedRasterPixelBridge.lazyImage(from: r.compressedSurface)
            guard sha256(try rgbData(from: image.cgImage)) == r.displayDigest else {
                throw LabError.outputMismatch
            }
        }
    }

    private func rawBridgeW2Materialization() async throws -> UInt64 {
        let image = try DerivedRasterPixelBridge.image(from: r.surface)
        return try measure { _ = try w2MaterializePixels(image.cgImage) }
    }

    private func opaquePremultipliedRawW2Materialization() async throws -> UInt64 {
        let image = try opaquePremultipliedImage(from: r.surface)
        return try measure { _ = try w2MaterializePixels(image) }
    }

    private func packedRGB24RawW2Materialization() async throws -> UInt64 {
        let image = try packedRGB24Image(
            pixelData: r.packedRGB24Pixels,
            width: r.surface.width,
            height: r.surface.height
        )
        return try measure { _ = try w2MaterializePixels(image) }
    }

    private func packedRGB24LazyW2Materialization() async throws -> UInt64 {
        let image = try packedRGB24CompressedImage(from: r.packedRGB24CompressedSurface)
        return try measure { _ = try w2MaterializePixels(image) }
    }

    private func lazyBridgeW2Materialization() async throws -> UInt64 {
        let image = try DerivedRasterPixelBridge.lazyImage(from: r.compressedSurface)
        return try measure { _ = try w2MaterializePixels(image.cgImage) }
    }

    private func opaquePremultipliedLazyW2Materialization() async throws -> UInt64 {
        let image = try DerivedRasterPixelBridge.lazyImage(from: r.compressedSurface)
        return try measure { _ = try w2MaterializePixels(image.cgImage) }
    }

    private func fileBlobPhysicalLookup() async throws -> UInt64 {
        let started = DispatchTime.now().uptimeNanoseconds
        let value = await context.directBlob.store.physicalID(
            digest: context.directBlob.digest,
            partition: context.directBlob.partition
        )
        guard value == context.directBlob.physicalID else { throw LabError.storageMiss }
        return DispatchTime.now().uptimeNanoseconds &- started
    }

    private func directBlobFileRead() async throws -> UInt64 {
        let started = DispatchTime.now().uptimeNanoseconds
        let value = try Data(contentsOf: context.directBlob.fileURL)
        guard value.count == r.container.count else { throw LabError.outputMismatch }
        return DispatchTime.now().uptimeNanoseconds &- started
    }

    private func directBlobFileReadAndDigest() async throws -> UInt64 {
        let started = DispatchTime.now().uptimeNanoseconds
        let value = try Data(contentsOf: context.directBlob.fileURL)
        guard context.directBlob.digest.matches(value) else { throw LabError.outputMismatch }
        return DispatchTime.now().uptimeNanoseconds &- started
    }

    private func fileBlobRead() async throws -> UInt64 {
        let started = DispatchTime.now().uptimeNanoseconds
        let value = try await context.directBlob.store.read(
            digest: context.directBlob.digest,
            partition: context.directBlob.partition
        )
        guard value.count == r.container.count else { throw LabError.outputMismatch }
        return DispatchTime.now().uptimeNanoseconds &- started
    }

    private func storeRead() async throws -> UInt64 {
        let started = DispatchTime.now().uptimeNanoseconds
        let artifact = try await loadArtifact()
        let value = try DerivedRasterContainer.decode(
            artifact.container,
            expectedContainerDigestHex: r.containerDigest,
            containerContentDigestAlreadyVerified: artifact.containerContentDigestVerified,
            expectedFormat: r.format
        )
        guard value.pixelDigestHex == r.storageDigest else { throw LabError.outputMismatch }
        return DispatchTime.now().uptimeNanoseconds &- started
    }

    private func storeDisplayReady() async throws -> UInt64 {
        let started = DispatchTime.now().uptimeNanoseconds
        let artifact = try await loadArtifact()
        let surface = try DerivedRasterContainer.decode(
            artifact.container,
            expectedContainerDigestHex: r.containerDigest,
            containerContentDigestAlreadyVerified: artifact.containerContentDigestVerified,
            expectedFormat: r.format
        )
        let image = try DerivedRasterPixelBridge.image(from: surface)
        guard sha256(try rgbData(from: image.cgImage)) == r.displayDigest else {
            throw LabError.outputMismatch
        }
        return DispatchTime.now().uptimeNanoseconds &- started
    }

    private func loadArtifact() async throws -> DerivedRasterStoredArtifact {
        guard
            let artifact = try await context.persistence.store.load(
                artifactKeyDigest: context.persistence.record.artifactKeyDigest,
                namespaceFingerprint: context.persistence.namespace,
                namespaceGeneration: 1
            )
        else { throw LabError.storageMiss }
        return artifact
    }

    private func pngCreation() async throws -> UInt64 {
        try measure {
            let image = try r.decode.decoder.decode(
                data: r.decode.input, probe: r.decode.probe, request: r.decode.request,
                limits: r.decode.limits
            )
            let png = try pngData(from: image.cgImage)
            guard !png.isEmpty else { throw LabError.outputMismatch }
        }
    }

    private func pngDisplayReady() async throws -> UInt64 {
        try measure {
            let image = try image(fromPNGData: r.png)
            guard sha256(try rgbData(from: image)) == r.displayDigest else {
                throw LabError.outputMismatch
            }
        }
    }

    private func validateDecode() async throws -> UInt64 {
        try measure {
            let value = try DerivedRasterContainer.decode(
                r.container,
                expectedContainerDigestHex: r.containerDigest
            )
            guard value.pixelDigestHex == r.storageDigest else { throw LabError.outputMismatch }
        }
    }

    private func trustedDecode() async throws -> UInt64 {
        try measure {
            let value = try DerivedRasterContainer.decode(
                r.container,
                expectedContainerDigestHex: r.containerDigest,
                containerContentDigestAlreadyVerified: true,
                expectedFormat: r.format
            )
            guard value.pixelDigestHex == r.storageDigest else { throw LabError.outputMismatch }
        }
    }

    private func trustedDecodeAndBridge() async throws -> UInt64 {
        try measure {
            let surface = try DerivedRasterContainer.decode(
                r.container,
                expectedContainerDigestHex: r.containerDigest,
                containerContentDigestAlreadyVerified: true,
                expectedFormat: r.format
            )
            let image = try DerivedRasterPixelBridge.image(from: surface)
            guard image.pixelWidth == surface.width, image.pixelHeight == surface.height else {
                throw LabError.outputMismatch
            }
        }
    }

    private func executorTrustedDecodeAndBridge() async throws -> UInt64 {
        let started = DispatchTime.now().uptimeNanoseconds
        let image = try await context.readExecutor.run {
            let surface = try DerivedRasterContainer.decode(
                r.container,
                expectedContainerDigestHex: r.containerDigest,
                containerContentDigestAlreadyVerified: true,
                expectedFormat: r.format
            )
            return try DerivedRasterPixelBridge.image(from: surface)
        }
        guard image.pixelWidth == r.decode.reference.pixelWidth,
            image.pixelHeight == r.decode.reference.pixelHeight
        else { throw LabError.outputMismatch }
        return DispatchTime.now().uptimeNanoseconds &- started
    }
}

@main
private enum FoveaDerivedRasterLab {
    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "--write-accounting" {
            try await DerivedRasterWriteAccountingLab.run(arguments: CommandLine.arguments)
            return
        }
        try await DerivedRasterBenchmarkRunner.run(
            options: try Options(arguments: CommandLine.arguments)
        )
    }
}
