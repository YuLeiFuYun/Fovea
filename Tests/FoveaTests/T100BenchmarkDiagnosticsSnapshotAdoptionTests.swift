import Foundation
@_spi(FoveaBenchmarking) import FoveaCore
import XCTest

final class T100BenchmarkDiagnosticsSnapshotAdoptionTests: XCTestCase {
    func testDerivedRasterCreationActivitySnapshotPreservesAllFields_BENCH_SNAPSHOT_PT_001() {
        let snapshot = FoveaDerivedRasterCreationActivitySnapshot(
            scheduledCount: 17,
            terminalCount: 11,
            activeCount: 6
        )

        XCTAssertEqual(snapshot.scheduledCount, 17)
        XCTAssertEqual(snapshot.terminalCount, 11)
        XCTAssertEqual(snapshot.activeCount, 6)
        XCTAssertEqual(
            snapshot,
            FoveaDerivedRasterCreationActivitySnapshot(
                scheduledCount: 17,
                terminalCount: 11,
                activeCount: 6
            )
        )
    }

    func testWarmMemoryTimingSamplePreservesFieldsAndCodableRoundTrips_BENCH_SNAPSHOT_PT_002()
        throws
    {
        let sample = FoveaWarmMemoryTimingSample(
            requestValidationNanoseconds: 1,
            namespaceGenerationNanoseconds: 2,
            aliasAuthorizationNanoseconds: 3,
            aliasIndexLookupNanoseconds: 4,
            representationAuthorizationNanoseconds: 5,
            varySelectionNanoseconds: 6,
            fixedIdentityAuthorizationNanoseconds: 7,
            renderedImageLookupNanoseconds: 8,
            freshnessClockNanoseconds: 9,
            freshnessEvaluationNanoseconds: 10,
            activeNamespaceFenceNanoseconds: 11,
            cancellationFenceNanoseconds: 12,
            coordinatorTotalNanoseconds: 13,
            totalNanoseconds: 14,
            pixelWidth: 15,
            pixelHeight: 16
        )

        XCTAssertEqual(sample.requestValidationNanoseconds, 1)
        XCTAssertEqual(sample.namespaceGenerationNanoseconds, 2)
        XCTAssertEqual(sample.aliasAuthorizationNanoseconds, 3)
        XCTAssertEqual(sample.aliasIndexLookupNanoseconds, 4)
        XCTAssertEqual(sample.representationAuthorizationNanoseconds, 5)
        XCTAssertEqual(sample.varySelectionNanoseconds, 6)
        XCTAssertEqual(sample.fixedIdentityAuthorizationNanoseconds, 7)
        XCTAssertEqual(sample.renderedImageLookupNanoseconds, 8)
        XCTAssertEqual(sample.freshnessClockNanoseconds, 9)
        XCTAssertEqual(sample.freshnessEvaluationNanoseconds, 10)
        XCTAssertEqual(sample.activeNamespaceFenceNanoseconds, 11)
        XCTAssertEqual(sample.cancellationFenceNanoseconds, 12)
        XCTAssertEqual(sample.coordinatorTotalNanoseconds, 13)
        XCTAssertEqual(sample.totalNanoseconds, 14)
        XCTAssertEqual(sample.pixelWidth, 15)
        XCTAssertEqual(sample.pixelHeight, 16)

        let encoded = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(FoveaWarmMemoryTimingSample.self, from: encoded)
        XCTAssertEqual(decoded, sample)
    }
}
