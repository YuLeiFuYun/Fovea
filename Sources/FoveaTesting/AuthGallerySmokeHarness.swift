import AkashicDisk
import CoreGraphics
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import ImageCraftCore
import ImageIO
import UniformTypeIdentifiers

public struct AuthGalleryCaseResult: Codable, Hashable, Sendable {
  public let identifier: String
  public let passed: Bool
  public let detail: String

  public init(identifier: String, passed: Bool, detail: String) {
    self.identifier = identifier
    self.passed = passed
    self.detail = detail
  }
}

public struct AuthGallerySummary: Codable, Hashable, Sendable {
  public let crossAccountPixelLeakCount: Int
  public let crossAccountMetadataCouplingCount: Int
  public let noStoreReusableWriteCount: Int
  public let logoutResidueCount: Int
  public let crossOriginAuthorizationLeakCount: Int
  public let revokedCommitResidueCount: Int
  public let sensitiveDiagnosticLeakCount: Int
  public let networkRequestCount: Int

  public var totalViolationCount: Int {
    crossAccountPixelLeakCount
      + crossAccountMetadataCouplingCount
      + noStoreReusableWriteCount
      + logoutResidueCount
      + crossOriginAuthorizationLeakCount
      + revokedCommitResidueCount
      + sensitiveDiagnosticLeakCount
  }
}

public struct AuthGallerySmokeArtifact: Codable, Hashable, Sendable {
  public let schemaVersion: Int
  public let workloadID: String
  public let profileID: String
  public let generatedAt: String
  public let platform: String
  public let architecture: String
  public let operatingSystem: String
  public let verifiedCommit: String
  public let cases: [AuthGalleryCaseResult]
  public let diagnostics: [RecordedDiagnosticEvent]
  public let summary: AuthGallerySummary

  public init(
    cases: [AuthGalleryCaseResult],
    diagnostics: [RecordedDiagnosticEvent],
    summary: AuthGallerySummary
  ) {
    self.schemaVersion = 1
    self.workloadID = "W3-Auth-Gallery-Smoke"
    self.profileID = "W3-AUTH-GALLERY-SMOKE-V1"
    self.generatedAt = ISO8601DateFormatter().string(from: Date())
    self.platform = AuthGalleryEnvironment.platform
    self.architecture = AuthGalleryEnvironment.architecture
    self.operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    self.verifiedCommit =
      ProcessInfo.processInfo.environment["FOVEA_VERIFIED_COMMIT"]
      ?? ProcessInfo.processInfo.environment["GITHUB_SHA"]
      ?? "unverified-local"
    self.cases = cases
    self.diagnostics = diagnostics
    self.summary = summary
  }
}

