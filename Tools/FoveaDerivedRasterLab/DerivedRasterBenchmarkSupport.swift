import AkashicCore
import AkashicDisk
import Dispatch
import Foundation
import FoveaCore
import FoveaPersistence
import FoveaStorage
import ImageCraftCore
import ImageCraftImageIO

struct DerivedRasterDecodeFixture {
    let input: Data
    let decoder: ImageIOImageDecoder
    let limits: DecodeLimits
    let probe: ImageProbe
    let request: ImageDecodeRequest
    let reference: DecodedImage

    static func make(options: Options) throws -> DerivedRasterDecodeFixture {
        let input = try Data(contentsOf: options.input)
        guard !input.isEmpty else { throw LabError.invalidArguments }
        let decoder = ImageIOImageDecoder()
        let limits = DecodeLimits(
            maximumEncodedBytes: max(input.count, 1),
            maximumDimension: 16_384,
            maximumPixelCount: 100_000_000,
            maximumFrameCount: 1,
            maximumMetadataBytes: 4 * 1_024 * 1_024,
            maximumAuxiliaryAttachments: 0,
            allowedFormats: [.jpeg]
        )
        let probe = try decoder.probe(data: input, limits: limits)
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: options.targetWidth, height: options.targetHeight),
            contentMode: .fit,
            colorPolicy: .convertToSRGB
        )
        return DerivedRasterDecodeFixture(
            input: input,
            decoder: decoder,
            limits: limits,
            probe: probe,
            request: request,
            reference: try decoder.decode(
                data: input, probe: probe, request: request, limits: limits)
        )
    }
}

struct DerivedRasterReferenceFixture {
    let decode: DerivedRasterDecodeFixture
    let displayDigest: String
    let format: DerivedRasterFormatIdentity
    let surface: DerivedRasterSurface
    let storagePixels: Data
    let storageDigest: String
    let packedRGB24Pixels: Data
    let packedRGB24CompressedSurface: PackedRGB24CompressedSurface
    let container: Data
    let containerDigest: String
    let png: Data
    let pngDigest: String
    let compressedSurface: DerivedRasterCompressedSurface

    static func make(options: Options) throws -> DerivedRasterReferenceFixture {
        let decode = try DerivedRasterDecodeFixture.make(options: options)
        let displayDigest = sha256(try rgbData(from: decode.reference.cgImage))
        let format = DerivedRasterContainer.formatIdentity
        let surface = try DerivedRasterPixelBridge.surface(from: decode.reference, format: format)
        try validatePixelControls(surface: surface, displayDigest: displayDigest)
        let packed = try packedRGB24Data(from: surface)
        let packedCompressed = try makePackedRGB24CompressedSurface(
            pixelData: packed,
            width: surface.width,
            height: surface.height
        )
        let packedLazy = try packedRGB24CompressedImage(from: packedCompressed)
        guard packedLazy.alphaInfo == .none,
            sha256(try rgbData(from: packedLazy)) == displayDigest
        else { throw LabError.outputMismatch }
        let container = try DerivedRasterContainer.encode(
            pixelData: surface.pixelData,
            width: decode.reference.pixelWidth,
            height: decode.reference.pixelHeight,
            format: format
        )
        let digest = sha256(container)
        let decoded = try DerivedRasterContainer.decode(
            container,
            expectedContainerDigestHex: digest,
            expectedFormat: format
        )
        guard decoded.pixelData == surface.pixelData else { throw LabError.outputMismatch }
        let png = try pngData(from: decode.reference.cgImage)
        guard sha256(try rgbData(from: try image(fromPNGData: png))) == displayDigest else {
            throw LabError.outputMismatch
        }
        let compressed = try DerivedRasterContainer.validatedCompressedSurface(
            container,
            expectedContainerDigestHex: digest,
            containerContentDigestAlreadyVerified: true,
            expectedFormat: format
        )
        guard
            sha256(
                try rgbData(from: try DerivedRasterPixelBridge.lazyImage(from: compressed).cgImage))
                == displayDigest
        else { throw LabError.outputMismatch }
        return DerivedRasterReferenceFixture(
            decode: decode,
            displayDigest: displayDigest,
            format: format,
            surface: surface,
            storagePixels: surface.pixelData,
            storageDigest: surface.pixelDigestHex,
            packedRGB24Pixels: packed,
            packedRGB24CompressedSurface: packedCompressed,
            container: container,
            containerDigest: digest,
            png: png,
            pngDigest: sha256(png),
            compressedSurface: compressed
        )
    }

