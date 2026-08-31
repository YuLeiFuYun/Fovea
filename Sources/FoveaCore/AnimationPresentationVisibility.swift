import Foundation

/// 平台 presenter 使用这个纯谓词，避免为不可见动画安排工作。
///
/// 祖先隐藏和可见区域状态仍由平台层推导；把谓词留在 Core，可让 UIKit、AppKit 与测试共享失败关闭契约，同时无需导入 UI API。
package enum AnimationPresentationVisibility {
    package static func isEffectivelyVisible(
        windowAttached: Bool,
        superviewAttached: Bool,
        hidden: Bool,
        alpha: Double,
        intersectsVisibleRegion: Bool
    ) -> Bool {
        windowAttached
            && superviewAttached
            && !hidden
            && alpha.isFinite
            && alpha > 0
            && intersectsVisibleRegion
    }
}
