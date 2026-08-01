/// namespace 世代持久化与管线配置共享的绝对表示域。
///
/// 该值限制可追踪 namespace 的数量，不表示默认预分配。具体上限仍由数学参数门
/// 审查；共享定义保证配置层不会接受持久化层无法表示的状态。
package enum NamespaceStorageLimits {
    package static let maximumTrackedNamespaces = 1_000_000
}
