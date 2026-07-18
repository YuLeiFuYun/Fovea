import Foundation
import ImageCraftCore

final class DecodeStage: Sendable {
  private let decoder: any ImageDecoding
  private let limits: DecodeLimits
  private let diagnostics: any DiagnosticsSink
  private let permits: AsyncPermitPool
  private let executor = DispatchWorkExecutor(label: "dev.fovea.decode")
  private let registry = SharedTaskRegistry<ScopedDecodeKey, DecodedImage>()

  init(
    decoder: any ImageDecoding,
    limits: DecodeLimits,
    diagnostics: any DiagnosticsSink,
    maximumConcurrentDecodes: Int,
    maximumQueuedDecodes: Int
  ) {
    self.decoder = decoder
    self.limits = limits
    self.diagnostics = diagnostics
    self.permits = AsyncPermitPool(
      limit: maximumConcurrentDecodes,
      queueLimit: maximumQueuedDecodes
    )
  }

  func cancelAll(namespace: SecurityNamespaceID) async {
    _ = await registry.cancelAll { $0.namespace == namespace }
  }

  @concurrent
  func image(
    from data: Data,
    contentID: ContentID,
    request: ImageRequest,
    generation: NamespaceGeneration,
    keyDigest: String
  ) async throws -> DecodedImage {
    let decodeKey = DecodeKey(
      contentID: contentID,
      targetWidth: request.target.width,
      targetHeight: request.target.height,
      decoderVersion: 1
    )
    let scopedKey = ScopedDecodeKey(
      namespace: request.namespace,
      generation: generation,
      decodeKey: decodeKey
    )
    let subscription = await registry.subscribe(
      key: scopedKey,
      priority: request.priority
    ) { [self] priorityControl in
      try await performDecode(
        data: data,
        request: request,
        keyDigest: keyDigest,
        priorityControl: priorityControl
      )
    }

    if subscription.wasJoined {
      await diagnostics.record(
        DiagnosticEvent(
          kind: .decodeJoined,
          keyDigest: keyDigest,
          requestedPriority: request.priority,
          effectivePriority: await subscription.priorityControl.currentPriority()
        )
      )
    }

    return try await withTaskCancellationHandler {
      do {
        let image = try await subscription.value()
        try Task.checkCancellation()
        await subscription.cancel()
        return image
      } catch {
        await subscription.cancel()
        if error is CancellationError { throw PipelineFailure.cancelled(stage: .decode) }
        throw error
      }
    } onCancel: {
      Task { await subscription.cancel() }
    }
  }

  private func performDecode(
    data: Data,
    request: ImageRequest,
    keyDigest: String,
    priorityControl: SharedTaskPriorityControl
  ) async throws -> DecodedImage {
    try Task.checkCancellation()
    await diagnostics.record(
      DiagnosticEvent(
        kind: .decodeQueued,
        keyDigest: keyDigest,
        requestedPriority: request.priority
      )
    )
    let permit: AsyncPermitPool.Permit
    do {
      let initialPriority = await priorityControl.currentPriority()
      permit = try await permits.acquire(
        priority: initialPriority,
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

    let effectivePriority = await priorityControl.currentPriority()
    await diagnostics.record(
      DiagnosticEvent(
        kind: .decodeStarted,
        keyDigest: keyDigest,
        requestedPriority: request.priority,
        effectivePriority: effectivePriority
      )
    )

    let probe: ImageProbe
    do {
      probe = try await executor.run { [decoder, limits] in
        try decoder.probe(data: data, limits: limits)
      }
      try Task.checkCancellation()
    } catch is CancellationError {
      await permit.release()
      throw PipelineFailure.cancelled(stage: .probe)
    } catch {
      await permit.release()
      throw PipelineFailure.imageCraft(error, stage: .probe)
    }

    let image: DecodedImage
    do {
      image = try await executor.run { [decoder, limits] in
        try decoder.decode(
          data: data,
          probe: probe,
          target: request.target,
          limits: limits
        )
      }
      try Task.checkCancellation()
      await permit.release()
    } catch is CancellationError {
      await permit.release()
      throw PipelineFailure.cancelled(stage: .decode)
    } catch {
      await permit.release()
      throw PipelineFailure.imageCraft(error, stage: .decode)
    }
    await diagnostics.record(
      DiagnosticEvent(
        kind: .decodeCompleted,
        keyDigest: keyDigest,
        sourcePixelCount: Self.pixelCount(width: probe.pixelWidth, height: probe.pixelHeight),
        outputPixelCount: Self.pixelCount(width: image.pixelWidth, height: image.pixelHeight),
        targetWidth: request.target.width,
        targetHeight: request.target.height
      )
    )
    return image
  }

  private static func pixelCount(width: Int, height: Int) -> Int {
    let (result, overflow) = width.multipliedReportingOverflow(by: height)
    return overflow ? Int.max : result
  }
}
