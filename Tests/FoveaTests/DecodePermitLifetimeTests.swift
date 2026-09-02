import Foundation
import FoveaCore
import ImageCraftCore
import XCTest

final class DecodePermitLifetimeTests: XCTestCase {
    func testNestedPermitRecorderMeasuresUpstreamHoldWhileWaiting_H046_PT_001() async throws {
        let localWorkingSet = AsyncPermitPool(limit: 10, queueLimit: 8)
        let globalWorkingSet = AsyncPermitPool(limit: 10, queueLimit: 8)
        let localDecode = AsyncPermitPool(limit: 1, queueLimit: 8)
        let globalDecode = AsyncPermitPool(limit: 1, queueLimit: 8)
        let recorder = FoveaDecodePermitLifetimeRecorder()
        let priorityControl = SharedTaskPriorityControl(priority: .normal)
        let request = try ImageRequest(
            url: XCTUnwrap(URL(string: "https://example.test/h046.png")),
            logicalSource: LogicalSourceID("asset:h046"),
            target: TargetPixels(width: 1, height: 1),
            colorPolicy: .convertToSRGB,
            namespace: SecurityNamespaceID("h046")
        )
        let controller = FoveaDecodePermitController(
            diagnostics: NullDiagnosticsSink(),
            maximumConcurrentDecodes: 1,
            maximumDecodeWorkingSetBytes: 10,
            maximumQueuedDecodes: 8,
            decodePermits: localDecode,
            workingSetPermits: localWorkingSet,
            globalDecodePermits: globalDecode,
            globalWorkingSetPermits: globalWorkingSet,
            lifetimeRecorder: recorder
        )

        let globalWorkingSetBlocker = try await globalWorkingSet.acquire(units: 10)
        let localDecodeBlocker = try await localDecode.acquire()
        let globalDecodeBlocker = try await globalDecode.acquire()

        let task = Task {
            try await controller.withRasterPermits(
                bytes: 10,
                request: request,
                keyDigest: request.fetchBaseKey.digestHex,
                priorityControl: priorityControl
            ) {
                try await Task.sleep(nanoseconds: 5_000_000)
                return 7
            }
        }

        try await waitUntil {
            let localUsed = await localWorkingSet.usedUnits
            let globalQueued = await globalWorkingSet.queuedCount()
            return localUsed == 10 && globalQueued == 1
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        await globalWorkingSetBlocker.release()

        try await waitUntil {
            let globalUsed = await globalWorkingSet.usedUnits
            let localDecodeQueued = await localDecode.queuedCount()
            return globalUsed == 10 && localDecodeQueued == 1
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        await localDecodeBlocker.release()

        try await waitUntil {
            let localDecodeUsed = await localDecode.usedUnits
            let globalDecodeQueued = await globalDecode.queuedCount()
            return localDecodeUsed == 1 && globalDecodeQueued == 1
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        await globalDecodeBlocker.release()

        let value = try await task.value
        XCTAssertEqual(value, 7)
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.completedOperationCount, 1)
        XCTAssertEqual(snapshot.admittedBytes, 10)

        let minimumForcedWait = UInt64(3_000_000)
        XCTAssertGreaterThan(
            snapshot.localWorkingSetHeldWaitingGlobalNanoseconds,
            minimumForcedWait
        )
        XCTAssertGreaterThan(
            snapshot.workingSetsHeldWaitingLocalDecodeNanoseconds,
            minimumForcedWait
        )
        XCTAssertGreaterThan(
            snapshot.workingSetsAndLocalDecodeHeldWaitingGlobalDecodeNanoseconds,
            minimumForcedWait
        )
        XCTAssertGreaterThan(snapshot.codecOperationNanoseconds, minimumForcedWait)

        XCTAssertGreaterThanOrEqual(
            snapshot.localWorkingSetLeaseNanoseconds,
            snapshot.localWorkingSetHeldWaitingGlobalNanoseconds
                + snapshot.workingSetsHeldWaitingLocalDecodeNanoseconds
                + snapshot.workingSetsAndLocalDecodeHeldWaitingGlobalDecodeNanoseconds
                + snapshot.codecOperationNanoseconds
        )
        XCTAssertGreaterThanOrEqual(
            snapshot.globalWorkingSetLeaseNanoseconds,
            snapshot.workingSetsHeldWaitingLocalDecodeNanoseconds
                + snapshot.workingSetsAndLocalDecodeHeldWaitingGlobalDecodeNanoseconds
                + snapshot.codecOperationNanoseconds
        )
        XCTAssertGreaterThanOrEqual(
            snapshot.localDecodeLeaseNanoseconds,
            snapshot.workingSetsAndLocalDecodeHeldWaitingGlobalDecodeNanoseconds
                + snapshot.codecOperationNanoseconds
        )
        XCTAssertGreaterThanOrEqual(
            snapshot.globalDecodeLeaseNanoseconds,
            snapshot.codecOperationNanoseconds
        )
        XCTAssertEqual(
            snapshot.localWorkingSetByteNanoseconds,
            snapshot.localWorkingSetLeaseNanoseconds * 10
        )
        XCTAssertEqual(
            snapshot.globalWorkingSetByteNanoseconds,
            snapshot.globalWorkingSetLeaseNanoseconds * 10
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping () async -> Bool
    ) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        while !(await condition()) {
            if DispatchTime.now().uptimeNanoseconds - started >= timeoutNanoseconds {
                XCTFail("timed out waiting for permit state")
                return
            }
            try await Task.sleep(nanoseconds: 100_000)
        }
    }
}