    private static func validatePixelControls(
        surface: DerivedRasterSurface,
        displayDigest: String
    ) throws {
        let opaque = try opaquePremultipliedImage(from: surface)
        guard sha256(try rgbData(from: opaque)) == displayDigest else {
            throw LabError.outputMismatch
        }
        let packed = try packedRGB24Data(from: surface)
        let image = try packedRGB24Image(
            pixelData: packed,
            width: surface.width,
            height: surface.height
        )
        guard sha256(try rgbData(from: image)) == displayDigest else {
            throw LabError.outputMismatch
        }
    }
}

struct DerivedRasterStoreFixture {
    let root: URL
    let store: AkashicDerivedRasterStore
    let namespace: StorageNamespaceFingerprint
    let record: DerivedRasterRecord

    static func make(
        options: Options,
        reference: DerivedRasterReferenceFixture
    ) async throws -> DerivedRasterStoreFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fovea-derived-raster-lab-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let store = try await AkashicDerivedRasterStore.open(
            root: root,
            limits: DerivedRasterStoreLimits(
                softTotalBytes: 1024 * 1024 * 1024,
                maximumBlobBytes: 1024 * 1024 * 1024,
                maximumWriteBytesPerWindow: 1024 * 1024 * 1024 * 1024,
                writeBudgetWindowNanoseconds: 60_000_000_000
            )
        )
        let namespace = StorageNamespaceFingerprint(namespace: "derived-raster-lab")
        let record = try DerivedRasterRecord(
            artifactKeyDigest: sha256(Data("artifact:\(reference.containerDigest)".utf8)),
            baseKeyDigest: sha256(Data("base:\(options.input.lastPathComponent)".utf8)),
            variantKeyDigest: sha256(Data("variant:\(options.input.lastPathComponent)".utf8)),
            namespaceFingerprint: namespace,
            namespaceGeneration: 1,
            containerContentID: BlobDigest.sha256(of: reference.container).canonicalString,
            containerByteCount: reference.container.count,
            formatIdentifier: reference.format.identifier,
            formatSemanticVersion: reference.format.semanticVersion,
            pixelLayoutFingerprint: reference.format.pixelLayoutFingerprint,
            pixelDigestHex: reference.storageDigest,
            pixelWidth: reference.decode.reference.pixelWidth,
            pixelHeight: reference.decode.reference.pixelHeight,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        try await store.commit(container: reference.container, record: record)
        return DerivedRasterStoreFixture(
            root: root, store: store, namespace: namespace, record: record)
    }
}

struct DerivedRasterDirectBlobFixture {
    let root: URL
    let store: FileBlobStore
    let digest: BlobDigest
    let partition: CachePartitionID
    let physicalID: PhysicalBlobID
    let fileURL: URL

    static func make(container: Data) async throws -> DerivedRasterDirectBlobFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fovea-derived-raster-blob-lab-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let store = try await FileBlobStore.open(
            root: root,
            limits: FileBlobStoreLimits(
                softTotalBytes: 1024 * 1024 * 1024,
                maximumBlobBytes: 1024 * 1024 * 1024
            )
        )
        let digest = BlobDigest.sha256(of: container)
        let partition = try CachePartitionID.derive(
            domain: "dev.fovea.derived-raster.lab-direct.v1",
            material: Data("partition".utf8)
        )
        _ = try await store.commit(data: container, digest: digest, partition: partition)
        guard let physicalID = await store.physicalID(digest: digest, partition: partition) else {
            throw LabError.storageMiss
        }
        let fileURL = root.appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(physicalID.rawValue.uuidString.lowercased(), isDirectory: false)
        return DerivedRasterDirectBlobFixture(
            root: root,
            store: store,
            digest: digest,
            partition: partition,
            physicalID: physicalID,
            fileURL: fileURL
        )
    }
}

struct DerivedRasterBenchmarkContext {
    let options: Options
    let reference: DerivedRasterReferenceFixture
    let persistence: DerivedRasterStoreFixture
    let directBlob: DerivedRasterDirectBlobFixture
    let readExecutor: DispatchWorkExecutor

