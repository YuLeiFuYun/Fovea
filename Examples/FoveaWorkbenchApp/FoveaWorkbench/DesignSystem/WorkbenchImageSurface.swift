import SwiftUI

struct WorkbenchImageSurfaceConfiguration: Equatable {
    let aspectRatio: CGFloat
    let contentMode: WorkbenchContentMode
    let cornerRadius: CGFloat

    init(
        aspectRatio: CGFloat,
        contentMode: WorkbenchContentMode,
        cornerRadius: CGFloat = WorkbenchDesign.compactCardRadius
    ) {
        self.aspectRatio = Self.sanitizedAspectRatio(aspectRatio)
        self.contentMode = contentMode
        self.cornerRadius = Self.sanitizedCornerRadius(cornerRadius)
    }

    static func detail(assetAspectRatio: CGFloat, contentMode: WorkbenchContentMode) -> Self {
        Self(
            aspectRatio: contentMode == .fit ? assetAspectRatio : 16 / 9,
            contentMode: contentMode,
            cornerRadius: WorkbenchDesign.prominentCardRadius
        )
    }

    private static func sanitizedAspectRatio(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 4 / 3 }
        return min(4, max(1 / 4, value))
    }

    private static func sanitizedCornerRadius(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return WorkbenchDesign.compactCardRadius }
        return min(40, max(0, value))
    }
}

/// 唯一拥有图片容器比例、背景、裁切和圆角的表面。
/// 子视图只负责按同一 contentMode 绘制，不得再声明第二层容器比例。
struct WorkbenchImageSurface<Content: View, Overlay: View>: View {
    let configuration: WorkbenchImageSurfaceConfiguration
    private let content: () -> Content
    private let overlay: () -> Overlay

    init(
        configuration: WorkbenchImageSurfaceConfiguration,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder overlay: @escaping () -> Overlay
    ) {
        self.configuration = configuration
        self.content = content
        self.overlay = overlay
    }

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(configuration.aspectRatio, contentMode: .fit)
        .clipped()
        .clipShape(
            RoundedRectangle(cornerRadius: configuration.cornerRadius, style: .continuous)
        )
        .overlay(alignment: .topLeading) { overlay() }
        .contentShape(
            RoundedRectangle(cornerRadius: configuration.cornerRadius, style: .continuous)
        )
    }
}

extension WorkbenchImageSurface where Overlay == EmptyView {
    init(
        configuration: WorkbenchImageSurfaceConfiguration,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(configuration: configuration, content: content, overlay: { EmptyView() })
    }
}
