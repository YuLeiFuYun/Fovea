import FoveaCore
import FoveaSwiftUI
import XCTest

#if canImport(AppKit)
  import FoveaAppKit
#endif

#if canImport(UIKit)
  import FoveaUIKit
#endif

final class PlatformUIFailurePolicyTests: XCTestCase {
  func testSwiftUIUsesCoreRecoveryMatrix_ERR_PT_014() {
    for (failure, expected) in fixtures {
      XCTAssertEqual(FoveaSwiftUIImageFailurePolicy.action(for: failure), expected)
      XCTAssertEqual(failure.imageRecoveryAction, expected)
    }
  }

  #if canImport(AppKit)
    func testAppKitAndSwiftUIUseSameRecoveryMatrix_ERR_PT_014() {
      for (failure, _) in fixtures {
        XCTAssertEqual(
          FoveaAppKitImageFailurePolicy.action(for: failure),
          FoveaSwiftUIImageFailurePolicy.action(for: failure)
        )
      }
    }
  #endif

  #if canImport(UIKit)
    func testUIKitAndSwiftUIUseSameRecoveryMatrix_ERR_PT_014() {
      for (failure, _) in fixtures {
        XCTAssertEqual(
          FoveaUIKitImageFailurePolicy.action(for: failure),
          FoveaSwiftUIImageFailurePolicy.action(for: failure)
        )
      }
    }
  #endif

  private var fixtures: [(PipelineFailure, FoveaImageRecoveryAction)] {
    [
      (
        PipelineFailure(
          category: .transport,
          stage: .transport,
          disposition: .retryable,
          reasonCode: "transport"
        ),
        .retry
      ),
      (
        PipelineFailure(
          category: .cacheWrite,
          stage: .persistence,
          disposition: .cacheDegraded,
          reasonCode: "cache-degraded"
        ),
        .retry
      ),
      (
        PipelineFailure(
          category: .namespaceRevoked,
          stage: .revocation,
          disposition: .terminal,
          reasonCode: "namespace-revoked"
        ),
        .reauthenticate
      ),
      (
        PipelineFailure(
          category: .securityLimit,
          stage: .probe,
          disposition: .terminal,
          reasonCode: "security-limit"
        ),
        .none
      ),
      (
        PipelineFailure(
          category: .cancelled,
          stage: .pipeline,
          disposition: .cancelled,
          reasonCode: "cancelled"
        ),
        .none
      ),
    ]
  }
}
