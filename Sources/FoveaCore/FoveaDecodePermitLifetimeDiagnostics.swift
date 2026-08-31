import Foundation

/// H046 只读研究快照。生产 DecodeStage 默认不创建 recorder，因此不会读取时钟或
/// 产生诊断 actor hop。所有时间都是单调 uptime 纳秒；byte-nanoseconds 使用饱和算术。
package struct FoveaDecodePermitLifetimeSnapshot: Equatable, Sendable {
    package let completedOperationCount: UInt64
    package let admittedBytes: UInt64
    package let localWorkingSetWaitNanoseconds: UInt64
    package let localWorkingSetHeldWaitingGlobalNanoseconds: UInt64
    package let workingSetsHeldWaitingLocalDecodeNanoseconds: UInt64
    package let workingSetsAndLocalDecodeHeldWaitingGlobalDecodeNanoseconds: UInt64
    package let codecOperationNanoseconds: UInt64
    package let localWorkingSetLeaseNanoseconds: UInt64
    package let globalWorkingSetLeaseNanoseconds: UInt64
    package let localDecodeLeaseNanoseconds: UInt64
    package let globalDecodeLeaseNanoseconds: UInt64
    package let localWorkingSetByteNanoseconds: UInt64
    package let globalWorkingSetByteNanoseconds: UInt64
}

package struct FoveaDecodePermitLifetimeSample: Sendable {
    package let bytes: Int
    package let localWorkingSetWaitNanoseconds: UInt64
    package let localWorkingSetHeldWaitingGlobalNanoseconds: UInt64
    package let workingSetsHeldWaitingLocalDecodeNanoseconds: UInt64
    package let workingSetsAndLocalDecodeHeldWaitingGlobalDecodeNanoseconds: UInt64
    package let codecOperationNanoseconds: UInt64
    package let localWorkingSetLeaseNanoseconds: UInt64
    package let globalWorkingSetLeaseNanoseconds: UInt64
    package let localDecodeLeaseNanoseconds: UInt64
    package let globalDecodeLeaseNanoseconds: UInt64
}

/// Package-only recorder for H046 resource-hold experiments.
///
/// It intentionally records only successfully completed raster operations. Failed/cancelled
/// acquisition paths require a separate waste trace before they can support cancellation claims.
package actor FoveaDecodePermitLifetimeRecorder {
    private var completedOperationCount: UInt64 = 0
    private var admittedBytes: UInt64 = 0
    private var localWorkingSetWaitNanoseconds: UInt64 = 0
    private var localWorkingSetHeldWaitingGlobalNanoseconds: UInt64 = 0
    private var workingSetsHeldWaitingLocalDecodeNanoseconds: UInt64 = 0
    private var workingSetsAndLocalDecodeHeldWaitingGlobalDecodeNanoseconds: UInt64 = 0
    private var codecOperationNanoseconds: UInt64 = 0
    private var localWorkingSetLeaseNanoseconds: UInt64 = 0
    private var globalWorkingSetLeaseNanoseconds: UInt64 = 0
    private var localDecodeLeaseNanoseconds: UInt64 = 0
    private var globalDecodeLeaseNanoseconds: UInt64 = 0
    private var localWorkingSetByteNanoseconds: UInt64 = 0
    private var globalWorkingSetByteNanoseconds: UInt64 = 0

    package init() {}

    package func record(_ sample: FoveaDecodePermitLifetimeSample) {
        completedOperationCount = saturatedAdd(completedOperationCount, 1)
        let bytes = UInt64(max(0, sample.bytes))
        admittedBytes = saturatedAdd(admittedBytes, bytes)
        localWorkingSetWaitNanoseconds = saturatedAdd(
            localWorkingSetWaitNanoseconds,
            sample.localWorkingSetWaitNanoseconds
        )
        localWorkingSetHeldWaitingGlobalNanoseconds = saturatedAdd(
            localWorkingSetHeldWaitingGlobalNanoseconds,
            sample.localWorkingSetHeldWaitingGlobalNanoseconds
        )
        workingSetsHeldWaitingLocalDecodeNanoseconds = saturatedAdd(
            workingSetsHeldWaitingLocalDecodeNanoseconds,
            sample.workingSetsHeldWaitingLocalDecodeNanoseconds
        )
        workingSetsAndLocalDecodeHeldWaitingGlobalDecodeNanoseconds = saturatedAdd(
            workingSetsAndLocalDecodeHeldWaitingGlobalDecodeNanoseconds,
            sample.workingSetsAndLocalDecodeHeldWaitingGlobalDecodeNanoseconds
        )
        codecOperationNanoseconds = saturatedAdd(
            codecOperationNanoseconds,
            sample.codecOperationNanoseconds
        )
        localWorkingSetLeaseNanoseconds = saturatedAdd(
            localWorkingSetLeaseNanoseconds,
            sample.localWorkingSetLeaseNanoseconds
        )
        globalWorkingSetLeaseNanoseconds = saturatedAdd(
            globalWorkingSetLeaseNanoseconds,
            sample.globalWorkingSetLeaseNanoseconds
        )
        localDecodeLeaseNanoseconds = saturatedAdd(
            localDecodeLeaseNanoseconds,
            sample.localDecodeLeaseNanoseconds
        )
        globalDecodeLeaseNanoseconds = saturatedAdd(
            globalDecodeLeaseNanoseconds,
            sample.globalDecodeLeaseNanoseconds
        )
        localWorkingSetByteNanoseconds = saturatedAdd(
            localWorkingSetByteNanoseconds,
            saturatedMultiply(bytes, sample.localWorkingSetLeaseNanoseconds)
        )
        globalWorkingSetByteNanoseconds = saturatedAdd(
            globalWorkingSetByteNanoseconds,
            saturatedMultiply(bytes, sample.globalWorkingSetLeaseNanoseconds)
        )
    }

    package func snapshot() -> FoveaDecodePermitLifetimeSnapshot {
        FoveaDecodePermitLifetimeSnapshot(
            completedOperationCount: completedOperationCount,
            admittedBytes: admittedBytes,
            localWorkingSetWaitNanoseconds: localWorkingSetWaitNanoseconds,
            localWorkingSetHeldWaitingGlobalNanoseconds:
                localWorkingSetHeldWaitingGlobalNanoseconds,
            workingSetsHeldWaitingLocalDecodeNanoseconds:
                workingSetsHeldWaitingLocalDecodeNanoseconds,
            workingSetsAndLocalDecodeHeldWaitingGlobalDecodeNanoseconds:
                workingSetsAndLocalDecodeHeldWaitingGlobalDecodeNanoseconds,
            codecOperationNanoseconds: codecOperationNanoseconds,
            localWorkingSetLeaseNanoseconds: localWorkingSetLeaseNanoseconds,
            globalWorkingSetLeaseNanoseconds: globalWorkingSetLeaseNanoseconds,
            localDecodeLeaseNanoseconds: localDecodeLeaseNanoseconds,
            globalDecodeLeaseNanoseconds: globalDecodeLeaseNanoseconds,
            localWorkingSetByteNanoseconds: localWorkingSetByteNanoseconds,
            globalWorkingSetByteNanoseconds: globalWorkingSetByteNanoseconds
        )
    }

    private func saturatedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }

    private func saturatedMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }
}
