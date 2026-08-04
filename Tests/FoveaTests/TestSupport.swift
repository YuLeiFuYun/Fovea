import AkashicCore
import AkashicDisk
import CoreGraphics
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaTesting
import ImageCraftCore
import ImageCraftImageIO
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// 等待异步可观察条件在截止时间前成立。
///
/// 并发测试必须等待明确状态，不得用固定延迟推测任务已经进入某阶段。
/// 该辅助函数只用于测试控制面；生产调度不得依赖轮询。
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(1),
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        try Task.checkCancellation()
        guard clock.now < deadline else {
            XCTFail("等待异步条件超时：\(description)", file: file, line: line)
            return
        }
        try await Task.sleep(for: pollInterval)
    }
}

@MainActor
func waitUntilOnMainActor(
    _ description: String = "MainActor 条件",
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(1),
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @MainActor () async -> Bool
) async throws {
    try await waitUntil(
        description,
        timeout: timeout,
        pollInterval: pollInterval,
        file: file,
        line: line
    ) {
        await condition()
    }
}

func makeTemporaryDirectory(_ name: String = UUID().uuidString) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FoveaTests", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: url.path
    )
    return url
}

func makePNG(width: Int = 100, height: Int = 50, red: UInt8 = 255) throws -> Data {
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    for index in stride(from: 0, to: pixels.count, by: 4) {
        pixels[index] = red
        pixels[index + 1] = 32
        pixels[index + 2] = 64
        pixels[index + 3] = 255
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    else {
        throw NSError(domain: "FoveaTests", code: 1)
    }
    let data = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        throw NSError(domain: "FoveaTests", code: 2)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "FoveaTests", code: 3)
    }
    return data as Data
}

/// 测试假 codec 的统一最新版能力面。生产代码不提供任意 `ImageDecoding` fallback。
protocol TestImageCodec: ImageCodec {}

extension ImageCodecCapabilities {
    static let foveaTestBaseline = ImageCodecCapabilities(
        formats: Set(EncodedImageFormat.allCases),
        deliveryModes: [.completeFrame],
        progressiveFormats: [],
        trackModes: [.primaryFrame],
        metadata: [.orientation, .sourceColorProfile],
        dynamicRanges: [.standard],
        outputRepresentations: [.coreGraphicsImage],
        cancellationMode: .operationBoundary
    )
}

extension TestImageCodec {
    var codecDescriptor: ImageCodecDescriptor {
        ImageCodecDescriptor(
            identifier: ImageCodecIdentifier(
                rawValue: "test:\(String(reflecting: type(of: self)))"
            ),
            implementationVersion: 1,
            capabilities: .foveaTestBaseline
        )
    }
}

func makePipeline(
    stubs: [FakeHTTPTransport.Stub],
    root: URL? = nil,
    namespaceRegistry: NamespaceRegistry? = nil,
    configuration: PipelineConfiguration = PipelineConfiguration(),
    softLimitBytes: Int = 8 * 1024 * 1024,
    diagnostics: any DiagnosticsSink = NullDiagnosticsSink(),
    decoder: any ImageCodec = ImageIOImageDecoder(),
    renderedImageCache: (any RenderedImageCaching)? = nil
) async throws -> (
    FoveaPipeline, FakeHTTPTransport, AkashicOriginalEncodedStore, RepresentationRecordStore
) {
    let root = try root ?? makeTemporaryDirectory()
    let transport = FakeHTTPTransport(stubs: stubs)
    let encoded = try await AkashicOriginalEncodedStore.open(
        root: root.appendingPathComponent("encoded"), softLimitBytes: softLimitBytes)
    let records = try await RepresentationRecordStore.open(
        root: root.appendingPathComponent("records"))
    let pipeline = FoveaPipeline(
        configuration: configuration,
        transport: transport,
        encodedStore: encoded,
        recordStore: records,
        renderedImageCache: renderedImageCache,
        namespaceRegistry: namespaceRegistry
            ?? NamespaceRegistry(
                maximumTrackedNamespaces: configuration.maximumTrackedNamespaces
            ),
        diagnostics: diagnostics,
        profileAccessPolicy: .unrestricted,
        codec: decoder
    )
    return (pipeline, transport, encoded, records)
}

