/// 让组合根生命周期协作者与其管线保持完全相同的存活期。
///
/// 该 actor 避免初始化后的可变状态削弱 `FoveaPipeline` 的
/// `Sendable` 契约，同时允许高层模块无环地附加监视器。
package actor PipelineLifetimeAnchorStore {
    private var anchors: [any Sendable] = []

    package func retain(_ anchor: any Sendable) {
        anchors.append(anchor)
    }

    package var count: Int { anchors.count }
}
