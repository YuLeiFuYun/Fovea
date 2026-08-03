import Foundation
import FoveaHTTP

package final class FetchCancellationHandoffLease: @unchecked Sendable {
    private let lock = NSLock()
    private var graceNanosecondsStorage: UInt64 = 0

    package init() {}

    package func activate(graceNanoseconds: UInt64) {
        lock.lock()
        graceNanosecondsStorage = max(graceNanosecondsStorage, graceNanoseconds)
        lock.unlock()
    }

    package func graceNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return graceNanosecondsStorage
    }
}

package enum FetchCancellationHandoffContext {
    @TaskLocal package static var lease: FetchCancellationHandoffLease?
}

/// 负责 fetch 阶段的请求编排、共享执行和单次网络尝试。
/// 编排获取阶段的共享执行、有限重试、优先级传播和命名空间屏障。
/// 网络时间从真正获得许可后开始计量，排队时间不会污染 HTTP 年龄计算。
final class FetchStage: Sendable {
    private let configuration: PipelineConfiguration
    private let transport: any HTTPTransporting
    private let clock: any WallClock
    private let namespaceRegistry: NamespaceRegistry
    private let permits: AsyncPermitPool
    private let diagnostics: FetchStageDiagnostics
    private let retryController: FetchRetryController
    private let registry = SharedTaskRegistry<ScopedFetchExecutionKey, TimedTransportResponse>()

    init(
        configuration: PipelineConfiguration,
        transport: any HTTPTransporting,
        diagnostics: any DiagnosticsSink,
        clock: any WallClock,
        namespaceRegistry: NamespaceRegistry,
        retrySleeper: any RetrySleeping,
        retryJitter: any RetryJittering
    ) {
        let fetchDiagnostics = FetchStageDiagnostics(sink: diagnostics)
        self.configuration = configuration
        self.transport = transport
        self.clock = clock
        self.namespaceRegistry = namespaceRegistry
        self.diagnostics = fetchDiagnostics
        self.retryController = FetchRetryController(
            policy: configuration.transportRetryPolicy,
            sleeper: retrySleeper,
            jitter: retryJitter,
            diagnostics: fetchDiagnostics
        )
        self.permits = AsyncPermitPool(
            limit: configuration.maximumConcurrentFetches,
            queueLimit: configuration.maximumQueuedFetches
        )
    }

    func cancelAll(namespace: SecurityNamespaceID) async {
        _ = await registry.cancelAll { $0.namespace == namespace }
    }

    func invalidateCompletionHandoff(
        for request: ImageRequest,
        conditionalRecord: RepresentationRecord?
    ) async {
        guard transport.reusePolicy.allowsCrossRequestReuse else { return }
        let selectedVariant = conditionalRecord.map { request.fetchVariantKey(for: $0.vary) }
        let executionKey = request.fetchExecutionKey(
            selectedVariant: selectedVariant,
            revalidationFingerprint: FetchRequestPreparation.revalidationFingerprint(
                for: conditionalRecord
            ),
            transportPolicyFingerprint:
                "\(configuration.transportPolicyFingerprint):\(transport.reusePolicy.executionFingerprint)"
        )
        _ = await registry.removeCompleted(
            for: ScopedFetchExecutionKey(
                namespace: request.namespace,
                execution: executionKey
            )
        )
    }

    /// 测试缝：查询无条件 fetch 执行身份的当前订阅者数量。
    /// 只读取 registry 控制面，不创建任务、不改变优先级或取消租约。
    package func subscriberCountForTesting(request: ImageRequest) async -> Int {
        let executionKey = request.fetchExecutionKey(
            selectedVariant: nil,
            revalidationFingerprint: FetchRequestPreparation.revalidationFingerprint(for: nil),
            transportPolicyFingerprint:
                "\(configuration.transportPolicyFingerprint):\(transport.reusePolicy.executionFingerprint)"
        )
        return await registry.subscriberCount(
            for: ScopedFetchExecutionKey(
                namespace: request.namespace,
                execution: executionKey
            )
        )
    }

    @concurrent
    func response(
        for request: ImageRequest,
        conditionalRecord: RepresentationRecord?,
        generation: NamespaceGeneration,
        memoryThresholdOverride: Int? = nil,
        bodyDelivery: TransportBodyDelivery = .materialized
    ) async throws -> TimedTransportResponse {
        let authorizedRequest = FetchRequestPreparation.authorizedRequest(
            for: request,
            conditionalRecord: conditionalRecord
        )
        let selectedVariant = conditionalRecord.map { request.fetchVariantKey(for: $0.vary) }
        let executionKey = request.fetchExecutionKey(
            selectedVariant: selectedVariant,
            revalidationFingerprint: FetchRequestPreparation.revalidationFingerprint(
                for: conditionalRecord
            ),
            transportPolicyFingerprint:
                "\(configuration.transportPolicyFingerprint):\(transport.reusePolicy.executionFingerprint)"
        )

        if !transport.reusePolicy.allowsCrossRequestReuse {
            return try await executeTaskLocal(
                authorizedRequest: authorizedRequest,
                request: request,
                generation: generation,
                executionKey: executionKey,
                memoryThresholdOverride: memoryThresholdOverride,
                bodyDelivery: bodyDelivery
            )
        }

        return try await executeShared(
            authorizedRequest: authorizedRequest,
            request: request,
            generation: generation,
            executionKey: executionKey,
            memoryThresholdOverride: memoryThresholdOverride,
            bodyDelivery: bodyDelivery
        )
    }