func variantKey(for request: ImageRequest) -> FetchVariantKey {
    request.fetchVariantKey
}

func makeRepresentationRecord(
    recordSchemaVersion: UInt16 = RepresentationRecord.currentSchemaVersion,
    namespace: String,
    namespaceGeneration: UInt64 = 0,
    baseKeyDigest: String,
    variantKeyDigest: String,
    vary: HTTPVarySelection = .empty,
    statusCode: Int = 200,
    requestTime: Date = Date(),
    responseTime: Date = Date(),
    responseDate: Date? = nil,
    expiresAt: Date? = nil,
    etag: String? = nil,
    lastModified: String? = nil,
    disposition: CacheDisposition = .reusable,
    requiresRevalidation: Bool = false,
    contentID: String = "sha256:00:0",
    payloadLength: Int = 0,
    contentType: String? = "image/png"
) -> RepresentationRecord {
    let normalizedBaseDigest = normalizedTestDigest(baseKeyDigest)
    let normalizedVariantDigest = normalizedTestDigest(variantKeyDigest)
    let normalizedContentID = normalizedTestContentID(contentID, byteCount: payloadLength)
    return RepresentationRecord(
        recordSchemaVersion: recordSchemaVersion,
        securityNamespace: namespace,
        namespaceGeneration: namespaceGeneration,
        baseKeyDigest: normalizedBaseDigest,
        variantKeyDigest: normalizedVariantDigest,
        vary: vary,
        statusCode: statusCode,
        requestTime: requestTime,
        responseTime: responseTime,
        responseDate: responseDate,
        expiresAt: expiresAt,
        etag: etag,
        lastModified: lastModified,
        disposition: disposition,
        requiresRevalidation: requiresRevalidation,
        contentID: normalizedContentID,
        payloadLength: payloadLength,
        contentType: contentType
    )
}

func centerRedComponent(of image: CGImage) throws -> UInt8 {
    var pixel = [UInt8](repeating: 0, count: 4)
    let rendered = pixel.withUnsafeMutableBytes { bytes -> Bool in
        guard let baseAddress = bytes.baseAddress,
            let context = CGContext(
                data: baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return true
    }
    guard rendered else { throw NSError(domain: "FoveaTests", code: 4) }
    return pixel[0]
}

extension Collection {
    var singleElement: Element? {
        count == 1 ? first : nil
    }
}

private func normalizedTestDigest(_ value: String) -> String {
    if value.utf8.count == 64,
        value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    {
        return value
    }
    return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func normalizedTestContentID(_ value: String, byteCount: Int) -> String {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    if parts.count == 3,
        parts[0] == "sha256",
        parts[1].utf8.count == 64,
        parts[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
        Int(parts[2]) == byteCount
    {
        return value
    }
    return "sha256:\(normalizedTestDigest(value)):\(byteCount)"
}

/// 等待前一个 typed store 实例释放进程内 writer lease 后重开同一路径。
///
/// 只容忍 ARC/actor job drain 造成的短暂 `transactionConflict`；超过固定期限仍失败，
/// 防止测试把真实 writer 泄漏伪装成可重试状态。
func reopenAkashicOriginalEncodedStore(
    root: URL,
    limits: OriginalEncodedStoreLimits = OriginalEncodedStoreLimits(),
    timeout: Duration = .seconds(2)
) async throws -> AkashicOriginalEncodedStore {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
        do {
            return try await AkashicOriginalEncodedStore.open(root: root, limits: limits)
        } catch let error as AkashicError where error == .transactionConflict {
            guard clock.now < deadline else { throw error }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
