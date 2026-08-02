import Foundation

/// 把同一轮 UI/调用方替换产生的取消归入一个有界 cohort。
///
/// 该窗口同时约束 FetchStage 的取消墓碑和自适应准入观察域，避免两个状态机对
/// “同一轮迟到调用”使用不一致时间语义。数值必须由参数注册表和 W7 敏感性证据约束。
package enum CancellationCohortPolicy {
    package static let retentionNanoseconds: UInt64 = 250_000_000
}
