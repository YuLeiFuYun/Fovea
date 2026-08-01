import FoveaCore
import ImageCraftCore
import XCTest

@testable import FoveaWorkbench

final class FoveaWorkbenchLiveNetworkTests: XCTestCase {
    private static var liveNetworkEnabled: Bool {
        if ProcessInfo.processInfo.environment["RUN_LIVE_NETWORK"] == "1" {
            return true
        }
        let value = Bundle(for: FoveaWorkbenchLiveNetworkTests.self)
            .object(forInfoDictionaryKey: "FoveaRunLiveNetwork")
        return (value as? String) == "1" || (value as? NSNumber)?.boolValue == true
    }
    func testRealHTTPSMatrix_DEMO_PT_001() async throws {
        guard Self.liveNetworkEnabled else {
            throw XCTSkip(
                "Set RUN_LIVE_NETWORK=1 or FOVEA_RUN_LIVE_NETWORK=1 to run external HTTPS tests.")
        }
        var configuration = WorkbenchConfiguration.defaults
        configuration.externalNetworkingEnabled = true
        configuration.waitsForConnectivity = false

        let diagnostics = WorkbenchDiagnosticsSink(capacity: 4_096)
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FoveaWorkbenchLiveTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let runtime = try await WorkbenchPipelineFactory.open(
            cacheRoot: cacheRoot,
            configuration: configuration,
            diagnostics: diagnostics
        )
        let scenarioIDs = [
            "live-httpbin-png",
            "live-picsum-redirect",
            "live-github-swift-png",
            "live-gstatic-jpeg",
        ]
        var attemptedHosts: Set<String> = []
        var successfulHosts: Set<String> = []
        var environmentUnavailable: [String] = []

        for identifier in scenarioIDs {
            let scenario = try XCTUnwrap(
                WorkbenchScenarioCatalog.all.first { $0.id == identifier },
                "Missing live scenario: \(identifier)"
            )
            let request = try WorkbenchRequestFactory.makeRequest(
                scenario: scenario,
                target: TargetPixels(width: 320, height: 240),
                configuration: configuration
            )
            let host = try XCTUnwrap(request.url.host)
            attemptedHosts.insert(host)
            let beforeSequence = await diagnostics.snapshot().last?.sequence ?? 0

            do {
                async let first = runtime.pipeline.image(for: request)
                async let second = runtime.pipeline.image(for: request)
                let (firstImage, secondImage) = try await (first, second)

                XCTAssertEqual(firstImage.pixelWidth, secondImage.pixelWidth, identifier)
                XCTAssertEqual(firstImage.pixelHeight, secondImage.pixelHeight, identifier)
                XCTAssertLessThanOrEqual(firstImage.pixelWidth, 320, identifier)
                XCTAssertLessThanOrEqual(firstImage.pixelHeight, 240, identifier)
                successfulHosts.insert(host)

                let events = await waitForTerminalEvents(
                    in: diagnostics,
                    after: beforeSequence
                )
                assertSingleFlightRetryEvidence(events, identifier: identifier)
                let completed = try XCTUnwrap(
                    events.last { $0.kind == .fetchCompleted },
                    "Missing fetchCompleted diagnostics for \(identifier)"
                )
                XCTAssertGreaterThanOrEqual(completed.transactionCount ?? 0, 1, identifier)
                XCTAssertFalse(completed.networkProtocolNames?.isEmpty ?? true, identifier)
                if identifier == "live-picsum-redirect" {
                    XCTAssertGreaterThanOrEqual(completed.transactionCount ?? 0, 2)
                }

                _ = try await runtime.pipeline.image(for: request)
            } catch let failure as PipelineFailure where isEnvironmentUnavailable(failure) {
                environmentUnavailable.append(
                    "\(identifier) host=\(host) category=\(failure.category.rawValue) "
                        + "status=\(failure.statusCode.map(String.init) ?? "none") "
                        + "reason=\(failure.reasonCode)"
                )
            }
        }

        XCTAssertEqual(attemptedHosts.count, scenarioIDs.count)
        XCTAssertGreaterThanOrEqual(
            successfulHosts.count,
            3,
            "Live matrix produced insufficient independent-origin evidence: "
                + environmentUnavailable.joined(separator: "; ")
        )

        let summary = [
            "attempted=\(attemptedHosts.sorted().joined(separator: ","))",
            "successful=\(successfulHosts.sorted().joined(separator: ","))",
            "environmentUnavailable=\(environmentUnavailable.joined(separator: " | "))",
        ].joined(separator: "\n")
        await MainActor.run {
            XCTContext.runActivity(named: "Live matrix environment summary") { activity in
                let attachment = XCTAttachment(string: summary)
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
        }
    }

    private func assertSingleFlightRetryEvidence(
        _ events: [DiagnosticEvent],
        identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let starts = events.filter { $0.kind == .fetchStarted }
        let retries = events.filter { $0.kind == .fetchRetryScheduled }
        let expectedAttempts = Array(1...starts.count)

        XCTAssertFalse(starts.isEmpty, identifier, file: file, line: line)
        XCTAssertLessThanOrEqual(
            starts.count,
            TransportRetryPolicy().maximumAttempts,
            identifier,
            file: file,
            line: line
        )
        XCTAssertEqual(
            starts.compactMap(\.attempt),
            expectedAttempts,
            identifier,
            file: file,
            line: line
        )
        XCTAssertEqual(
            retries.count,
            max(0, starts.count - 1),
            identifier,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            events.filter { $0.kind == .fetchJoined }.count,
            1,
            identifier,
            file: file,
            line: line
        )
    }

    private func isEnvironmentUnavailable(_ failure: PipelineFailure) -> Bool {
        if failure.category == .transport, failure.disposition == .retryable {
            return true
        }
        guard failure.category == .http, let statusCode = failure.statusCode else {
            return false
        }
        return [408, 425, 429, 500, 502, 503, 504].contains(statusCode)
    }

    func testLicensedRemoteGalleryUsesOfficialPipeline() async throws {
        guard Self.liveNetworkEnabled else {
            throw XCTSkip(
                "Set RUN_LIVE_NETWORK=1 or FOVEA_RUN_LIVE_NETWORK=1 to run external HTTPS tests.")
        }
        var configuration = WorkbenchConfiguration.defaults
        configuration.waitsForConnectivity = false

        let diagnostics = WorkbenchDiagnosticsSink(capacity: 4_096)
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FoveaWorkbenchRemoteGallery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let runtime = try await WorkbenchPipelineFactory.open(
            cacheRoot: cacheRoot,
            configuration: configuration,
            diagnostics: diagnostics
        )

        for asset in WorkbenchRemoteAssetCatalog.remoteAssets.prefix(4) {
            let request = try WorkbenchRequestFactory.makeRemoteAssetRequest(
                asset: asset,
                target: TargetPixels(width: 640, height: 420),
                configuration: configuration
            )
            XCTAssertEqual(request.url.host, "commons.wikimedia.org", asset.id)

            let beforeSequence = await diagnostics.snapshot().last?.sequence ?? 0
            let image = try await runtime.pipeline.image(for: request)
            XCTAssertGreaterThan(image.pixelWidth, 0, asset.id)
            XCTAssertGreaterThan(image.pixelHeight, 0, asset.id)
            XCTAssertLessThanOrEqual(image.pixelWidth, 640, asset.id)
            XCTAssertLessThanOrEqual(image.pixelHeight, 420, asset.id)

            let events = await waitForTerminalEvents(in: diagnostics, after: beforeSequence)
            let completed = try XCTUnwrap(
                events.last { $0.kind == .fetchCompleted },
                "Missing fetchCompleted diagnostics for \(asset.id)"
            )
            XCTAssertGreaterThanOrEqual(completed.transactionCount ?? 0, 2, asset.id)
            XCTAssertFalse(completed.networkProtocolNames?.isEmpty ?? true, asset.id)

            let cachedImage = try await runtime.pipeline.image(for: request)
            XCTAssertEqual(cachedImage.pixelWidth, image.pixelWidth, asset.id)
            XCTAssertEqual(cachedImage.pixelHeight, image.pixelHeight, asset.id)
        }
    }

    private func waitForTerminalEvents(
        in diagnostics: WorkbenchDiagnosticsSink,
        after sequence: UInt64
    ) async -> [DiagnosticEvent] {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            let events = await diagnostics.snapshot()
                .filter { $0.sequence > sequence }
                .map(\.event)
            if events.contains(where: { $0.kind == .fetchCompleted || $0.kind == .fetchFailed }) {
                return events
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return await diagnostics.snapshot()
            .filter { $0.sequence > sequence }
            .map(\.event)
    }
}
