import Dispatch
import Foundation
import ImageCraftCore

/// DecodeStage 使用的四层许可顺序：本地 working-set → 全局 working-set →
/// 本地 decode 并发 → 全局 decode 并发。该类型只拥有准入，不执行 codec 工作。
package struct FoveaDecodePermitController: Sendable {
    package let maximumWorkingSetBytes: Int

    private let decodePermits: AsyncPermitPool
    private let workingSetPermits: AsyncPermitPool
    private let globalDecodePermits: AsyncPermitPool?
    private let globalWorkingSetPermits: AsyncPermitPool?
    private let diagnostics: any DiagnosticsSink
    private let lifetimeRecorder: FoveaDecodePermitLifetimeRecorder?

    package init(
        diagnostics: any DiagnosticsSink,
        maximumConcurrentDecodes: Int,
        maximumDecodeWorkingSetBytes: Int,
        maximumQueuedDecodes: Int,
        decodePermits: AsyncPermitPool?,
        workingSetPermits: AsyncPermitPool?,
        globalDecodePermits: AsyncPermitPool?,
        globalWorkingSetPermits: AsyncPermitPool?,
        lifetimeRecorder: FoveaDecodePermitLifetimeRecorder? = nil
    ) {
        let normalizedWorkingSetBytes = max(1, maximumDecodeWorkingSetBytes)
        self.maximumWorkingSetBytes = normalizedWorkingSetBytes
        self.diagnostics = diagnostics
        self.decodePermits =
            decodePermits
            ?? AsyncPermitPool(
                limit: maximumConcurrentDecodes,
                queueLimit: maximumQueuedDecodes
            )
        self.workingSetPermits =
            workingSetPermits
            ?? AsyncPermitPool(
                limit: normalizedWorkingSetBytes,
                queueLimit: maximumQueuedDecodes
            )
        self.globalDecodePermits = globalDecodePermits
        self.globalWorkingSetPermits = globalWorkingSetPermits
        self.lifetimeRecorder = lifetimeRecorder
    }

    package func acquireDecodePermit(
        priorityControl: SharedTaskPriorityControl,
        workEstimate: Int
    ) async throws -> AsyncPermitPool.Permit {
        do {
            return try await decodePermits.acquire(
                priority: await priorityControl.currentPriority(),
                workEstimate: workEstimate,
                priorityUpdates: await priorityControl.updates()
            )
        } catch is CancellationError {
            throw PipelineFailure.cancelled(stage: .decode)
        } catch PermitPoolError.queueLimitExceeded {
            throw PipelineFailure.resourceLimit(
                stage: .decode,
                reasonCode: "decode-queue-limit-exceeded"
            )
        } catch {
            throw PipelineFailure.internalFailure(stage: .decode)
        }
    }

    /// Progressive codec work has no trustworthy per-session working-set estimate yet, so it
    /// cannot enter the weighted memory pools without fabricating safety data. It must still obey
    /// the same local/global decode CPU caps as complete-frame work. The permit is held only around
    /// one synchronous codec operation (`append`/`finish`), never across network waits.
    package func withProgressiveDecodePermits<Result>(
        priority: ImageRequestPriority,
        workEstimate: Int,
        operation: () async throws -> Result
    ) async throws -> Result {
        let normalizedEstimate = max(1, workEstimate)
        let decodePermit = try await acquireFixedPriorityDecodePermit(
            priority: priority,
            workEstimate: normalizedEstimate
        )
        return try await decodePermit.withPermit {
            if let globalDecodePermits {
                let globalPermit = try await acquireFixedPriorityGlobalDecodePermit(
                    from: globalDecodePermits,
                    priority: priority,
                    workEstimate: normalizedEstimate
                )
                return try await globalPermit.withPermit(operation)
            }
            return try await operation()
        }
    }

    package func withRasterPermits<Result>(
        bytes: Int,
        request: ImageRequest,
        keyDigest: String,
        priorityControl: SharedTaskPriorityControl,
        operation: () async throws -> Result
    ) async throws -> Result {
        if let lifetimeRecorder {
            return try await withMeasuredRasterPermits(
                bytes: bytes,
                request: request,
                keyDigest: keyDigest,
                priorityControl: priorityControl,
                lifetimeRecorder: lifetimeRecorder,
                operation: operation
            )
        }

        let workingSetPermit = try await acquireWorkingSetPermit(
            bytes: bytes,
            request: request,
            keyDigest: keyDigest,
            priorityControl: priorityControl
        )
        return try await workingSetPermit.withPermit {
            if let globalWorkingSetPermits {
                let globalPermit = try await acquireGlobalWorkingSetPermit(
                    from: globalWorkingSetPermits,
                    bytes: bytes,
                    priorityControl: priorityControl
                )
                return try await globalPermit.withPermit {
                    try await withDecodePermits(
                        workEstimate: bytes,
                        priorityControl: priorityControl,
                        operation: operation
                    )
                }
            }
            return try await withDecodePermits(
                workEstimate: bytes,
                priorityControl: priorityControl,
                operation: operation
            )
        }
    }

    /// H046 research path. The ordinary production path above remains free of clock reads and
    /// recorder actor hops because DecodeStage does not supply a lifetime recorder.
    private func withMeasuredRasterPermits<Result>(
        bytes: Int,
        request: ImageRequest,
        keyDigest: String,
        priorityControl: SharedTaskPriorityControl,
        lifetimeRecorder: FoveaDecodePermitLifetimeRecorder,
        operation: () async throws -> Result
    ) async throws -> Result {
        let localWorkingSetWaitStarted = DispatchTime.now().uptimeNanoseconds
        let workingSetPermit = try await acquireWorkingSetPermit(
            bytes: bytes,
            request: request,
            keyDigest: keyDigest,
            priorityControl: priorityControl
        )
        let localWorkingSetAcquired = DispatchTime.now().uptimeNanoseconds
        var globalWorkingSetAcquired: UInt64?
        var globalWorkingSetReleased: UInt64?
        var decodeTiming: MeasuredDecodePermitTiming?

        let result = try await workingSetPermit.withPermit {
            if let globalWorkingSetPermits {
                let globalPermit = try await acquireGlobalWorkingSetPermit(
                    from: globalWorkingSetPermits,
                    bytes: bytes,
                    priorityControl: priorityControl
                )
                globalWorkingSetAcquired = DispatchTime.now().uptimeNanoseconds
                let value = try await globalPermit.withPermit {
                    let measured = try await withMeasuredDecodePermits(
                        workEstimate: bytes,
                        priorityControl: priorityControl,
                        operation: operation
                    )
                    decodeTiming = measured.timing
                    return measured.value
                }
                globalWorkingSetReleased = DispatchTime.now().uptimeNanoseconds
                return value
            }

            let measured = try await withMeasuredDecodePermits(
                workEstimate: bytes,
                priorityControl: priorityControl,
                operation: operation
            )
            decodeTiming = measured.timing
            return measured.value
        }
        let localWorkingSetReleased = DispatchTime.now().uptimeNanoseconds

        if let decodeTiming {
            await recordMeasuredRasterPermitLifetime(
                bytes: bytes,
                localWorkingSetWaitStarted: localWorkingSetWaitStarted,
                localWorkingSetAcquired: localWorkingSetAcquired,
                globalWorkingSetAcquired: globalWorkingSetAcquired,
                globalWorkingSetReleased: globalWorkingSetReleased,
                localWorkingSetReleased: localWorkingSetReleased,
                decodeTiming: decodeTiming,
                lifetimeRecorder: lifetimeRecorder
            )
        }
        return result
    }

    private func recordMeasuredRasterPermitLifetime(
        bytes: Int,
        localWorkingSetWaitStarted: UInt64,
        localWorkingSetAcquired: UInt64,
        globalWorkingSetAcquired: UInt64?,
        globalWorkingSetReleased: UInt64?,
        localWorkingSetReleased: UInt64,
        decodeTiming: MeasuredDecodePermitTiming,
        lifetimeRecorder: FoveaDecodePermitLifetimeRecorder
    ) async {
        let workingSetReady = globalWorkingSetAcquired ?? localWorkingSetAcquired
        await lifetimeRecorder.record(
            FoveaDecodePermitLifetimeSample(
                bytes: bytes,
                localWorkingSetWaitNanoseconds: elapsed(
                    from: localWorkingSetWaitStarted,
                    to: localWorkingSetAcquired
                ),
                localWorkingSetHeldWaitingGlobalNanoseconds: globalWorkingSetAcquired.map {
                    elapsed(from: localWorkingSetAcquired, to: $0)
                } ?? 0,
                workingSetsHeldWaitingLocalDecodeNanoseconds: elapsed(
                    from: workingSetReady,
                    to: decodeTiming.localDecodeAcquired
                ),
                workingSetsAndLocalDecodeHeldWaitingGlobalDecodeNanoseconds:
                    decodeTiming.globalDecodeAcquired.map {
                        elapsed(from: decodeTiming.localDecodeAcquired, to: $0)
                    } ?? 0,
                codecOperationNanoseconds: elapsed(
                    from: decodeTiming.operationStarted,
                    to: decodeTiming.operationEnded
                ),
                localWorkingSetLeaseNanoseconds: elapsed(
                    from: localWorkingSetAcquired,
                    to: localWorkingSetReleased
                ),
                globalWorkingSetLeaseNanoseconds: leaseDuration(
                    acquired: globalWorkingSetAcquired,
                    released: globalWorkingSetReleased
                ),
                localDecodeLeaseNanoseconds: elapsed(
                    from: decodeTiming.localDecodeAcquired,
                    to: decodeTiming.localDecodeReleased
                ),
                globalDecodeLeaseNanoseconds: leaseDuration(
                    acquired: decodeTiming.globalDecodeAcquired,
                    released: decodeTiming.globalDecodeReleased
                )
            )
        )
    }

    private func withMeasuredDecodePermits<Result>(
        workEstimate: Int,
        priorityControl: SharedTaskPriorityControl,
        operation: () async throws -> Result
    ) async throws -> (value: Result, timing: MeasuredDecodePermitTiming) {
        let decodePermit = try await acquireDecodePermit(
            priorityControl: priorityControl,
            workEstimate: workEstimate
        )
        let localDecodeAcquired = DispatchTime.now().uptimeNanoseconds
        var globalDecodeAcquired: UInt64?
        var globalDecodeReleased: UInt64?
        var operationStarted = localDecodeAcquired
        var operationEnded = localDecodeAcquired

        let result = try await decodePermit.withPermit {
            if let globalDecodePermits {
                let globalPermit = try await acquireGlobalDecodePermit(
                    from: globalDecodePermits,
                    priorityControl: priorityControl,
                    workEstimate: workEstimate
                )
                globalDecodeAcquired = DispatchTime.now().uptimeNanoseconds
                let value = try await globalPermit.withPermit {
                    operationStarted = DispatchTime.now().uptimeNanoseconds
                    let value = try await operation()
                    operationEnded = DispatchTime.now().uptimeNanoseconds
                    return value
                }
                globalDecodeReleased = DispatchTime.now().uptimeNanoseconds
                return value
            }

            operationStarted = DispatchTime.now().uptimeNanoseconds
            let value = try await operation()
            operationEnded = DispatchTime.now().uptimeNanoseconds
            return value
        }
        let localDecodeReleased = DispatchTime.now().uptimeNanoseconds
        return (
            result,
            MeasuredDecodePermitTiming(
                localDecodeAcquired: localDecodeAcquired,
                globalDecodeAcquired: globalDecodeAcquired,
                operationStarted: operationStarted,
                operationEnded: operationEnded,
                globalDecodeReleased: globalDecodeReleased,
                localDecodeReleased: localDecodeReleased
            )
        )
    }

    private func elapsed(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }

    private func leaseDuration(acquired: UInt64?, released: UInt64?) -> UInt64 {
        guard let acquired, let released else { return 0 }
        return elapsed(from: acquired, to: released)
    }

    private func acquireFixedPriorityDecodePermit(
        priority: ImageRequestPriority,
        workEstimate: Int
    ) async throws -> AsyncPermitPool.Permit {
        do {
            return try await decodePermits.acquire(
                priority: priority,
                workEstimate: workEstimate
            )
        } catch is CancellationError {
            throw PipelineFailure.cancelled(stage: .decode)
        } catch PermitPoolError.queueLimitExceeded {
            throw PipelineFailure.resourceLimit(
                stage: .decode,
                reasonCode: "decode-queue-limit-exceeded"
            )
        } catch {
            throw PipelineFailure.internalFailure(stage: .decode)
        }
    }

    private func acquireFixedPriorityGlobalDecodePermit(
        from pool: AsyncPermitPool,
        priority: ImageRequestPriority,
        workEstimate: Int
    ) async throws -> AsyncPermitPool.Permit {
        do {
            return try await pool.acquire(
                priority: priority,
                workEstimate: workEstimate
            )
        } catch is CancellationError {
            throw PipelineFailure.cancelled(stage: .decode)
        } catch PermitPoolError.queueLimitExceeded {
            throw PipelineFailure.resourceLimit(
                stage: .decode,
                reasonCode: "global-decode-queue-limit-exceeded"
            )
        } catch {
            throw PipelineFailure.internalFailure(stage: .decode)
        }
    }

    private func acquireWorkingSetPermit(
        bytes: Int,
        request: ImageRequest,
        keyDigest: String,
        priorityControl: SharedTaskPriorityControl
    ) async throws -> AsyncPermitPool.Permit {
        do {
            let permit = try await workingSetPermits.acquire(
                units: bytes,
                priority: await priorityControl.currentPriority(),
                workEstimate: bytes,
                priorityUpdates: await priorityControl.updates()
            )
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .decodeWorkingSetReserved,
                    keyDigest: keyDigest,
                    byteCount: bytes,
                    requestedPriority: request.priority,
                    effectivePriority: await priorityControl.currentPriority()
                )
            )
            return permit
        } catch is CancellationError {
            throw PipelineFailure.cancelled(stage: .decode)
        } catch PermitPoolError.requestExceedsLimit {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .decodeAdmissionRejected,
                    keyDigest: keyDigest,
                    byteCount: bytes,
                    reason: "decode-working-set-limit-exceeded"
                )
            )
            throw PipelineFailure.resourceLimit(
                stage: .decode,
                reasonCode: "decode-working-set-limit-exceeded"
            )
        } catch PermitPoolError.queueLimitExceeded {
            throw PipelineFailure.resourceLimit(
                stage: .decode,
                reasonCode: "decode-working-set-queue-limit-exceeded"
            )
        } catch {
            throw PipelineFailure.internalFailure(stage: .decode)
        }
    }

    private func withDecodePermits<Result>(
        workEstimate: Int,
        priorityControl: SharedTaskPriorityControl,
        operation: () async throws -> Result
    ) async throws -> Result {
        let decodePermit = try await acquireDecodePermit(
            priorityControl: priorityControl,
            workEstimate: workEstimate
        )
        return try await decodePermit.withPermit {
            if let globalDecodePermits {
                let globalPermit = try await acquireGlobalDecodePermit(
                    from: globalDecodePermits,
                    priorityControl: priorityControl,
                    workEstimate: workEstimate
                )
                return try await globalPermit.withPermit(operation)
            }
            return try await operation()
        }
    }

    private func acquireGlobalWorkingSetPermit(
        from pool: AsyncPermitPool,
        bytes: Int,
        priorityControl: SharedTaskPriorityControl
    ) async throws -> AsyncPermitPool.Permit {
        do {
            return try await pool.acquire(
                units: bytes,
                priority: await priorityControl.currentPriority(),
                workEstimate: bytes,
                priorityUpdates: await priorityControl.updates()
            )
        } catch is CancellationError {
            throw PipelineFailure.cancelled(stage: .decode)
        } catch PermitPoolError.requestExceedsLimit {
            throw PipelineFailure.resourceLimit(
                stage: .decode,
                reasonCode: "global-decode-working-set-limit-exceeded"
            )
        } catch PermitPoolError.queueLimitExceeded {
            throw PipelineFailure.resourceLimit(
                stage: .decode,
                reasonCode: "global-decode-working-set-queue-limit-exceeded"
            )
        } catch {
            throw PipelineFailure.internalFailure(stage: .decode)
        }
    }

    private func acquireGlobalDecodePermit(
        from pool: AsyncPermitPool,
        priorityControl: SharedTaskPriorityControl,
        workEstimate: Int
    ) async throws -> AsyncPermitPool.Permit {
        do {
            return try await pool.acquire(
                priority: await priorityControl.currentPriority(),
                workEstimate: workEstimate,
                priorityUpdates: await priorityControl.updates()
            )
        } catch is CancellationError {
            throw PipelineFailure.cancelled(stage: .decode)
        } catch PermitPoolError.queueLimitExceeded {
            throw PipelineFailure.resourceLimit(
                stage: .decode,
                reasonCode: "global-decode-queue-limit-exceeded"
            )
        } catch {
            throw PipelineFailure.internalFailure(stage: .decode)
        }
    }
}

private struct MeasuredDecodePermitTiming {
    let localDecodeAcquired: UInt64
    let globalDecodeAcquired: UInt64?
    let operationStarted: UInt64
    let operationEnded: UInt64
    let globalDecodeReleased: UInt64?
    let localDecodeReleased: UInt64
}
