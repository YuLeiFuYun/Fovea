import Foundation
import FoveaTesting
import XCTest

final class BenchmarkSmokeTests: XCTestCase {
    func testW1FeedScrollProducesReproducibleSmokeArtifact() async throws {
        let output = try benchmarkOutputDirectory()
        let artifact = try await BenchmarkSmokeHarness.runW1FeedScroll(outputDirectory: output)

        XCTAssertEqual(artifact.schemaVersion, 1)
        XCTAssertEqual(artifact.workloadID, "W1-Feed-Scroll-Smoke")
        XCTAssertEqual(artifact.datasetLogicalItemCount, 1_000)
        XCTAssertEqual(artifact.uniqueResourceCount, 64)
        XCTAssertGreaterThan(artifact.trace.count, 300)
        XCTAssertGreaterThan(artifact.summary.completedLoads, 0)
        XCTAssertGreaterThan(artifact.summary.cancelledLoads, 0)
        XCTAssertEqual(artifact.summary.failedLoads, 0)
        XCTAssertGreaterThan(artifact.summary.decodedMegapixels, 0)
        XCTAssertGreaterThan(artifact.summary.renderedMemoryHitCount, 0)
        XCTAssertGreaterThan(artifact.summary.singleFlightJoinCount, 0)
        XCTAssertEqual(artifact.summary.droppedDiagnosticEventCount, 0)
        XCTAssertLessThan(artifact.summary.networkRequestCount, artifact.summary.completedLoads)
        XCTAssertTrue(artifact.diagnostics.contains { $0.event.kind == .decodeCompleted })
        XCTAssertTrue(artifact.diagnostics.contains { $0.event.kind == .fetchCancelled })
    }

    func testW2DetailHeroUsesRealSourceDimensionsAndTargetDecode() async throws {
        let output = try benchmarkOutputDirectory()
        let artifact = try await BenchmarkSmokeHarness.runW2DetailHero(outputDirectory: output)

        XCTAssertEqual(artifact.workloadID, "W2-Detail-Hero-Smoke")
        XCTAssertEqual(
            artifact.sources.map { $0.pixelWidth * $0.pixelHeight },
            [12_000_000, 24_000_000, 48_000_000]
        )
        XCTAssertEqual(artifact.summary.attemptedLoads, 9)
        XCTAssertEqual(artifact.summary.completedLoads, 9)
        XCTAssertEqual(artifact.summary.cancelledLoads, 0)
        XCTAssertEqual(artifact.summary.failedLoads, 0)
        XCTAssertEqual(artifact.summary.networkRequestCount, 3)
        XCTAssertGreaterThanOrEqual(artifact.summary.originalEncodedHitCount, 6)
        XCTAssertEqual(artifact.summary.droppedDiagnosticEventCount, 0)
        XCTAssertGreaterThan(artifact.summary.sourceMegapixelsObserved, 200)

        for event in artifact.trace where event.category == "hero-load" {
            let target = try XCTUnwrap(event.target)
            let decodedPixels = try XCTUnwrap(event.decodedPixelCount)
            XCTAssertLessThanOrEqual(decodedPixels, target.width * target.height)
        }
    }

    func testW3AuthGalleryProducesZeroViolationArtifact() async throws {
        let output = try benchmarkOutputDirectory()
        let artifact = try await AuthGallerySmokeHarness.run(outputDirectory: output)

        XCTAssertEqual(artifact.workloadID, "W3-Auth-Gallery-Smoke")
        XCTAssertEqual(artifact.profileID, "W3-AUTH-GALLERY-SMOKE-V1")
        XCTAssertEqual(artifact.summary.totalViolationCount, 0)
        XCTAssertGreaterThanOrEqual(artifact.summary.networkRequestCount, 5)
        XCTAssertFalse(artifact.cases.isEmpty)
        XCTAssertTrue(artifact.cases.allSatisfy(\.passed))
        XCTAssertFalse(artifact.diagnostics.isEmpty)
    }

    private func benchmarkOutputDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let directory: URL
        #if os(macOS)
            if let configured = environment["FOVEA_BENCHMARK_OUTPUT_DIR"], !configured.isEmpty {
                directory = URL(fileURLWithPath: configured, isDirectory: true)
            } else {
                directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("FoveaBenchmarkArtifacts", isDirectory: true)
            }
        #else
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("FoveaBenchmarkArtifacts", isDirectory: true)
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
