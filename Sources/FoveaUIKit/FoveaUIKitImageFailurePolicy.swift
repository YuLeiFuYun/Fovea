#if canImport(UIKit)
  import FoveaCore
  import UIKit

  public enum FoveaUIKitImageFailurePolicy {
    public static func action(for failure: PipelineFailure) -> FoveaImageRecoveryAction {
      failure.imageRecoveryAction
    }
  }
#endif
