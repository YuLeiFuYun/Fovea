import AkashicDisk
import CoreGraphics
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaTesting
import ImageCraftImageIO
import ImageIO
import UniformTypeIdentifiers

func makeTemporaryDirectory(_ name: String = UUID().uuidString) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("FoveaTests", isDirectory: true)
    .appendingPathComponent(name, isDirectory: true)
  try? FileManager.default.removeItem(at: url)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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

func makePipeline(
  stubs: [FakeHTTPTransport.Stub],
  root: URL? = nil,
  namespaceRegistry: NamespaceRegistry = NamespaceRegistry(),
  softLimitBytes: Int = 8 * 1024 * 1024,
  diagnostics: any DiagnosticsSink = NullDiagnosticsSink()
) async throws -> (
  FoveaPipeline, FakeHTTPTransport, OriginalEncodedStore, RepresentationRecordStore
) {
  let root = try root ?? makeTemporaryDirectory()
  let transport = FakeHTTPTransport(stubs: stubs)
  let encoded = try await OriginalEncodedStore.open(
    root: root.appendingPathComponent("encoded"), softLimitBytes: softLimitBytes)
  let records = try await RepresentationRecordStore.open(
    root: root.appendingPathComponent("records"))
  let pipeline = FoveaPipeline(
    transport: transport,
    encodedStore: encoded,
    recordStore: records,
    namespaceRegistry: namespaceRegistry,
    diagnostics: diagnostics,
    decoder: ImageIOImageDecoder()
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
  vary: HTTPVarySelection = HTTPVarySelection(fieldNames: [], values: [:]),
  statusCode: Int = 200,
  requestTime: Date = Date(),
  responseTime: Date = Date(),
  responseDate: Date? = nil,
  expiresAt: Date? = nil,
  etag: String? = nil,
  lastModified: String? = nil,
  disposition: CacheDisposition = .reusable,
  contentID: String = "sha256:00:0",
  payloadLength: Int = 0,
  contentType: String? = "image/png"
) -> RepresentationRecord {
  RepresentationRecord(
    recordSchemaVersion: recordSchemaVersion,
    securityNamespace: namespace,
    namespaceGeneration: namespaceGeneration,
    baseKeyDigest: baseKeyDigest,
    variantKeyDigest: variantKeyDigest,
    vary: vary,
    statusCode: statusCode,
    requestTime: requestTime,
    responseTime: responseTime,
    responseDate: responseDate,
    expiresAt: expiresAt,
    etag: etag,
    lastModified: lastModified,
    disposition: disposition,
    contentID: contentID,
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
