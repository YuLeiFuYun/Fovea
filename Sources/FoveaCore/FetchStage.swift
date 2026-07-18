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
  private let permits: AsyncPermitPool
  private let registry = SharedTaskRegistry<ScopedFetchExecutionKey, TimedTransportResponse>()

  init(
    configuration: PipelineConfiguration,
    transport: any HTTPTransporting,
    diagnostics: any DiagnosticsSink,
    clock: any WallClock,
    namespaceRegistry: NamespaceRegistry
  ) {
    self.configuration = configuration
    self.transport = transport
    self.diagnostics = diagnostics
    self.clock = clock
    self.namespaceRegistry = namespaceRegistry
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
      revalidationFingerprint: Self.revalidationFingerprint(for: conditionalRecord)
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
      do {
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
        let transportResponse: TransportResponse
        do {
          transportResponse = try await transport.execute(
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
          await diagnostics.record(
            DiagnosticEvent(
              kind: .fetchCompleted,
              keyDigest: executionKey.digestHex,
              statusCode: transportResponse.head.statusCode,
              byteCount: transportResponse.metrics.receivedBytes
            )
          )
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
      } catch {
        if error is CancellationError {
          await diagnostics.record(
            DiagnosticEvent(kind: .fetchCancelled, keyDigest: executionKey.digestHex)
          )
          throw PipelineFailure.cancelled(stage: .transport)
        }
        if let failure = error as? PipelineFailure { throw failure }
        throw PipelineFailure.transport(error)
      }
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
