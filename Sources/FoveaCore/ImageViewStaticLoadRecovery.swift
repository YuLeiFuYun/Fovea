import Foundation
import ImageCraftCore

/// UIKit/AppKit 静态图窗口生命周期的共享恢复状态。
///
/// 该对象只在 MainActor 使用。窗口 detach 可以保存同一请求的轻量 restart recipe，
/// 但显式 cancel/reuse 会立即删除 recipe，避免调用方已经取消的工作在 reattach 时复活。
@MainActor
package final class ImageViewStaticLoadRecovery {
    package struct Recipe {
        package let token: UUID
        package let request: ImageRequest
        package let loader: any ImageLoading
        package let placeholderDelayNanoseconds: UInt64
    }

    private var recipe: Recipe?
    private var completion:
        (@MainActor @Sendable (Result<DecodedImage, PipelineFailure>) -> Void)?
    private var resumesWhenAttached = false

    package init() {}

    @discardableResult
    package func install(
        request: ImageRequest,
        loader: any ImageLoading,
        placeholderDelayNanoseconds: UInt64,
        completion: (@MainActor @Sendable (Result<DecodedImage, PipelineFailure>) -> Void)?
    ) -> Recipe {
        let recipe = Recipe(
            token: UUID(),
            request: request,
            loader: loader,
            placeholderDelayNanoseconds: placeholderDelayNanoseconds
        )
        self.recipe = recipe
        self.completion = completion
        resumesWhenAttached = false
        return recipe
    }

    /// 仅窗口 detach 路径调用。没有当前 recipe 时不会创造恢复责任。
    package func suspend(resumeWhenAttached: Bool) {
        resumesWhenAttached = resumeWhenAttached && recipe != nil
    }

    /// reattach 消费一次恢复意图；recipe 仅在当前未完成订阅生命周期内保留。
    package func takeResumeRecipe() -> Recipe? {
        guard resumesWhenAttached, let recipe else { return nil }
        resumesWhenAttached = false
        return recipe
    }

    /// 完成回调是一次性的。成功或失败都结束当前订阅并删除 restart recipe；
    /// 只有 detach 时仍未完成的订阅才允许在 reattach 后恢复，因此不会为了未来窗口切换
    /// 长期强持有调用方提供的 loader。
    package func resolve(
        _ result: Result<DecodedImage, PipelineFailure>,
        token: UUID
    ) {
        guard recipe?.token == token else { return }
        let handler = completion
        completion = nil
        recipe = nil
        resumesWhenAttached = false
        handler?(result)
    }

    /// 显式 cancel、reuse 或切换到动画/live surface 必须走这里，绝不能留下 reattach recipe。
    package func clear() {
        recipe = nil
        completion = nil
        resumesWhenAttached = false
    }
}
