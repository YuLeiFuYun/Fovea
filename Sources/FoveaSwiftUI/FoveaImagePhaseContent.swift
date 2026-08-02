import FoveaCore
import ImageCraftCore
import SwiftUI

@MainActor
package struct FoveaImagePhaseContent<Placeholder: View, Failure: View>: View {
    private let phase: FoveaImagePhase
    private let accessibility: FoveaImageAccessibility
    private let contentMode: ImageContentMode
    private let placeholder: () -> Placeholder
    private let failure: (FoveaImageFailureContext) -> Failure
    private let retryAction: @MainActor () -> Void
    private let previewAppeared: @MainActor () -> Void
    private let successAppeared: @MainActor () -> Void

    package init(
        phase: FoveaImagePhase,
        accessibility: FoveaImageAccessibility,
        contentMode: ImageContentMode = .fit,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping (FoveaImageFailureContext) -> Failure,
        retryAction: @escaping @MainActor () -> Void,
        previewAppeared: @escaping @MainActor () -> Void = {},
        successAppeared: @escaping @MainActor () -> Void = {}
    ) {
        self.phase = phase
        self.accessibility = accessibility
        self.contentMode = contentMode
        self.placeholder = placeholder
        self.failure = failure
        self.retryAction = retryAction
        self.previewAppeared = previewAppeared
        self.successAppeared = successAppeared
    }

    @ViewBuilder
    package var body: some View {
        switch phase {
        case .empty:
            // 初始状态保持透明，只有占位延迟真正到期后才进入 `.loading`。
            // 这样近同步内存命中和滚动回屏不会先闪过一次 loading 视图。
            Color.clear.accessibilityHidden(true)
        case .loading, .cancelled:
            placeholder()
        case .preview(let decoded):
            renderedImage(decoded)
                .onAppear(perform: previewAppeared)
        case .success(let decoded):
            renderedImage(decoded)
                .onAppear(perform: successAppeared)
        case .failure(let error):
            failure(
                FoveaImageFailureContext(
                    failure: error,
                    recoveryAction: error.imageRecoveryAction,
                    retryAction: retryAction
                )
            )
        }
    }

    @ViewBuilder
    private func renderedImage(_ decoded: DecodedImage) -> some View {
        switch accessibility {
        case .decorative:
            Image(decorative: decoded.cgImage, scale: 1)
                .resizable()
                .aspectRatio(contentMode: swiftUIContentMode)
                .clipped()
        case .label(let label):
            Image(decoded.cgImage, scale: 1, label: label)
                .resizable()
                .aspectRatio(contentMode: swiftUIContentMode)
                .clipped()
        }
    }

    private var swiftUIContentMode: ContentMode {
        contentMode == .fit ? .fit : .fill
    }
}