    static func make(options: Options) async throws -> DerivedRasterBenchmarkContext {
        let reference = try DerivedRasterReferenceFixture.make(options: options)
        return DerivedRasterBenchmarkContext(
            options: options,
            reference: reference,
            persistence: try await DerivedRasterStoreFixture.make(
                options: options, reference: reference),
            directBlob: try await DerivedRasterDirectBlobFixture.make(
                container: reference.container),
            readExecutor: DispatchWorkExecutor(
                label: "dev.fovea.derived-raster-lab-read",
                qos: .userInitiated,
                concurrent: true
            )
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: persistence.root)
        try? FileManager.default.removeItem(at: directBlob.root)
    }
}

struct DerivedRasterBenchmarkSamples {
    var values: [String: [UInt64]] = [:]
    var orderCounts: [String: Int] = [:]

    mutating func append(_ duration: UInt64, for key: String) {
        values[key, default: []].append(duration)
    }

    func durationSummary(_ key: String) throws -> DurationSummary {
        guard let values = values[key], !values.isEmpty else { throw LabError.outputMismatch }
        return summary(values)
    }
}

enum DerivedRasterBenchmarkRunner {
    private static let fixedKeys = [
        "validate-decode", "trusted-decode", "trusted-decode-bridge",
        "executor-trusted-decode-bridge",
    ]

    static func run(options: Options) async throws {
        let context = try await DerivedRasterBenchmarkContext.make(options: options)
        defer { context.cleanup() }
        let samples = try await collectSamples(context: context)
        let report = try makeReport(context: context, samples: samples)
        try write(report: report, to: options.output)
    }

    private static func collectSamples(
        context: DerivedRasterBenchmarkContext
    ) async throws -> DerivedRasterBenchmarkSamples {
        let operations = DerivedRasterBenchmarkOperations(context: context).table()
        let warmups = 3
        var samples = DerivedRasterBenchmarkSamples()
        for iteration in 0..<(warmups + context.options.iterations) {
            let rotation = iteration % 3
            let record = iteration >= warmups
            if record { samples.orderCounts["rotation-\(rotation)", default: 0] += 1 }
            for key in rotationKeys(rotation) + fixedKeys {
                guard let operation = operations[key] else { throw LabError.outputMismatch }
                let duration = try await operation()
                if record { samples.append(duration, for: key) }
            }
        }
        return samples
    }

    private static func rotationKeys(_ rotation: Int) -> [String] {
        switch rotation {
        case 0:
            return [
                "direct", "container", "file-blob-physical-id", "direct-blob-file",
                "direct-blob-file-digest", "file-blob", "store", "container-display-ready",
                "raw-bridge", "lazy-bridge", "raw-bridge-display-ready",
                "lazy-bridge-display-ready",
                "raw-bridge-w2-materialization", "opaque-premultiplied-raw-w2-materialization",
                "packed-rgb24-raw-w2-materialization", "packed-rgb24-lazy-w2-materialization",
                "lazy-bridge-w2-materialization", "opaque-premultiplied-lazy-w2-materialization",
                "direct-materialized", "store-display-ready", "encode-surface",
                "materialize-encode",
                "creation", "png-creation", "png-display-ready",
            ]
        case 1:
            return [
                "container", "direct-materialized", "png-display-ready", "store-display-ready",
                "lazy-bridge-display-ready", "raw-bridge-display-ready", "encode-surface",
                "creation",
                "direct-blob-file-digest", "file-blob", "store", "file-blob-physical-id",
                "png-creation", "direct-blob-file", "materialize-encode",
                "lazy-bridge-w2-materialization", "opaque-premultiplied-lazy-w2-materialization",
                "opaque-premultiplied-raw-w2-materialization",
                "packed-rgb24-raw-w2-materialization",
                "packed-rgb24-lazy-w2-materialization", "raw-bridge-w2-materialization",
                "lazy-bridge", "raw-bridge", "container-display-ready", "direct",
            ]
        default:
            return [
                "store", "png-creation", "creation", "direct", "container-display-ready",
                "lazy-bridge", "raw-bridge", "direct-blob-file", "materialize-encode", "file-blob",
                "container", "file-blob-physical-id", "lazy-bridge-display-ready",
                "raw-bridge-display-ready", "png-display-ready", "raw-bridge-w2-materialization",
                "opaque-premultiplied-raw-w2-materialization",
                "packed-rgb24-raw-w2-materialization",
                "packed-rgb24-lazy-w2-materialization", "lazy-bridge-w2-materialization",
                "opaque-premultiplied-lazy-w2-materialization", "direct-blob-file-digest",
                "encode-surface", "direct-materialized", "store-display-ready",
            ]
        }
    }

