#if canImport(AppKit)
  import AppKit
  import FoveaCore

  public enum FoveaAppKitImageFailurePolicy {
    public static func action(for failure: PipelineFailure) -> FoveaImageRecoveryAction {
      failure.imageRecoveryAction
    }
  }
#endif