    private func executeTaskLocal(
        authorizedRequest: URLRequest,
        request: ImageRequest,
        generation: NamespaceGeneration,
        executionKey: FetchExecutionKey,
        memoryThresholdOverride: Int?,
        bodyDelivery: TransportBodyDelivery
    ) async throws -> TimedTransportResponse {
        await diagnostics.recordQueued(
            executionKey: executionKey,
            requestedPriority: request.priority,
            reason: "transport-task-local"
        )
        let priorityControl = SharedTaskPriorityControl(priority: request.priority)

        do {
            let result = try await executeWithRetry(
                authorizedRequest: authorizedRequest,
                request: request,
                generation: generation,
                executionKey: executionKey,
                priorityControl: priorityControl,
                memoryThresholdOverride: memoryThresholdOverride,
                bodyDelivery: bodyDelivery
            )
            await priorityControl.finish()
            return result
        } catch {
            await priorityControl.finish()
            throw await normalizeSubscriptionFailure(
                error,
                request: request,
                generation: generation
            )
        }
    }

    private func executeShared(
        authorizedRequest: URLRequest,
        request: ImageRequest,
        generation: NamespaceGeneration,
        executionKey: FetchExecutionKey,
        memoryThresholdOverride: Int?,
        bodyDelivery: TransportBodyDelivery
    ) async throws -> TimedTransportResponse {
        let scopedKey = ScopedFetchExecutionKey(
            namespace: request.namespace,
            execution: executionKey
        )
        let subscription = await registry.subscribe(
            key: scopedKey,
            priority: request.priority,
            admission: SharedTaskAdmissionContext.current ?? .now()
        ) { [self] priorityControl in
            await diagnostics.recordQueued(
                executionKey: executionKey,
                requestedPriority: request.priority
            )
            return try await executeWithRetry(
                authorizedRequest: authorizedRequest,
                request: request,
                generation: generation,
                executionKey: executionKey,
                priorityControl: priorityControl,
                memoryThresholdOverride: memoryThresholdOverride,
                bodyDelivery: bodyDelivery
            )
        }

        if subscription.wasJoined {
            await diagnostics.recordJoined(
                executionKey: executionKey,
                requestedPriority: request.priority,
                effectivePriority: await subscription.priorityControl.currentPriority()
            )
        }

        let handoffLease = FetchCancellationHandoffContext.lease
        return try await withTaskCancellationHandler {
            do {
                let result = try await subscription.value()
                try Task.checkCancellation()
                let completionHandoff = FetchCompletionHandoffPolicy.retentionNanoseconds(
                    head: result.head,
                    requestTime: result.requestTime,
                    responseTime: result.responseTime,
                    request: request
                )
                if completionHandoff > 0 {
                    await subscription.detach(handoffGraceNanoseconds: completionHandoff)
                } else {
                    await subscription.cancel()
                }
                return result
            } catch {
                if Self.isCancellation(error) || Task.isCancelled {
                    let handoffGraceNanoseconds = handoffLease?.graceNanoseconds() ?? 0
                    if handoffGraceNanoseconds > 0 {
                        await subscription.detach(
                            handoffGraceNanoseconds: handoffGraceNanoseconds
                        )
                    } else {
                        await subscription.cancel(
                            retainingCancelledTaskForNanoseconds: CancellationCohortPolicy
                                .retentionNanoseconds
                        )
                    }
                } else {
                    await subscription.cancel()
                }
                throw await normalizeSubscriptionFailure(
                    error,
                    request: request,
                    generation: generation
                )
            }
        } onCancel: {
            Task {
                let handoffGraceNanoseconds = handoffLease?.graceNanoseconds() ?? 0
                if handoffGraceNanoseconds > 0 {
                    await subscription.detach(
                        handoffGraceNanoseconds: handoffGraceNanoseconds
                    )
                } else {
                    await subscription.cancel(
                        retainingCancelledTaskForNanoseconds: CancellationCohortPolicy
                            .retentionNanoseconds
                    )
                }
            }
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        guard let failure = error as? PipelineFailure else { return false }
        return failure.disposition == .cancelled
    }

    private func executeWithRetry(
        authorizedRequest: URLRequest,
        request: ImageRequest,
        generation: NamespaceGeneration,
        executionKey: FetchExecutionKey,
        priorityControl: SharedTaskPriorityControl,
        memoryThresholdOverride: Int?,
        bodyDelivery: TransportBodyDelivery
    ) async throws -> TimedTransportResponse {
        var state = FetchRetryState()

        while true {
            try await requireAttemptAllowed(
                request: request,
                generation: generation,
                executionKey: executionKey,
                attempt: state.attempt
            )

            let response: TimedTransportResponse
            do {
                response = try await executeAttempt(
                    authorizedRequest: authorizedRequest,
                    request: request,
                    executionKey: executionKey,
                    attempt: state.attempt,
                    priorityControl: priorityControl,
                    memoryThresholdOverride: memoryThresholdOverride,
                    bodyDelivery: bodyDelivery
                )
            } catch {
                let failure = retryController.normalizedFailure(error)
                guard
                    let plan = await retryController.failurePlan(
                        failure: failure,
                        state: state
                    )
                else {
                    await diagnostics.recordTerminalFailure(
                        failure,
                        executionKey: executionKey,
                        attempt: state.attempt
                    )
                    throw failure
                }
                try await retryController.schedule(
                    plan,
                    executionKey: executionKey,
                    attempt: state.attempt
                )
                state.totalDelay += plan.delay
                state.attempt += 1
                continue
            }

            guard
                let plan = await retryController.responsePlan(
                    response: response,
                    state: state
                )
            else {
                await diagnostics.recordCompleted(
                    response,
                    executionKey: executionKey,
                    attempt: state.attempt
                )
                return response
            }

            try await retryController.schedule(
                plan,
                executionKey: executionKey,
                attempt: state.attempt
            )
            state.additionalResponseBytes =
                plan.additionalResponseBytes ?? state.additionalResponseBytes
            state.totalDelay += plan.delay
            state.attempt += 1
        }
    }

    private func requireAttemptAllowed(
        request: ImageRequest,
        generation: NamespaceGeneration,
        executionKey: FetchExecutionKey,
        attempt: Int
    ) async throws {
        do {
            try Task.checkCancellation()
        } catch {
            let failure = PipelineFailure.cancelled(stage: .transport)
            await diagnostics.recordTerminalFailure(
                failure,
                executionKey: executionKey,
                attempt: attempt
            )
            throw failure
        }
        guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
            let failure = PipelineFailure.namespaceRevoked
            await diagnostics.recordTerminalFailure(
                failure,
                executionKey: executionKey,
                attempt: attempt
            )
            throw failure
        }
    }

