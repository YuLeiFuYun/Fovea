import Foundation

/// namespace generation 推进后、缓存清理前需要同步关闭的运行时资源。
package protocol NamespaceRevocationObserving: Sendable {
    /// `minimumActiveGeneration` 是持久化推进后的新 generation；nil 表示推进失败但仍需清理。
    func namespaceWillRevoke(
        _ namespace: SecurityNamespaceID,
        minimumActiveGeneration: NamespaceGeneration?
    ) async
}
