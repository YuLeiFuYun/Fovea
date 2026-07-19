import ImageCraftCore

package struct TransformStage: Sendable {
  package nonisolated let fingerprint: String
  private let transformer: any ImageTransforming

  package init(transformer: any ImageTransforming) {
    self.transformer = transformer
    self.fingerprint = transformer.fingerprint
  }

  package func image(from decoded: DecodedImage) async throws -> DecodedImage {
    do {
      return try await transformer.transform(decoded)
    } catch is CancellationError {
      throw PipelineFailure.cancelled(stage: .transform)
    } catch let failure as PipelineFailure {
      throw failure
    } catch {
      throw PipelineFailure.transformFailed
    }
  }
}
