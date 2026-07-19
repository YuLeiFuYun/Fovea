import Foundation
import FoveaHTTP

struct TimedTransportResponse: Sendable {
  let requestTime: Date
  let responseTime: Date
  let transport: TransportResponse

  var head: TransportResponseHead { transport.head }
}

final class FetchStage: Sendable {
  private let configuration: PipelineConfiguration
  private let transport: any HTTPTransporting
  private let diagnostics: any DiagnosticsSink
  private let clock: any WallClock
  private let namespaceRegistry: NamespaceRegistry
  private let retrySleeper: any RetrySleeping
  private let retryJitter: any RetryJittering
  private let permits: AsyncPermitPool
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
    self.configuration = configuration
    self.transport = transport
    self.diagnostics = diagnostics
    self.clock = clock
    self.namespaceRegistry = namespaceRegistry
    self.retrySleeper = retrySleeper
    self.retryJitter = retryJitter
    self.permits = AsyncPermitPool(
      limit: configuration.maximumConcurrentFetches,
      queueLimit: configuration.maximumQueuedFetches
    )
  }

  func cancelAll(namespace: SecurityNamespaceID) async {
    _ = await registry.cancelAll { $0.namespace == namespace }
  }

  @concurrent
  func response(
    for request: ImageRequest,
    conditionalRecord: RepresentationRecord?,
    generation: NamespaceGeneration
  ) async throws -> TimedTransportResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = "GET"
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    if let conditionalRecord {
      for (name, value) in HTTPCachePolicy.conditionalHeaders(for: conditionalRecord) {
        urlRequest.setValue(value, forHTTPHeaderField: name)
      }
    }

    let selectedVariant = conditionalRecord.map { request.fetchVariantKey(for: $0.vary) }
    let executionKey = request.fetchExecutionKey(
      selectedVariant: selectedVariant,
      revalidationFingerprint: Self.revalidationFingerprint(for: conditionalRecord),
      transportPolicyFingerprint: configuration.transportPolicyFingerprint
    )
    let scopedKey = ScopedFetchExecutionKey(
      namespace: request.namespace,
      execution: executionKey
    )
    let authorizedRequest = urlRequest
    let subscription = await registry.subscribe(
      key: scopedKey,
      priority: request.priority
    ) { [self] priorityControl in
      await diagnostics.record(
        DiagnosticEvent(
          kind: .fetchQueued,
          keyDigest: executionKey.digestHex,
          requestedPriority: request.priority
        )
      )
      return try await executeWithRetry(
        authorizedRequest: authorizedRequest,
        request: request,
        generation: generation,
        executionKey: executionKey,
        priorityControl: priorityControl
      )
    }

    if subscription.wasJoined {
      await diagnostics.record(
        DiagnosticEvent(
          kind: .fetchJoined,
          keyDigest: executionKey.digestHex,
          requestedPriority: request.priority,
          effectivePriority: await subscription.priorityControl.currentPriority()
        )
      )
    }

    return try await withTaskCancellationHandler {
      do {
        let result = try await subscription.value()
        try Task.checkCancellation()
        await subscription.cancel()
        return result
      } catch {
        await subscription.cancel()
        if !(await namespaceRegistry.isActive(generation, for: request.namespace)) {
          throw PipelineFailure.namespaceRevoked
        }
        if error is CancellationError { throw PipelineFailure.cancelled(stage: .transport) }
        throw error
      }
    } onCancel: {
      Task { await subscription.cancel() }
    }
  }

  private func executeWithRetry(
    authorizedRequest: URLRequest,
    request: ImageRequest,
    generation: NamespaceGeneration,
    executionKey: FetchExecutionKey,
    priorityControl: SharedTaskPriorityControl
  ) async throws -> TimedTransportResponse {
    let policy = configuration.transportRetryPolicy
    var attempt = 1
    var totalDelay: UInt64 = 0
    var additionalResponseBytes = 0

    while true {
      try Task.checkCancellation()
      guard await namespaceRegistry.isActive(generation, for: request.namespace) else {
        throw PipelineFailure.namespaceRevoked
      }

      let response: TimedTransportResponse
      do {
        response = try await executeAttempt(
          authorizedRequest: authorizedRequest,
          request: request,
          executionKey: executionKey,
          attempt: attempt,
          priorityControl: priorityControl
        )
      } catch {
        let failure: PipelineFailure
        if error is CancellationError {
          failure = .cancelled(stage: .transport)
        } else if let pipelineFailure = error as? PipelineFailure {
          failure = pipelineFailure
        } else {
          failure = .transport(error)
        }

        guard failure.disposition == .retryable,
          attempt < policy.maximumAttempts,
          let delay = await retryDelay(
            policy: policy,
            failedAttempt: attempt,
            retryAfterNanoseconds: nil,
            totalDelay: totalDelay
          )
        else {
          if failure.disposition == .cancelled {
            await diagnostics.record(
              DiagnosticEvent(
                kind: .fetchCancelled,
                keyDigest: executionKey.digestHex,
                attempt: attempt
              )
            )
          }
          throw failure
        }

        totalDelay += delay
        await recordRetry(
          executionKey: executionKey,
          attempt: attempt,
          delay: delay,
          reason: failure.reasonCode,
          statusCode: failure.statusCode
        )
        try await retrySleeper.sleep(nanoseconds: delay)
        attempt += 1
        continue
      }

      let statusFailure = PipelineFailure.unsupportedStatus(response.head.statusCode)
      guard statusFailure.disposition == .retryable, response.head.statusCode != 304 else {
        await recordCompleted(response, executionKey: executionKey, attempt: attempt)
        return response
      }

      let bytes = response.transport.metrics.receivedBytes
      let byteTotal = additionalResponseBytes.addingReportingOverflow(bytes)
      guard attempt < policy.maximumAttempts,
        !byteTotal.overflow,
        byteTotal.partialValue <= policy.maximumAdditionalResponseBytes
      else {
        await recordCompleted(response, executionKey: executionKey, attempt: attempt)
        return response
      }

      let retryAfter = HTTPCachePolicy.retryAfterNanoseconds(
        in: response.head.headers,
        now: response.responseTime,
        maximum: policy.maximumDelayNanoseconds
      )
      guard
        let delay = await retryDelay(
          policy: policy,
          failedAttempt: attempt,
          retryAfterNanoseconds: retryAfter,
          totalDelay: totalDelay
        )
      else {
        await recordCompleted(response, executionKey: executionKey, attempt: attempt)
        return response
      }

      additionalResponseBytes = byteTotal.partialValue
      totalDelay += delay
      await recordRetry(
        executionKey: executionKey,
        attempt: attempt,
        delay: delay,
        reason: "http-status-retry",
        statusCode: response.head.statusCode
      )
      try await retrySleeper.sleep(nanoseconds: delay)
      attempt += 1
    }
  }

  private func executeAttempt(
    authorizedRequest: URLRequest,
    request: ImageRequest,
    executionKey: FetchExecutionKey,
    attempt: Int,
    priorityControl: SharedTaskPriorityControl
  ) async throws -> TimedTransportResponse {
    let permit: AsyncPermitPool.Permit
    do {
      let initialPriority = await priorityControl.currentPriority()
      permit = try await permits.acquire(
        priority: initialPriority,
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

    let effectivePriority = await priorityControl.currentPriority()
    await diagnostics.record(
      DiagnosticEvent(
        kind: .fetchStarted,
        keyDigest: executionKey.digestHex,
        attempt: attempt,
        requestedPriority: request.priority,
        effectivePriority: effectivePriority
      )
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

    do {
      let transportResponse = try await transport.execute(
        TransportRequest(
          request: authorizedRequest,
          maximumBytes: configuration.maximumTransportBytes,
          memoryThreshold: configuration.transportMemoryThreshold,
          credentialHeaderNames: request.credentialHeaderNames,
          priority: effectivePriority.transportPriority,
          priorityController: transportPriority
        )
      )
      let responseTime = await clock.now()
      priorityPropagation.cancel()
      await transportPriority.finish()
      await permit.release()
      return TimedTransportResponse(
        requestTime: requestTime,
        responseTime: responseTime,
        transport: transportResponse
      )
    } catch {
      priorityPropagation.cancel()
      await transportPriority.finish()
      await permit.release()
      throw error
    }
  }

  private func retryDelay(
    policy: TransportRetryPolicy,
    failedAttempt: Int,
    retryAfterNanoseconds: UInt64?,
    totalDelay: UInt64
  ) async -> UInt64? {
    let jitter = await retryJitter.offsetPermille(maximumMagnitude: policy.jitterPermille)
    let delay = policy.delayNanoseconds(
      afterFailedAttempt: failedAttempt,
      retryAfterNanoseconds: retryAfterNanoseconds,
      jitterOffsetPermille: jitter
    )
    let nextTotal = totalDelay.addingReportingOverflow(delay)
    guard !nextTotal.overflow, nextTotal.partialValue <= policy.maximumTotalDelayNanoseconds else {
      return nil
    }
    return delay
  }

  private func recordRetry(
    executionKey: FetchExecutionKey,
    attempt: Int,
    delay: UInt64,
    reason: String,
    statusCode: Int?
  ) async {
    await diagnostics.record(
      DiagnosticEvent(
        kind: .fetchRetryScheduled,
        keyDigest: executionKey.digestHex,
        statusCode: statusCode,
        reason: reason,
        attempt: attempt,
        retryDelayNanoseconds: delay
      )
    )
  }

  private func recordCompleted(
    _ response: TimedTransportResponse,
    executionKey: FetchExecutionKey,
    attempt: Int
  ) async {
    await diagnostics.record(
      DiagnosticEvent(
        kind: .fetchCompleted,
        keyDigest: executionKey.digestHex,
        statusCode: response.head.statusCode,
        byteCount: response.transport.metrics.receivedBytes,
        attempt: attempt
      )
    )
  }

  private static func revalidationFingerprint(for record: RepresentationRecord?) -> String {
    guard let record else { return "unconditional" }
    let etag = record.etag ?? ""
    let lastModified = record.lastModified ?? ""
    return Data("etag:\(etag)\u{0}last-modified:\(lastModified)".utf8).sha256Hex
  }
}

extension ImageRequestPriority {
  fileprivate var transportPriority: TransportPriority {
    switch self {
    case .background: .background
    case .low: .low
    case .normal: .normal
    case .high: .high
    case .userInitiated: .userInitiated
    }
  }
}