public enum AuthGallerySmokeHarness {
  @discardableResult
  public static func run(outputDirectory: URL) async throws -> AuthGallerySmokeArtifact {
    let isolation = try await runAccountIsolationCase()
    let noStore = try await runNoStoreCase()
    let revokeRace = try await runRevokeRaceCase()
    let redirect = try runRedirectCase()

    let diagnostics = isolation.diagnostics + noStore.diagnostics + revokeRace.diagnostics
    let diagnosticsData = try JSONEncoder().encode(diagnostics)
    let diagnosticString = String(decoding: diagnosticsData, as: UTF8.self)
    let sensitiveDiagnosticLeakCount = [
      "Bearer account-a",
      "Bearer account-b",
      "Bearer no-store",
      "Bearer delayed",
    ].filter { diagnosticString.contains($0) }.count

    let cases =
      isolation.cases + noStore.cases + revokeRace.cases + redirect.cases + [
        AuthGalleryCaseResult(
          identifier: "diagnostics-sensitive-data",
          passed: sensitiveDiagnosticLeakCount == 0,
          detail: "sensitive diagnostic matches=\(sensitiveDiagnosticLeakCount)"
        )
      ]
    let summary = AuthGallerySummary(
      crossAccountPixelLeakCount: isolation.pixelLeaks,
      crossAccountMetadataCouplingCount: isolation.metadataCoupling,
      noStoreReusableWriteCount: noStore.reusableWrites,
      logoutResidueCount: isolation.logoutResidue,
      crossOriginAuthorizationLeakCount: redirect.authorizationLeaks,
      revokedCommitResidueCount: revokeRace.commitResidue,
      sensitiveDiagnosticLeakCount: sensitiveDiagnosticLeakCount,
      networkRequestCount: isolation.networkRequests + noStore.networkRequests
        + revokeRace.networkRequests
    )
    let artifact = AuthGallerySmokeArtifact(
      cases: cases,
      diagnostics: diagnostics,
      summary: summary
    )
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let destination = outputDirectory.appendingPathComponent(
      "w3-auth-gallery-smoke-\(artifact.platform.lowercased()).json"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(artifact).write(to: destination, options: [.atomic])
    return artifact
  }

  private static func runAccountIsolationCase() async throws -> IsolationResult {
    let bodyA = try makeSolidPNG(red: 230)
    let bodyB = try makeSolidPNG(red: 20)
    let origin = AuthenticatedOrigin(responses: [
      "Bearer account-a": .init(
        body: bodyA,
        headers: ["Content-Type": "image/png", "Cache-Control": "private, max-age=3600"]
      ),
      "Bearer account-b": .init(
        body: bodyB,
        headers: ["Content-Type": "image/png", "Cache-Control": "private, max-age=3600"]
      ),
    ])
    let diagnostics = BoundedDiagnosticsSink(capacity: 256)
    let root = try temporaryDirectory("w3-isolation")
    let encoded = try OriginalEncodedStore(root: root.appendingPathComponent("encoded"))
    let records = try RepresentationRecordStore(root: root.appendingPathComponent("records"))
    let pipeline = FoveaPipeline(
      transport: origin,
      encodedStore: encoded,
      recordStore: records,
      diagnostics: diagnostics
    )
    let url = URL(string: "https://images.example.test/avatar")!
    let target = try TargetPixels(width: 40, height: 40)
    let accountA = request(
      url: url,
      target: target,
      namespace: "account-a",
      principal: "principal-a",
      token: "Bearer account-a"
    )
    let accountB = request(
      url: url,
      target: target,
      namespace: "account-b",
      principal: "principal-b",
      token: "Bearer account-b"
    )

    let imageA = try await pipeline.image(for: accountA)
    let imageB = try await pipeline.image(for: accountB)
    let warmA = try await pipeline.image(for: accountA)
    let warmB = try await pipeline.image(for: accountB)
    var pixelLeaks = 0
    if try centerRed(imageA.cgImage) <= 180 { pixelLeaks += 1 }
    if try centerRed(warmA.cgImage) <= 180 { pixelLeaks += 1 }
    if try centerRed(imageB.cgImage) >= 80 { pixelLeaks += 1 }
    if try centerRed(warmB.cgImage) >= 80 { pixelLeaks += 1 }

    let recordA = await records.record(for: accountA.fetchVariantKey.digestHex)
    let recordB = await records.record(for: accountB.fetchVariantKey.digestHex)
    let physicalA = await recordA.flatMapAsync { record in
      await encoded.physicalID(contentID: record.contentID, namespace: "account-a")
    }
    let physicalB = await recordB.flatMapAsync { record in
      await encoded.physicalID(contentID: record.contentID, namespace: "account-b")
    }
    var metadataCoupling = 0
    if recordA?.securityNamespace != "account-a" { metadataCoupling += 1 }
    if recordB?.securityNamespace != "account-b" { metadataCoupling += 1 }
    if physicalA == nil || physicalB == nil || physicalA == physicalB { metadataCoupling += 1 }

    try await pipeline.revoke(namespace: accountA.namespace)
    let revokedRecordA = await records.record(for: accountA.fetchVariantKey.digestHex)
    let revokedPhysicalA = await recordA.flatMapAsync { record in
      await encoded.physicalID(contentID: record.contentID, namespace: "account-a")
    }
    let preservedRecordB = await records.record(for: accountB.fetchVariantKey.digestHex)
    let preservedPhysicalB = await recordB.flatMapAsync { record in
      await encoded.physicalID(contentID: record.contentID, namespace: "account-b")
    }
    var logoutResidue = 0
    if revokedRecordA != nil { logoutResidue += 1 }
    if revokedPhysicalA != nil { logoutResidue += 1 }
    if preservedRecordB == nil || preservedPhysicalB == nil { metadataCoupling += 1 }

    let afterLogoutB = try await pipeline.image(for: accountB)
    if try centerRed(afterLogoutB.cgImage) >= 80 { pixelLeaks += 1 }
    let metrics = await origin.metrics()
    if metrics.requestsByCredential["Bearer account-a"] != 1 { metadataCoupling += 1 }
    if metrics.requestsByCredential["Bearer account-b"] != 1 { metadataCoupling += 1 }

    return IsolationResult(
      cases: [
        .init(
          identifier: "cross-account-pixels",
          passed: pixelLeaks == 0,
          detail: "pixel leaks=\(pixelLeaks)"
        ),
        .init(
          identifier: "cross-account-storage",
          passed: metadataCoupling == 0,
          detail: "metadata coupling=\(metadataCoupling)"
        ),
        .init(
          identifier: "logout-cleanup",
          passed: logoutResidue == 0,
          detail: "logout residue=\(logoutResidue)"
        ),
      ],
      diagnostics: await diagnostics.snapshot(),
      pixelLeaks: pixelLeaks,
      metadataCoupling: metadataCoupling,
      logoutResidue: logoutResidue,
      networkRequests: metrics.requestCount
    )
  }

  private static func runNoStoreCase() async throws -> NoStoreResult {
    let body = try makeSolidPNG(red: 170)
    let origin = AuthenticatedOrigin(responses: [
      "Bearer no-store": .init(
        body: body,
        headers: ["Content-Type": "image/png", "Cache-Control": "private, no-store"]
      )
    ])
    let diagnostics = BoundedDiagnosticsSink(capacity: 128)
    let root = try temporaryDirectory("w3-no-store")
    let encoded = try OriginalEncodedStore(root: root.appendingPathComponent("encoded"))
    let records = try RepresentationRecordStore(root: root.appendingPathComponent("records"))
    let pipeline = FoveaPipeline(
      transport: origin,
      encodedStore: encoded,
      recordStore: records,
      diagnostics: diagnostics
    )
    let imageRequest = request(
      url: URL(string: "https://images.example.test/no-store")!,
      target: try TargetPixels(width: 40, height: 40),
      namespace: "account-no-store",
      principal: "principal-no-store",
      token: "Bearer no-store"
    )
    _ = try await pipeline.image(for: imageRequest)
    _ = try await pipeline.image(for: imageRequest)

    let metrics = await origin.metrics()
    let record = await records.record(for: imageRequest.fetchVariantKey.digestHex)
    let physicalID = await encoded.physicalID(
      contentID: ContentID(data: body).description,
      namespace: imageRequest.namespace.value
    )
    var reusableWrites = 0
    if record != nil { reusableWrites += 1 }
    if physicalID != nil { reusableWrites += 1 }
    if metrics.requestCount != 2 { reusableWrites += 1 }

    return NoStoreResult(
      cases: [
        .init(
          identifier: "private-no-store",
          passed: reusableWrites == 0,
          detail: "reusable writes=\(reusableWrites), requests=\(metrics.requestCount)"
        )
      ],
      diagnostics: await diagnostics.snapshot(),
      reusableWrites: reusableWrites,
      networkRequests: metrics.requestCount
    )
  }

  private static func runRevokeRaceCase() async throws -> RevokeRaceResult {
    let body = try makeSolidPNG(red: 100)
    let origin = AuthenticatedOrigin(responses: [
      "Bearer delayed": .init(
        body: body,
        headers: ["Content-Type": "image/png", "Cache-Control": "private, max-age=3600"]
      )
    ])
    let diagnostics = BoundedDiagnosticsSink(capacity: 128)
    let root = try temporaryDirectory("w3-revoke-race")
    let encoded = try OriginalEncodedStore(root: root.appendingPathComponent("encoded"))
    let barrierStore = CommitBarrierEncodedStore(base: encoded)
    let records = try RepresentationRecordStore(root: root.appendingPathComponent("records"))
    let pipeline = FoveaPipeline(
      transport: origin,
      encodedStore: barrierStore,
      recordStore: records,
      diagnostics: diagnostics
    )
    let imageRequest = request(
      url: URL(string: "https://images.example.test/delayed")!,
      target: try TargetPixels(width: 40, height: 40),
      namespace: "account-delayed",
      principal: "principal-delayed",
      token: "Bearer delayed"
    )

    let task = Task { try await pipeline.image(for: imageRequest) }
    await barrierStore.waitUntilCommitStarts()
    try await pipeline.revoke(namespace: imageRequest.namespace)
    await barrierStore.releaseCommit()
    var deliveredAfterRevoke = false
    do {
      _ = try await task.value
      deliveredAfterRevoke = true
    } catch {
      // Expected.
    }
    let record = await records.record(for: imageRequest.fetchVariantKey.digestHex)
    let physicalID = await encoded.physicalID(
      contentID: ContentID(data: body).description,
      namespace: imageRequest.namespace.value
    )
    var residue = 0
    if deliveredAfterRevoke { residue += 1 }
    if record != nil { residue += 1 }
    if physicalID != nil { residue += 1 }
    let metrics = await origin.metrics()

    return RevokeRaceResult(
      cases: [
        .init(
          identifier: "revoke-commit-race",
          passed: residue == 0,
          detail: "revoked commit residue=\(residue)"
        )
      ],
      diagnostics: await diagnostics.snapshot(),
      commitResidue: residue,
      networkRequests: metrics.requestCount
    )
  }

  private static func runRedirectCase() throws -> RedirectResult {
    var original = URLRequest(url: URL(string: "https://a.example.test/private")!)
    original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    original.setValue("session=secret", forHTTPHeaderField: "Cookie")
    original.setValue("api-secret", forHTTPHeaderField: "X-API-Key")
    original.setValue("image/avif", forHTTPHeaderField: "Accept")
    var proposed = URLRequest(url: URL(string: "https://b.example.test/redirected")!)
    proposed.allHTTPHeaderFields = original.allHTTPHeaderFields
    let sanitized = CredentialHeaderPolicy.sanitizedRedirectRequest(
      original: original,
      proposed: proposed
    )
    let leaks = CredentialHeaderPolicy.sensitiveHeaderNames.filter {
      sanitized.value(forHTTPHeaderField: $0) != nil
    }.count
    let acceptPreserved = sanitized.value(forHTTPHeaderField: "Accept") == "image/avif"
    let violations = leaks + (acceptPreserved ? 0 : 1)
    return RedirectResult(
      cases: [
        .init(
          identifier: "cross-origin-redirect",
          passed: violations == 0,
          detail: "credential leaks=\(leaks), accept preserved=\(acceptPreserved)"
        )
      ],
      authorizationLeaks: violations
    )
  }

  private static func request(
    url: URL,
    target: TargetPixels,
    namespace: String,
    principal: String,
    token: String
  ) -> ImageRequest {
    ImageRequest(
      url: url,
      target: target,
      namespace: SecurityNamespaceID(namespace),
      authorizationContext: AuthorizationContextID(principal),
      credentialGeneration: CredentialGeneration(1),
      headers: ["Authorization": token]
    )
  }

  private static func temporaryDirectory(_ suffix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("FoveaAuthGallery", isDirectory: true)
      .appendingPathComponent("\(suffix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func makeSolidPNG(red: UInt8) throws -> Data {
    let width = 100
    let height = 50
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
      throw AuthGalleryHarnessError.imageGenerationFailed
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
      throw AuthGalleryHarnessError.imageGenerationFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw AuthGalleryHarnessError.imageGenerationFailed
    }
    return data as Data
  }

  private static func centerRed(_ image: CGImage) throws -> UInt8 {
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
      else {
        return false
      }
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
      return true
    }
    guard rendered else { throw AuthGalleryHarnessError.pixelReadFailed }
    return pixel[0]
  }
}

