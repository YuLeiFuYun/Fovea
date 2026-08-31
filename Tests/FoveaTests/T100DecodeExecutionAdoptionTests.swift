import Foundation
@testable import FoveaCore
import ImageCraftCore
import XCTest

final class T100DecodeExecutionAdoptionTests: XCTestCase {
    func testProgressivePermitRoutingQueuesBehindGlobalWithoutBypassingLocalAndReleasesOnThrow_T100_AUTH_PT_006()
        async throws
    {
        let localDecode = AsyncPermitPool(limit: 2, queueLimit: 8)
        let globalDecode = AsyncPermitPool(limit: 1, queueLimit: 8)
        let controller = FoveaDecodePermitController(
            diagnostics: NullDiagnosticsSink(),
            maximumConcurrentDecodes: 2,
            maximumDecodeWorkingSetBytes: 1,
            maximumQueuedDecodes: 8,
            decodePermits: localDecode,
            workingSetPermits: nil,
            globalDecodePermits: globalDecode,
            globalWorkingSetPermits: nil
        )
        let globalBlocker = try await globalDecode.acquire()
        let probe = T100ProgressiveOperationProbe()

        let first = Task {
            try await controller.withProgressiveDecodePermits(
                priority: .normal,
                workEstimate: 1
            ) {
                await probe.recordEntry()
                await Task.yield()
                return 1
            }
        }
        let second = Task {
            try await controller.withProgressiveDecodePermits(
                priority: .normal,
                workEstimate: 1
            ) {
                await probe.recordEntry()
                await Task.yield()
                return 2
            }
        }

        try await waitUntil_T100_AUTH {
            let localUsedUnits = await localDecode.usedUnits
            let globalQueuedCount = await globalDecode.queuedCount()
            return localUsedUnits == 2 && globalQueuedCount == 2
        }
        let entryCountWhileGlobalBlocked = await probe.entryCount
        XCTAssertEqual(entryCountWhileGlobalBlocked, 0)
        await globalBlocker.release()

        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual([firstValue, secondValue].sorted(), [1, 2])
        let finalEntryCount = await probe.entryCount
        let finalLocalUsedUnits = await localDecode.usedUnits
        let finalGlobalUsedUnits = await globalDecode.usedUnits
        XCTAssertEqual(finalEntryCount, 2)
        XCTAssertEqual(finalLocalUsedUnits, 0)
        XCTAssertEqual(finalGlobalUsedUnits, 0)

        do {
            _ = try await controller.withProgressiveDecodePermits(
                priority: .normal,
                workEstimate: 1
            ) {
                throw T100DecodeExecutionTestError.expected
            } as Int
            XCTFail("throwing operation must propagate")
        } catch T100DecodeExecutionTestError.expected {
            // Expected.
        }
        let localUsedUnitsAfterThrow = await localDecode.usedUnits
        let globalUsedUnitsAfterThrow = await globalDecode.usedUnits
        XCTAssertEqual(localUsedUnitsAfterThrow, 0)
        XCTAssertEqual(globalUsedUnitsAfterThrow, 0)

        let cancellationBlocker = try await globalDecode.acquire()
        let cancellationProbe = T100ProgressiveOperationProbe()
        let cancelled = Task {
            try await controller.withProgressiveDecodePermits(
                priority: .normal,
                workEstimate: 1
            ) {
                await cancellationProbe.recordEntry()
                return 3
            }
        }
        try await waitUntil_T100_AUTH {
            let localUsedUnits = await localDecode.usedUnits
            let globalQueuedCount = await globalDecode.queuedCount()
            return localUsedUnits == 1 && globalQueuedCount == 1
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("cancellation while waiting for the global permit must fail")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .cancelled)
            XCTAssertEqual(failure.stage, .decode)
            XCTAssertEqual(failure.disposition, .cancelled)
        }
        let localUsedUnitsAfterCancel = await localDecode.usedUnits
        let globalQueuedCountAfterCancel = await globalDecode.queuedCount()
        let cancellationEntryCount = await cancellationProbe.entryCount
        XCTAssertEqual(localUsedUnitsAfterCancel, 0)
        XCTAssertEqual(globalQueuedCountAfterCancel, 0)
        XCTAssertEqual(cancellationEntryCount, 0)
        await cancellationBlocker.release()
        let globalUsedUnitsAfterCancellationBlocker = await globalDecode.usedUnits
        XCTAssertEqual(globalUsedUnitsAfterCancellationBlocker, 0)
    }

    func testMeasuredRasterPermitLifetimeRecordsOnlyCompletedOperations_T100_AUTH_PT_007()
        async throws
    {
        let recorder = FoveaDecodePermitLifetimeRecorder()
        let priorityControl = SharedTaskPriorityControl(priority: .normal)
        let request = try ImageRequest(
            url: XCTUnwrap(URL(string: "https://example.test/t100-decode-lifetime.png")),
            logicalSource: LogicalSourceID("asset:t100-decode-lifetime"),
            target: TargetPixels(width: 1, height: 1),
            colorPolicy: .convertToSRGB,
            namespace: SecurityNamespaceID("t100-decode-lifetime")
        )
        let controller = FoveaDecodePermitController(
            diagnostics: NullDiagnosticsSink(),
            maximumConcurrentDecodes: 1,
            maximumDecodeWorkingSetBytes: 16,
            maximumQueuedDecodes: 8,
            decodePermits: nil,
            workingSetPermits: nil,
            globalDecodePermits: nil,
            globalWorkingSetPermits: nil,
            lifetimeRecorder: recorder
        )

        let value = try await controller.withRasterPermits(
            bytes: 7,
            request: request,
            keyDigest: request.fetchBaseKey.digestHex,
            priorityControl: priorityControl
        ) {
            try await Task.sleep(nanoseconds: 1_000_000)
            return 42
        }
        XCTAssertEqual(value, 42)
        var snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.completedOperationCount, 1)
        XCTAssertEqual(snapshot.admittedBytes, 7)
        XCTAssertGreaterThan(snapshot.localWorkingSetLeaseNanoseconds, 0)
        XCTAssertGreaterThan(snapshot.localDecodeLeaseNanoseconds, 0)
        XCTAssertEqual(
            snapshot.localWorkingSetByteNanoseconds,
            snapshot.localWorkingSetLeaseNanoseconds * 7
        )

        do {
            _ = try await controller.withRasterPermits(
                bytes: 11,
                request: request,
                keyDigest: request.fetchBaseKey.digestHex,
                priorityControl: priorityControl
            ) {
                throw T100DecodeExecutionTestError.expected
            } as Int
            XCTFail("throwing operation must propagate")
        } catch T100DecodeExecutionTestError.expected {
            // Expected.
        }
        snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.completedOperationCount, 1)
        XCTAssertEqual(snapshot.admittedBytes, 7)
    }
}

private enum T100DecodeExecutionTestError: Error {
    case expected
}

private actor T100ProgressiveOperationProbe {
    private(set) var entryCount = 0

    func recordEntry() {
        entryCount += 1
    }
}

private func waitUntil_T100_AUTH(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    condition: @escaping () async -> Bool
) async throws {
    let started = DispatchTime.now().uptimeNanoseconds
    while !(await condition()) {
        if DispatchTime.now().uptimeNanoseconds &- started >= timeoutNanoseconds {
            XCTFail("timed out waiting for decode permit state")
            return
        }
        try await Task.sleep(nanoseconds: 100_000)
    }
}
