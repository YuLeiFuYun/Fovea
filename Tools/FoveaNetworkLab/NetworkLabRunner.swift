import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaSystem
import ImageCraftCore

enum NetworkLabRunner {
  static func run(_ options: NetworkLabOptions) async throws -> NetworkLabReport {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("FoveaNetworkLab", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    let cacheRoot = options.cacheRoot ?? temporaryRoot
    let cacheWasTemporary = options.cacheRoot == nil
    let shouldCleanup = cacheWasTemporary && !options.keepCache
    defer {
      if shouldCleanup { try? FileManager.default.removeItem(at: cacheRoot) }
    }

    let appID = "dev.fovea.network-lab"
    let namespace = SecurityNamespaceID.publicNamespace(appID: appID)
    let diagnostics = BoundedDiagnosticsSink(capacity: 4_096)
    let system = try await FoveaSystemPipeline.open(
      cacheRoot: cacheRoot,
      configuration: PipelineConfiguration(
        memoryCostLimit: 64 * 1024 * 1024,
        maximumTransportBytes: 16 * 1024 * 1024,
        transportMemoryThreshold: 256 * 1024,
        maximumConcurrentFetches: 4,
        maximumConcurrentDecodes: 2,
        maximumDecodeWorkingSetBytes: 128 * 1024 * 1024,
        maximumQueuedFetches: 32,
        maximumQueuedDecodes: 32
      ),
      diagnostics: diagnostics,
      profileAccessPolicy: .allowOnly([
        ProfileAccessScope(namespace: namespace, authorizationContext: .public)
      ]),
      transportPolicy: URLSessionTransportPolicy(
        waitsForConnectivity: true,
        requestTimeoutSeconds: 20,
        resourceTimeoutSeconds: 60,
        maximumConnectionsPerHost: 4
      ),
      encodedSoftLimitBytes: 128 * 1024 * 1024
    )

    let urls = options.urls.isEmpty ? defaultURLs : options.urls
    var results: [NetworkCaseResult] = []
    results.reserveCapacity(urls.count)
    for url in urls {
      results.append(
        await runCase(
          url: url,
          appID: appID,
          pipeline: system.pipeline,
          diagnostics: diagnostics
        )
      )
    }
    let snapshot = await diagnostics.snapshot()
    let counts = Dictionary(grouping: snapshot.map(\.event.kind.rawValue), by: { $0 })
      .mapValues(\.count)
    return NetworkLabReport(
      schemaVersion: 1,
      mode: "live-public-https",
      allSucceeded: results.allSatisfy(\.success),
      allInvariantsSatisfied: results.allSatisfy {
        $0.success
          && $0.singleFlightObserved
          && $0.targetPixelInvariantSatisfied
          && $0.networkMetricsObserved
      },
      cacheWasTemporary: cacheWasTemporary,
      cases: results,
      diagnosticCounts: counts
    )
  }

  private static func runCase(
    url: URL,
    appID: String,
    pipeline: FoveaPipeline,
    diagnostics: BoundedDiagnosticsSink
  ) async -> NetworkCaseResult {
    let before = await diagnostics.snapshot().count
    do {
      let request = try ImageRequest.publicImage(
        url: url,
        target: TargetPixels(width: 320, height: 240),
        appID: appID,
        priority: .userInitiated,
        networkPolicy: .interactive
      )
      let concurrentStart = DispatchTime.now().uptimeNanoseconds
      async let first = pipeline.image(for: request)
      async let second = pipeline.image(for: request)
      let (firstImage, secondImage) = try await (first, second)
      let concurrentElapsed = DispatchTime.now().uptimeNanoseconds &- concurrentStart
      guard firstImage.pixelWidth == secondImage.pixelWidth,
        firstImage.pixelHeight == secondImage.pixelHeight
      else {
        throw NetworkLabError.inconsistentConcurrentResult
      }

      let afterConcurrent = await diagnostics.snapshot()
      let concurrentEvents = Array(afterConcurrent.dropFirst(before)).map(\.event)
      let repeatStart = DispatchTime.now().uptimeNanoseconds
      _ = try await pipeline.image(for: request)
      let repeatElapsed = DispatchTime.now().uptimeNanoseconds &- repeatStart
      let afterRepeat = await diagnostics.snapshot()
      let repeatEvents = Array(afterRepeat.dropFirst(afterConcurrent.count)).map(\.event)
      let allEvents = concurrentEvents + repeatEvents
      let completed = allEvents.last { $0.kind == .fetchCompleted }
      let concurrentFetchStarted = concurrentEvents.filter { $0.kind == .fetchStarted }.count
      let concurrentFetchJoined = concurrentEvents.filter { $0.kind == .fetchJoined }.count
      return NetworkCaseResult(
        urlHost: url.host ?? "unknown-host",
        urlDigest: urlDigest(url),
        success: true,
        firstPixelWidth: firstImage.pixelWidth,
        firstPixelHeight: firstImage.pixelHeight,
        concurrentElapsedNanoseconds: concurrentElapsed,
        repeatElapsedNanoseconds: repeatElapsed,
        concurrentFetchStarted: concurrentFetchStarted,
        concurrentFetchJoined: concurrentFetchJoined,
        repeatFetchStarted: repeatEvents.filter { $0.kind == .fetchStarted }.count,
        repeatMemoryHit: repeatEvents.filter { $0.kind == .renderedMemoryHit }.count,
        repeatOriginalEncodedHit: repeatEvents.filter { $0.kind == .originalEncodedHit }.count,
        singleFlightObserved: concurrentFetchStarted == 1 && concurrentFetchJoined >= 1,
        targetPixelInvariantSatisfied: firstImage.pixelWidth <= 320
          && firstImage.pixelHeight <= 240,
        networkMetricsObserved: completed?.transactionCount != nil,
        networkTransactionCount: completed?.transactionCount,
        networkProtocolNames: completed?.networkProtocolNames,
        reusedConnectionCount: completed?.reusedConnectionCount,
        proxyConnectionCount: completed?.proxyConnectionCount,
        cellularTransactionCount: completed?.cellularTransactionCount,
        expensiveTransactionCount: completed?.expensiveTransactionCount,
        constrainedTransactionCount: completed?.constrainedTransactionCount,
        failureCategory: nil,
        failureReason: nil
      )
    } catch let failure as PipelineFailure {
      return failureResult(url: url, failure: failure)
    } catch {
      return failureResult(
        url: url,
        category: "unclassified",
        reason: "unclassified-error"
      )
    }
  }

  private static func failureResult(
    url: URL,
    failure: PipelineFailure
  ) -> NetworkCaseResult {
    failureResult(url: url, category: failure.category.rawValue, reason: failure.reasonCode)
  }

  private static func failureResult(
    url: URL,
    category: String,
    reason: String
  ) -> NetworkCaseResult {
    NetworkCaseResult(
      urlHost: url.host ?? "unknown-host",
      urlDigest: urlDigest(url),
      success: false,
      firstPixelWidth: nil,
      firstPixelHeight: nil,
      concurrentElapsedNanoseconds: 0,
      repeatElapsedNanoseconds: nil,
      concurrentFetchStarted: 0,
      concurrentFetchJoined: 0,
      repeatFetchStarted: 0,
      repeatMemoryHit: 0,
      repeatOriginalEncodedHit: 0,
      singleFlightObserved: false,
      targetPixelInvariantSatisfied: false,
      networkMetricsObserved: false,
      networkTransactionCount: nil,
      networkProtocolNames: nil,
      reusedConnectionCount: nil,
      proxyConnectionCount: nil,
      cellularTransactionCount: nil,
      expensiveTransactionCount: nil,
      constrainedTransactionCount: nil,
      failureCategory: category,
      failureReason: reason
    )
  }

  private static func urlDigest(_ url: URL) -> String {
    SHA256.hash(data: Data(url.absoluteString.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static let defaultURLs: [URL] = [
    URL(string: "https://picsum.photos/seed/fovea-network-lab-a/800/600")!,
    URL(string: "https://picsum.photos/seed/fovea-network-lab-b/1200/800")!,
    URL(string: "https://picsum.photos/seed/fovea-network-lab-c/720/1080")!,
  ]
}
