import AkashicCore
import Foundation

/// 在显式安全命名空间内存取原始编码载荷。

public protocol OriginalEncodedStoring: Sendable {
    /// 读取并完整性校验命名空间内容身份对应的原始载荷。
    func read(contentID: String, namespace: String) async throws -> Data

    /// 原子发布已验证字节，或复用内容相同的现有数据块。
    @discardableResult
    func commit(data: Data, contentID: String, namespace: String) async throws -> StoredBlob

    /// 返回不透明物理定位符，但不暴露文件系统路径。
    func physicalID(contentID: String, namespace: String) async -> PhysicalBlobID?
    /// 删除一个命名空间逻辑内容引用及其不再被引用的数据块。
    func remove(contentID: String, namespace: String) async throws
    /// 删除某命名空间拥有的全部逻辑与物理条目。
    func removeAll(namespace: String) async throws
}
