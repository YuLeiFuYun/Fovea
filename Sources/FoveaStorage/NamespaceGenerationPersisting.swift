/// 为不透明命名空间指纹持久化单调递增的代际。
///
/// 该契约有意只承载存储层值，不理解退出登录、
/// 授权、管线失败或清理屏障；这些语义仍由 FoveaCore 负责。
package protocol NamespaceGenerationPersisting: Sendable {
    func load(
        maximumCount: Int
    ) async throws -> [StorageNamespaceFingerprint: UInt64]

    func persist(
        _ generation: UInt64,
        for namespace: StorageNamespaceFingerprint
    ) async throws
}
