import Foundation
import FoveaPersistence
import XCTest

final class T100DerivedRasterWriteBudgetStoreAdoptionTests: XCTestCase {
    func testReservationPersistsAndOnlyForwardWindowBoundaryResets_WRITE_BUDGET_PT_001()
        async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date(timeIntervalSinceReferenceDate: 10_000)
        let window: UInt64 = 10_000_000_000

        var budget: DerivedRasterWriteBudgetStore? = try await DerivedRasterWriteBudgetStore.open(
            root: root
        )
        let firstReservation =
            try await budget?.reserve(
                byteCount: 60,
                at: started,
                maximumBytes: 100,
                windowNanoseconds: window
            ) ?? false
        XCTAssertTrue(firstReservation)
        let overBudgetReservation =
            try await budget?.reserve(
                byteCount: 41,
                at: started.addingTimeInterval(1),
                maximumBytes: 100,
                windowNanoseconds: window
            ) ?? true
        XCTAssertFalse(overBudgetReservation)
        budget = nil

        let reopened = try await DerivedRasterWriteBudgetStore.open(root: root)
        let reservedAfterReopen = await reopened.reservedBytesForTesting()
        XCTAssertEqual(reservedAfterReopen, 60)
        let backwardClockReservation = try await reopened.reserve(
            byteCount: 41,
            at: started.addingTimeInterval(-100),
            maximumBytes: 100,
            windowNanoseconds: window
        )
        XCTAssertFalse(backwardClockReservation)
        let nextWindowReservation = try await reopened.reserve(
            byteCount: 41,
            at: started.addingTimeInterval(10),
            maximumBytes: 100,
            windowNanoseconds: window
        )
        XCTAssertTrue(nextWindowReservation)
        let reservedInNextWindow = await reopened.reservedBytesForTesting()
        XCTAssertEqual(reservedInNextWindow, 41)
    }

    func testInvalidInputsAndPerReservationBudgetFailClosed_WRITE_BUDGET_PT_002() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = try await DerivedRasterWriteBudgetStore.open(root: root)
        let now = Date(timeIntervalSinceReferenceDate: 20_000)

        let oversized = try await budget.reserve(
            byteCount: 101,
            at: now,
            maximumBytes: 100,
            windowNanoseconds: 1
        )
        XCTAssertFalse(oversized)
        for (bytes, maximum, window) in [
            (0, 100, UInt64(1)), (1, 0, UInt64(1)), (1, 100, UInt64(0)),
        ] {
            do {
                _ = try await budget.reserve(
                    byteCount: bytes,
                    at: now,
                    maximumBytes: maximum,
                    windowNanoseconds: window
                )
                XCTFail("invalid write-budget input must fail closed")
            } catch {
                // 预期 typed storage failure；失败时不得发布任何 reservation。
            }
        }
        let reservedAfterInvalidInputs = await budget.reservedBytesForTesting()
        XCTAssertEqual(reservedAfterInvalidInputs, 0)
    }

    func testCorruptPersistedStateIsRejectedOnReopen_WRITE_BUDGET_PT_003() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var budget: DerivedRasterWriteBudgetStore? = try await DerivedRasterWriteBudgetStore.open(
            root: root
        )
        let initialReservation =
            try await budget?.reserve(
                byteCount: 1,
                at: Date(timeIntervalSinceReferenceDate: 30_000),
                maximumBytes: 10,
                windowNanoseconds: 1_000_000_000
            ) ?? false
        XCTAssertTrue(initialReservation)
        budget = nil

        let stateURL = root.appendingPathComponent("derived-raster-write-budget.json")
        try Data("{}".utf8).write(to: stateURL, options: .atomic)
        do {
            _ = try await DerivedRasterWriteBudgetStore.open(root: root)
            XCTFail("corrupt persisted write-budget state must fail closed")
        } catch {
            // 预期路径：bootstrap 拒绝 schema/shape corruption。
        }
    }

    private func temporaryDirectory() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fovea-t100-write-budget-\(UUID().uuidString)", isDirectory: true)
    }
}
