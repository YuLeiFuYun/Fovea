import FoveaCore
import ImageCraftCore
import SwiftUI

/// package-internal SwiftUI 动画展示。公开/default FoveaImage 静态与渐进 API 不受影响。
@MainActor
package struct FoveaAnimatedImage<Placeholder: View, Failure: View>: View {
    private let presentation: FoveaAnimatedImagePresentation
    private let accessibility: FoveaImageAccessibility
    private let contentMode: ImageContentMode
    private let placeholder: () -> Placeholder
    private let failure: (String) -> Failure
    @StateObject private var model = FoveaAnimatedImageModel()
    @State private var isVisible = false

    package init(
        presentation: FoveaAnimatedImagePresentation,
        accessibility: FoveaImageAccessibility,
        contentMode: ImageContentMode = .fit,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping (String) -> Failure
    ) {
        self.presentation = presentation
        self.accessibility = accessibility
        self.contentMode = contentMode
        self.placeholder = placeholder
        self.failure = failure
    }

    package var body: some View {
        content
            .onAppear {
                isVisible = true
                model.present(presentation, initiallyVisible: true)
            }
            .onDisappear {
                isVisible = false
                model.setVisible(false)
            }
            .onChange(of: presentation.id) { _ in
                model.present(presentation, initiallyVisible: isVisible)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .empty:
            placeholder()
        case .image(let decoded):
            renderedImage(decoded)
        case .failure(let reason):
            failure(reason)
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