    private static func makeReport(
        context: DerivedRasterBenchmarkContext,
        samples: DerivedRasterBenchmarkSamples
    ) throws -> Report {
        let r = context.reference
        return Report(
            schemaVersion: 1,
            evidenceVersion: "fovea-derived-raster-container-performance-v1",
            runtime: runtimeFingerprint(),
            inputPathBasename: context.options.input.lastPathComponent,
            inputByteCount: r.decode.input.count,
            inputSHA256: sha256(r.decode.input),
            targetWidth: context.options.targetWidth,
            targetHeight: context.options.targetHeight,
            outputWidth: r.decode.reference.pixelWidth,
            outputHeight: r.decode.reference.pixelHeight,
            outputRGBSHA256: r.displayDigest,
            containerByteCount: r.container.count,
            containerSHA256: r.containerDigest,
            pngByteCount: r.png.count,
            pngSHA256: r.pngDigest,
            warmupIterations: 3,
            measuredIterations: context.options.iterations,
            orderCounts: samples.orderCounts,
            directDecode: try samples.durationSummary("direct"),
            directDecodeAndRGBMaterialization: try samples.durationSummary("direct-materialized"),
            containerEncodeFromSurface: try samples.durationSummary("encode-surface"),
            containerMaterializeAndEncode: try samples.durationSummary("materialize-encode"),
            containerCreationFromOriginal: try samples.durationSummary("creation"),
            containerValidateAndDecode: try samples.durationSummary("validate-decode"),
            trustedContainerDecode: try samples.durationSummary("trusted-decode"),
            trustedContainerDecodeAndBridge: try samples.durationSummary("trusted-decode-bridge"),
            executorTrustedContainerDecodeAndBridge:
                try samples.durationSummary("executor-trusted-decode-bridge"),
            rawSurfaceBridgeConstruction: try samples.durationSummary("raw-bridge"),
            rawSurfaceBridgeDisplayReady: try samples.durationSummary("raw-bridge-display-ready"),
            rawSurfaceBridgeW2Materialization: try samples.durationSummary(
                "raw-bridge-w2-materialization"),
            opaquePremultipliedRawSurfaceW2Materialization:
                try samples.durationSummary("opaque-premultiplied-raw-w2-materialization"),
            packedRGB24RawSurfaceW2Materialization:
                try samples.durationSummary("packed-rgb24-raw-w2-materialization"),
            packedRGB24LazyCompressedBridgeW2Materialization:
                try samples.durationSummary("packed-rgb24-lazy-w2-materialization"),
            lazyCompressedBridgeConstruction: try samples.durationSummary("lazy-bridge"),
            lazyCompressedBridgeDisplayReady: try samples.durationSummary(
                "lazy-bridge-display-ready"),
            lazyCompressedBridgeW2Materialization:
                try samples.durationSummary("lazy-bridge-w2-materialization"),
            opaquePremultipliedLazyCompressedBridgeW2Materialization:
                try samples.durationSummary("opaque-premultiplied-lazy-w2-materialization"),
            containerDecodeVerifiedBytes: try samples.durationSummary("container"),
            containerDecodeAndDisplayReady: try samples.durationSummary("container-display-ready"),
            fileBlobPhysicalIDLookup: try samples.durationSummary("file-blob-physical-id"),
            directBlobFileRead: try samples.durationSummary("direct-blob-file"),
            directBlobFileReadAndDigest: try samples.durationSummary("direct-blob-file-digest"),
            fileBlobStoreRead: try samples.durationSummary("file-blob"),
            akashicLoadAndDecode: try samples.durationSummary("store"),
            akashicLoadDecodeAndDisplayReady: try samples.durationSummary("store-display-ready"),
            pngCreationFromOriginal: try samples.durationSummary("png-creation"),
            pngDecodeAndDisplayReady: try samples.durationSummary("png-display-ready")
        )
    }

    private static func write(report: Report, to output: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(report).write(to: output, options: .atomic)
    }
}
