import Foundation

/// 单次图片请求可使用的网络类型。
///
/// 该策略只影响本次传输执行，不进入持久缓存身份；不同策略必须产生不同的
/// FetchExecutionKey，避免低权限请求与高权限请求错误共享网络任务。
public struct ImageRequestNetworkPolicy: Codable, Hashable, Sendable {
  public let allowsCellularAccess: Bool
  public let allowsConstrainedNetworkAccess: Bool
  public let allowsExpensiveNetworkAccess: Bool

  public init(
    allowsCellularAccess: Bool,
    allowsConstrainedNetworkAccess: Bool,
    allowsExpensiveNetworkAccess: Bool
  ) {
    self.allowsCellularAccess = allowsCellularAccess
    self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
    self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
  }

  /// 面向当前可见内容的默认策略；遵循系统网络选择，不静默限制蜂窝或 Low Data Mode。
  public static let interactive = ImageRequestNetworkPolicy(
    allowsCellularAccess: true,
    allowsConstrainedNetworkAccess: true,
    allowsExpensiveNetworkAccess: true
  )

  /// 面向预取或可延后工作的保守策略。
  public static let conservative = ImageRequestNetworkPolicy(
    allowsCellularAccess: true,
    allowsConstrainedNetworkAccess: false,
    allowsExpensiveNetworkAccess: false
  )

  package var executionFingerprint: String {
    [
      "cellular:\(allowsCellularAccess)",
      "constrained:\(allowsConstrainedNetworkAccess)",
      "expensive:\(allowsExpensiveNetworkAccess)",
    ].joined(separator: ";")
  }
}
