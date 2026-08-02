import Foundation

/// 尚未进入逻辑清单、只能由创建它的存储实例发布或丢弃的编码数据阶段令牌。
package struct OriginalEncodedStage: Hashable, Sendable {
    package let identifier: UUID

    package init(identifier: UUID) {
        self.identifier = identifier
    }
}

/// 为原始编码存储补充不可见 staging 与显式发布边界。
///
/// `stage` 只能创建未被逻辑清单引用的物理数据；`publish` 成功后数据才可通过
/// `read`/`physicalID` 观察。调用方必须在验证失败、取消或撤销时调用 `discard`。
package protocol OriginalEncodedTransactionalStoring: OriginalEncodedStoring {
    func stage(data: Data, contentID: String, namespace: String) async throws
        -> OriginalEncodedStage
    func publish(_ stage: OriginalEncodedStage) async throws -> StoredBlob
    func discard(_ stage: OriginalEncodedStage) async
}
