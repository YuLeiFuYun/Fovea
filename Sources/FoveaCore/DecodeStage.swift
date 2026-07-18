import Foundation
import ImageCraftCore

final class DecodeStage: Sendable {
  private let decoder: any ImageDecoding
  private let limits: DecodeLimits
  private let diagnostics: any DiagnosticsSink
  private let permits: AsyncPermitPool
  private let executor = DispatchWorkExecutor(label: "dev.fovea.decode")

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

  @concurrent
  func image(
    from data: Data,
    request: ImageRequest,
    keyDigest: String
  ) async throws -> DecodedImage {
    try Task.checkCancellation()
    await diagnostics.record(
      DiagnosticEvent(kind: .decodeQueued, keyDigest: keyDigest)
    )
    let permit: AsyncPermitPool.Permit
    do {
      permit = try await permits.acquire()
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

    await diagnostics.record(
      DiagnosticEvent(kind: .decodeStarted, keyDigest: keyDigest)
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
