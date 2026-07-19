import Foundation
import ImageCraftCore

package final class DecodeStage: Sendable {
  private let decoder: any ImageDecoding
  private let limits: DecodeLimits
  private let diagnostics: any DiagnosticsSink
  private let permits: AsyncPermitPool
  private let workingSetPermits: AsyncPermitPool
  private let executor = DispatchWorkExecutor(label: "dev.fovea.decode")
  private let registry = SharedTaskRegistry<ScopedDecodeKey, DecodedImage>()

  package init(
    decoder: any ImageDecoding,
    limits: DecodeLimits,
    diagnostics: any DiagnosticsSink,
    maximumConcurrentDecodes: Int,
    maximumDecodeWorkingSetBytes: Int,
    maximumQueuedDecodes: Int,
    decodePermits: AsyncPermitPool? = nil,
    workingSetPermits: AsyncPermitPool? = nil
  ) {
    self.decoder = decoder
    self.limits = limits
    self.diagnostics = diagnostics
    self.permits =
      decodePermits
      ?? AsyncPermitPool(
        limit: maximumConcurrentDecodes,
        queueLimit: maximumQueuedDecodes
      )
    self.workingSetPermits =
      workingSetPermits
      ?? AsyncPermitPool(
        limit: maximumDecodeWorkingSetBytes,
        queueLimit: maximumQueuedDecodes
      )
  }

  func cancelAll(namespace: SecurityNamespaceID) async {
    _ = await registry.cancelAll { $0.namespace == namespace }
  }

  @concurrent
  package func image(
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
      contentMode: request.contentMode,
      geometryPolicyFingerprint: request.geometryPolicyFingerprint,
      colorPolicy: request.colorPolicy,
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

    let probePermit = try await acquireDecodePermit(priorityControl: priorityControl)
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
      await probePermit.release()
    } catch is CancellationError {
      await probePermit.release()
      throw PipelineFailure.cancelled(stage: .probe)
    } catch {
      await probePermit.release()
      throw PipelineFailure.imageCraft(error, stage: .probe)
    }

    let workingSetBytes = ImageDecodeWorkingSetEstimator.estimatedBytes(
      probe: probe,
      request: ImageDecodeRequest(
        target: request.target,
        contentMode: request.contentMode,
        geometryPolicyFingerprint: request.geometryPolicyFingerprint,
        colorPolicy: request.colorPolicy
      )
    )
    let workingSetPermit: AsyncPermitPool.Permit
    do {
      workingSetPermit = try await workingSetPermits.acquire(
        units: workingSetBytes,
        priority: await priorityControl.currentPriority(),
        priorityUpdates: await priorityControl.updates()
      )
      await diagnostics.record(
        DiagnosticEvent(
          kind: .decodeWorkingSetReserved,
          keyDigest: keyDigest,
          byteCount: workingSetBytes,
          requestedPriority: request.priority,
          effectivePriority: await priorityControl.currentPriority()
        )
      )
    } catch is CancellationError {
      throw PipelineFailure.cancelled(stage: .decode)
    } catch PermitPoolError.requestExceedsLimit {
      await diagnostics.record(
        DiagnosticEvent(
          kind: .decodeAdmissionRejected,
          keyDigest: keyDigest,
          byteCount: workingSetBytes,
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

    let decodePermit: AsyncPermitPool.Permit
    do {
      decodePermit = try await acquireDecodePermit(priorityControl: priorityControl)
    } catch {
      await workingSetPermit.release()
      throw error
    }

    let image: DecodedImage
    do {
      try Task.checkCancellation()
      image = try await executor.run { [decoder, limits] in
        try decoder.decode(
          data: data,
          probe: probe,
          request: ImageDecodeRequest(
            target: request.target,
            contentMode: request.contentMode,
            geometryPolicyFingerprint: request.geometryPolicyFingerprint,
            colorPolicy: request.colorPolicy
          ),
          limits: limits
        )
      }
      try Task.checkCancellation()
      await decodePermit.release()
      await workingSetPermit.release()
    } catch is CancellationError {
      await decodePermit.release()
      await workingSetPermit.release()
      throw PipelineFailure.cancelled(stage: .decode)
    } catch {
      await decodePermit.release()
      await workingSetPermit.release()
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

  private func acquireDecodePermit(
    priorityControl: SharedTaskPriorityControl
  ) async throws -> AsyncPermitPool.Permit {
    do {
      return try await permits.acquire(
        priority: await priorityControl.currentPriority(),
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

  private static func pixelCount(width: Int, height: Int) -> Int {
    let (result, overflow) = width.multipliedReportingOverflow(by: height)
    return overflow ? Int.max : result
  }
}
