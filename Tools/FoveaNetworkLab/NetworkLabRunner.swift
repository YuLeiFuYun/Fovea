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

        let inputs = options.inputs.isEmpty ? defaultInputs : options.inputs
        var allowedOrigins = options.additionalAllowedOrigins
        for input in inputs {
            allowedOrigins.insert(try HTTPOrigin(url: input.url))
        }
        if options.inputs.isEmpty {
            allowedOrigins.formUnion(defaultRedirectOrigins)
        }
        let destinationPolicy = try HTTPDestinationPolicy.allowOnly(allowedOrigins)
        let privacySalt = Data(UUID().uuidString.utf8)

        let appID = "dev.fovea.network-lab"
        let namespace = SecurityNamespaceID.publicNamespace(appID: appID)
        let diagnostics = BoundedDiagnosticsSink(capacity: 4_096)
        let system = try await FoveaSystemPipeline.open(
            cacheRoot: cacheRoot,
            configuration: PipelineConfiguration(
                memoryCostLimit: 64 * 1024 * 1024,
                maximumTransportBytes: options.maximumTransportBytes,
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
                maximumConnectionsPerHost: 4,
                destinationPolicy: destinationPolicy
            ),
            encodedSoftTotalBytes: 128 * 1024 * 1024
        )

        var results: [NetworkCaseResult] = []
        results.reserveCapacity(inputs.count)
        for input in inputs {
            results.append(
                await runCase(
                    input: input,
                    appID: appID,
                    pipeline: system.pipeline,
                    diagnostics: diagnostics,
                    privacySalt: privacySalt
                )
            )
        }
        let snapshot = await diagnostics.snapshot()
        let counts = Dictionary(grouping: snapshot.map(\.event.kind.rawValue), by: { $0 })
            .mapValues(\.count)
        return NetworkLabReport(
            schemaVersion: 4,
            mode: "live-http-images",
            allSucceeded: results.allSatisfy { $0.expectedFailureReason != nil || $0.success },
            allExpectationsSatisfied: results.allSatisfy(\.expectationSatisfied),
            allInvariantsSatisfied: results.allSatisfy { result in
                if result.expectedFailureReason != nil { return result.expectationSatisfied }
                return result.success
                    && result.singleFlightObserved
                    && result.targetPixelInvariantSatisfied
                    && result.networkMetricsObserved
                    && result.networkTimingObserved
            },
            cacheWasTemporary: cacheWasTemporary,
            cases: results,
            diagnosticCounts: counts
        )
    }

    private static func runCase(
        input: NetworkLabInput,
        appID: String,
        pipeline: FoveaPipeline,
        diagnostics: BoundedDiagnosticsSink,
        privacySalt: Data
    ) async -> NetworkCaseResult {
        let url = input.url
        let originLabel = reportOriginLabel(for: input, salt: privacySalt)
        let before = await diagnostics.snapshot().count
        do {
            let request = try ImageRequest.publicImage(
                url: url,
                target: TargetPixels(width: 320, height: 240),
                appID: appID,
                priority: .userInitiated,
                networkPolicy: .interactive
            )
            if case .failure(let expectedReason) = input.expectation {
                return await runExpectedFailureCase(
                    request: request,
                    caseID: input.caseID,
                    originLabel: originLabel,
                    expectedReason: expectedReason,
                    beforeDiagnosticCount: before,
                    pipeline: pipeline,
                    diagnostics: diagnostics
                )
            }
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
                caseID: input.caseID,
                originLabel: originLabel,
                expectedFailureReason: nil,
                expectationSatisfied: true,
                success: true,
                firstPixelWidth: firstImage.pixelWidth,
                firstPixelHeight: firstImage.pixelHeight,
                concurrentElapsedNanoseconds: concurrentElapsed,
                repeatElapsedNanoseconds: repeatElapsed,
                concurrentFetchStarted: concurrentFetchStarted,
                concurrentFetchJoined: concurrentFetchJoined,
                repeatFetchStarted: repeatEvents.filter { $0.kind == .fetchStarted }.count,
                repeatMemoryHit: repeatEvents.filter { $0.kind == .renderedMemoryHit }.count,
                repeatOriginalEncodedHit: repeatEvents.filter { $0.kind == .originalEncodedHit }
                    .count,
                singleFlightObserved: concurrentFetchStarted == 1 && concurrentFetchJoined >= 1,
                targetPixelInvariantSatisfied: firstImage.pixelWidth <= 320
                    && firstImage.pixelHeight <= 240,
                networkMetricsObserved: completed?.transactionCount != nil,
                networkTimingObserved: Self.networkTimingObserved(completed),
                networkTaskDurationNanoseconds: completed?.durationNanoseconds,
                responseAnomalyObserved: allEvents.contains { $0.kind == .responseAnomaly },
                networkTransactionCount: completed?.transactionCount,
                networkProtocolNames: completed?.networkProtocolNames,
                reusedConnectionCount: completed?.reusedConnectionCount,
                proxyConnectionCount: completed?.proxyConnectionCount,
                cellularTransactionCount: completed?.cellularTransactionCount,
                expensiveTransactionCount: completed?.expensiveTransactionCount,
                constrainedTransactionCount: completed?.constrainedTransactionCount,
                redirectCount: completed?.redirectCount,
                domainLookupDurationNanoseconds: completed?.domainLookupDurationNanoseconds,
                connectionDurationNanoseconds: completed?.connectionDurationNanoseconds,
                secureConnectionDurationNanoseconds: completed?.secureConnectionDurationNanoseconds,
                requestDurationNanoseconds: completed?.requestDurationNanoseconds,
                timeToFirstByteNanoseconds: completed?.timeToFirstByteNanoseconds,
                responseDurationNanoseconds: completed?.responseDurationNanoseconds,
                failureCategory: nil,
                failureReason: nil
            )
        } catch let failure as PipelineFailure {
            return failureResult(
                caseID: input.caseID,
                originLabel: originLabel,
                expectedFailureReason: nil,
                failure: failure
            )
        } catch {
            return failureResult(
                caseID: input.caseID,
                originLabel: originLabel,
                expectedFailureReason: nil,
                category: "unclassified",
                reason: "unclassified-error"
            )
        }
    }

    private static func runExpectedFailureCase(
        request: ImageRequest,
        caseID: String,
        originLabel: String,
        expectedReason: String,
        beforeDiagnosticCount: Int,
        pipeline: FoveaPipeline,
        diagnostics: BoundedDiagnosticsSink
    ) async -> NetworkCaseResult {
        do {
            let image = try await pipeline.image(for: request)
            return NetworkCaseResult(
                caseID: caseID,
                originLabel: originLabel,
                expectedFailureReason: expectedReason,
                expectationSatisfied: false,
                success: true,
                firstPixelWidth: image.pixelWidth,
                firstPixelHeight: image.pixelHeight,
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
                networkTimingObserved: false,
                networkTaskDurationNanoseconds: nil,
                responseAnomalyObserved: false,
                networkTransactionCount: nil,
                networkProtocolNames: nil,
                reusedConnectionCount: nil,
                proxyConnectionCount: nil,
                cellularTransactionCount: nil,
                expensiveTransactionCount: nil,
                constrainedTransactionCount: nil,
                redirectCount: nil,
                domainLookupDurationNanoseconds: nil,
                connectionDurationNanoseconds: nil,
                secureConnectionDurationNanoseconds: nil,
                requestDurationNanoseconds: nil,
                timeToFirstByteNanoseconds: nil,
                responseDurationNanoseconds: nil,
                failureCategory: nil,
                failureReason: nil
            )
        } catch let failure as PipelineFailure {
            let events = Array((await diagnostics.snapshot()).dropFirst(beforeDiagnosticCount)).map(
                \.event)
            let completed = events.last { $0.kind == .fetchCompleted }
            return NetworkCaseResult(
                caseID: caseID,
                originLabel: originLabel,
                expectedFailureReason: expectedReason,
                expectationSatisfied: failure.reasonCode == expectedReason,
                success: false,
                firstPixelWidth: nil,
                firstPixelHeight: nil,
                concurrentElapsedNanoseconds: 0,
                repeatElapsedNanoseconds: nil,
                concurrentFetchStarted: events.filter { $0.kind == .fetchStarted }.count,
                concurrentFetchJoined: events.filter { $0.kind == .fetchJoined }.count,
                repeatFetchStarted: 0,
                repeatMemoryHit: 0,
                repeatOriginalEncodedHit: 0,
                singleFlightObserved: false,
                targetPixelInvariantSatisfied: false,
                networkMetricsObserved: completed?.transactionCount != nil,
                networkTimingObserved: Self.networkTimingObserved(completed),
                networkTaskDurationNanoseconds: completed?.durationNanoseconds,
                responseAnomalyObserved: events.contains { $0.kind == .responseAnomaly },
                networkTransactionCount: completed?.transactionCount,
                networkProtocolNames: completed?.networkProtocolNames,
                reusedConnectionCount: completed?.reusedConnectionCount,
                proxyConnectionCount: completed?.proxyConnectionCount,
                cellularTransactionCount: completed?.cellularTransactionCount,
                expensiveTransactionCount: completed?.expensiveTransactionCount,
                constrainedTransactionCount: completed?.constrainedTransactionCount,
                redirectCount: completed?.redirectCount,
                domainLookupDurationNanoseconds: completed?.domainLookupDurationNanoseconds,
                connectionDurationNanoseconds: completed?.connectionDurationNanoseconds,
                secureConnectionDurationNanoseconds: completed?.secureConnectionDurationNanoseconds,
                requestDurationNanoseconds: completed?.requestDurationNanoseconds,
                timeToFirstByteNanoseconds: completed?.timeToFirstByteNanoseconds,
                responseDurationNanoseconds: completed?.responseDurationNanoseconds,
                failureCategory: failure.category.rawValue,
                failureReason: failure.reasonCode
            )
        } catch {
            return failureResult(
                caseID: caseID,
                originLabel: originLabel,
                expectedFailureReason: expectedReason,
                category: "unclassified",
                reason: "unclassified-error"
            )
        }
    }

    private static func failureResult(
        caseID: String,
        originLabel: String,
        expectedFailureReason: String?,
        failure: PipelineFailure
    ) -> NetworkCaseResult {
        failureResult(
            caseID: caseID,
            originLabel: originLabel,
            expectedFailureReason: expectedFailureReason,
            category: failure.category.rawValue,
            reason: failure.reasonCode
        )
    }

    private static func failureResult(
        caseID: String,
        originLabel: String,
        expectedFailureReason: String?,
        category: String,
        reason: String
    ) -> NetworkCaseResult {
        NetworkCaseResult(
            caseID: caseID,
            originLabel: originLabel,
            expectedFailureReason: expectedFailureReason,
            expectationSatisfied: expectedFailureReason == reason,
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
            networkTimingObserved: false,
            networkTaskDurationNanoseconds: nil,
            responseAnomalyObserved: false,
            networkTransactionCount: nil,
            networkProtocolNames: nil,
            reusedConnectionCount: nil,
            proxyConnectionCount: nil,
            cellularTransactionCount: nil,
            expensiveTransactionCount: nil,
            constrainedTransactionCount: nil,
            redirectCount: nil,
            domainLookupDurationNanoseconds: nil,
            connectionDurationNanoseconds: nil,
            secureConnectionDurationNanoseconds: nil,
            requestDurationNanoseconds: nil,
            timeToFirstByteNanoseconds: nil,
            responseDurationNanoseconds: nil,
            failureCategory: category,
            failureReason: reason
        )
    }

    private static func networkTimingObserved(_ event: DiagnosticEvent?) -> Bool {
        guard let event else { return false }
        return (event.durationNanoseconds ?? 0) > 0
            || event.domainLookupDurationNanoseconds != nil
            || event.connectionDurationNanoseconds != nil
            || event.secureConnectionDurationNanoseconds != nil
            || event.requestDurationNanoseconds != nil
            || event.timeToFirstByteNanoseconds != nil
            || event.responseDurationNanoseconds != nil
    }

    private static func reportOriginLabel(
        for input: NetworkLabInput,
        salt: Data
    ) -> String {
        if input.originDisclosure == .publicHost {
            return input.url.host?.lowercased() ?? "unknown-public-origin"
        }
        guard let origin = try? HTTPOrigin(url: input.url) else { return "private-invalid" }
        var material = Data("fovea-network-lab-origin-v1\u{0}".utf8)
        material.append(salt)
        material.append(0)
        material.append(contentsOf: origin.description.utf8)
        let digest = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
        return "private-\(digest.prefix(16))"
    }

    private static let defaultInputs: [NetworkLabInput] = [
        NetworkLabInput(
            caseID: "public-httpbin",
            url: URL(string: "https://httpbin.org/image/png")!,
            expectation: .success,
            originDisclosure: .publicHost
        ),
        NetworkLabInput(
            caseID: "public-picsum",
            url: URL(string: "https://picsum.photos/seed/fovea-network-lab/800/600")!,
            expectation: .success,
            originDisclosure: .publicHost
        ),
        NetworkLabInput(
            caseID: "public-github-swift",
            url: URL(
                string:
                    "https://raw.githubusercontent.com/github/explore/main/topics/swift/swift.png")!,
            expectation: .success,
            originDisclosure: .publicHost
        ),
        NetworkLabInput(
            caseID: "public-gstatic",
            url: URL(string: "https://www.gstatic.com/webp/gallery/1.jpg")!,
            expectation: .success,
            originDisclosure: .publicHost
        ),
    ]

    private static var defaultRedirectOrigins: Set<HTTPOrigin> {
        guard let url = URL(string: "https://fastly.picsum.photos"),
            let origin = try? HTTPOrigin(url: url)
        else { return [] }
        return [origin]
    }
}