private enum AuthGalleryHarnessError: Error {
  case imageGenerationFailed
  case pixelReadFailed
}

private struct IsolationResult {
  let cases: [AuthGalleryCaseResult]
  let diagnostics: [RecordedDiagnosticEvent]
  let pixelLeaks: Int
  let metadataCoupling: Int
  let logoutResidue: Int
  let networkRequests: Int
}

private struct NoStoreResult {
  let cases: [AuthGalleryCaseResult]
  let diagnostics: [RecordedDiagnosticEvent]
  let reusableWrites: Int
  let networkRequests: Int
}

private struct RevokeRaceResult {
  let cases: [AuthGalleryCaseResult]
  let diagnostics: [RecordedDiagnosticEvent]
  let commitResidue: Int
  let networkRequests: Int
}

private struct RedirectResult {
  let cases: [AuthGalleryCaseResult]
  let authorizationLeaks: Int
}

private actor AuthenticatedOrigin: HTTPTransporting {
  struct Response: Sendable {
    let body: Data
    let headers: [String: String]
    let delayNanoseconds: UInt64

    init(body: Data, headers: [String: String], delayNanoseconds: UInt64 = 0) {
      self.body = body
      self.headers = headers
      self.delayNanoseconds = delayNanoseconds
    }
  }

  struct Metrics: Sendable {
    let requestCount: Int
    let requestsByCredential: [String: Int]
  }

  private let responses: [String: Response]
  private var counts: [String: Int] = [:]

  init(responses: [String: Response]) {
    self.responses = responses
  }

  func execute(_ request: TransportRequest) async throws -> TransportResponse {
    guard let credential = request.request.value(forHTTPHeaderField: "Authorization"),
      let response = responses[credential]
    else {
      throw URLError(.userAuthenticationRequired)
    }
    counts[credential, default: 0] += 1
    if response.delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: response.delayNanoseconds)
    }
    try Task.checkCancellation()
    let digest = SHA256.hash(data: response.body).map { String(format: "%02x", $0) }.joined()
    return TransportResponse(
      head: TransportResponseHead(
        statusCode: 200,
        headers: response.headers,
        url: request.request.url
      ),
      body: response.body,
      digestHex: digest,
      metrics: TransportMetrics(receivedBytes: response.body.count, spilledToDisk: false)
    )
  }

  func metrics() -> Metrics {
    Metrics(requestCount: counts.values.reduce(0, +), requestsByCredential: counts)
  }
}

extension Optional {
  fileprivate func flatMapAsync<T>(_ transform: (Wrapped) async -> T?) async -> T? {
    guard let self else { return nil }
    return await transform(self)
  }
}

private enum AuthGalleryEnvironment {
  static var platform: String {
    #if os(iOS) && targetEnvironment(simulator)
      return "iOS-Simulator"
    #elseif os(iOS)
      return "iOS-Device"
    #elseif os(macOS)
      return "macOS"
    #else
      return "Apple-Unknown"
    #endif
  }

  static var architecture: String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x86_64"
    #else
      return "unknown"
    #endif
  }
}