    private func executeAttempt(
        authorizedRequest: URLRequest,
        request: ImageRequest,
        executionKey: FetchExecutionKey,
        attempt: Int,
        priorityControl: SharedTaskPriorityControl,
        memoryThresholdOverride: Int?,
        bodyDelivery: TransportBodyDelivery
    ) async throws -> TimedTransportResponse {
        let permit = try await acquirePermit(priorityControl: priorityControl)
        let effectivePriority = await priorityControl.currentPriority()
        await diagnostics.recordStarted(
            executionKey: executionKey,
            attempt: attempt,
            requestedPriority: request.priority,
            effectivePriority: effectivePriority
        )

        let requestTime = await clock.now()
        let transportPriority = TransportPriorityController(
            priority: effectivePriority.transportPriority
        )
        let priorityPropagation = Task { @concurrent in
            let updates = await priorityControl.updates()
            for await priority in updates {
                await transportPriority.update(priority.transportPriority)
            }
        }

        return try await permit.withPermit {
            defer { priorityPropagation.cancel() }
            do {
                let transportResponse = try await transport.execute(
                    try TransportRequest(
                        request: authorizedRequest,
                        maximumBytes: configuration.maximumTransportBytes,
                        memoryThreshold: min(
                            configuration.maximumTransportBytes,
                            max(
                                0, memoryThresholdOverride ?? configuration.transportMemoryThreshold
                            )
                        ),
                        credentialHeaderNames: request.credentialHeaderNames,
                        priority: effectivePriority.transportPriority,
                        bodyDelivery: bodyDelivery,
                        priorityController: transportPriority
                    )
                )
                guard transportResponse.bodyByteCount <= configuration.maximumTransportBytes else {
                    throw TransportError.bodyTooLarge
                }
                let responseTime = await clock.now()
                await transportPriority.finish()
                return TimedTransportResponse(
                    requestTime: requestTime,
                    responseTime: responseTime,
                    transport: transportResponse
                )
            } catch {
                await transportPriority.finish()
                throw error
            }
        }
    }

    private func acquirePermit(
        priorityControl: SharedTaskPriorityControl
    ) async throws -> AsyncPermitPool.Permit {
        do {
            return try await permits.acquire(
                priority: await priorityControl.currentPriority(),
                priorityUpdates: await priorityControl.updates()
            )
        } catch is CancellationError {
            throw PipelineFailure.cancelled(stage: .transport)
        } catch PermitPoolError.queueLimitExceeded {
            throw PipelineFailure.resourceLimit(
                stage: .transport,
                reasonCode: "fetch-queue-limit-exceeded"
            )
        }
    }

    private func normalizeSubscriptionFailure(
        _ error: any Error,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async -> any Error {
        FetchSubscriptionFailureNormalizer.normalize(
            error,
            namespaceIsActive: await namespaceRegistry.isActive(
                generation,
                for: request.namespace
            ),
            callerIsCancelled: Task.isCancelled
        )
    }
}
