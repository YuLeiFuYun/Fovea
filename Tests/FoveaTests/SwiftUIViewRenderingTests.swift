import FoveaCore
import FoveaSwiftUI
import ImageCraftCore
import ImageCraftImageIO
import SwiftUI
import XCTest

@MainActor
final class SwiftUIViewRenderingTests: XCTestCase {
    func testPhaseContentDefersPlaceholderUntilLoading_UI_PT_019() {
        var emptyPlaceholderBuilds = 0
        let empty = FoveaImagePhaseContent(
            phase: .empty,
            accessibility: .decorative
        ) {
            emptyPlaceholderBuilds += 1
            return Color.clear
        } failure: { _ in
            XCTFail("空状态不得构造 failure view")
            return Color.clear
        } retryAction: {
            XCTFail("空状态不得触发 retry")
        }
        _ = empty.body
        XCTAssertEqual(emptyPlaceholderBuilds, 0)

        for phase in [FoveaImagePhase.loading, .cancelled] {
            var placeholderBuilds = 0
            let content = FoveaImagePhaseContent(
                phase: phase,
                accessibility: .decorative
            ) {
                placeholderBuilds += 1
                return Color.clear
            } failure: { _ in
                XCTFail("非失败阶段不得构造 failure view")
                return Color.clear
            } retryAction: {
                XCTFail("非失败阶段不得触发 retry")
            }

            _ = content.body
            XCTAssertEqual(placeholderBuilds, 1)
        }
    }

    func testPhaseContentBuildsDecorativeAndLabeledImages_UI_PT_019() throws {
        let image = try renderedDecodedImage()

        let decorative = FoveaImagePhaseContent(
            phase: .success(image),
            accessibility: .decorative
        ) {
            XCTFail("成功阶段不得构造 placeholder")
            return EmptyView()
        } failure: { _ in
            XCTFail("成功阶段不得构造 failure view")
            return EmptyView()
        } retryAction: {
        }
        _ = decorative.body

        let labeled = FoveaImagePhaseContent(
            phase: .preview(image),
            accessibility: .label(Text("用户头像"))
        ) {
            XCTFail("预览阶段不得构造 placeholder")
            return EmptyView()
        } failure: { _ in
            XCTFail("预览阶段不得构造 failure view")
            return EmptyView()
        } retryAction: {
        }
        _ = labeled.body
    }

    func testPreviewAndFinalVisibilityCallbacksRemainDistinct_UI_PT_024() throws {
        guard #available(macOS 13.0, iOS 16.0, *) else { return }
        let image = try renderedDecodedImage()
        var previewAppearances = 0
        var finalAppearances = 0

        let preview = FoveaImagePhaseContent(
            phase: .preview(image),
            accessibility: .decorative
        ) {
            EmptyView()
        } failure: { _ in
            EmptyView()
        } retryAction: {
        } previewAppeared: {
            previewAppearances += 1
        } successAppeared: {
            finalAppearances += 1
        }
        XCTAssertNotNil(render(view: preview))
        XCTAssertEqual(previewAppearances, 1)
        XCTAssertEqual(finalAppearances, 0)

        let final = FoveaImagePhaseContent(
            phase: .success(image),
            accessibility: .decorative
        ) {
            EmptyView()
        } failure: { _ in
            EmptyView()
        } retryAction: {
        } previewAppeared: {
            previewAppearances += 1
        } successAppeared: {
            finalAppearances += 1
        }
        XCTAssertNotNil(render(view: final))
        XCTAssertEqual(previewAppearances, 1)
        XCTAssertEqual(finalAppearances, 1)
    }

    func testPhaseContentBuildsFailureContextAndRetryAction_UI_PT_019() {
        let pipelineFailure = PipelineFailure(
            category: .transport,
            stage: .transport,
            disposition: .retryable,
            reasonCode: "transport-failed"
        )
        var receivedFailure: PipelineFailure?
        var receivedRecovery: FoveaImageRecoveryAction?
        var retryCount = 0
        let content = FoveaImagePhaseContent(
            phase: .failure(pipelineFailure),
            accessibility: .decorative
        ) {
            XCTFail("失败阶段不得构造 placeholder")
            return EmptyView()
        } failure: { context in
            receivedFailure = context.failure
            receivedRecovery = context.recoveryAction
            context.retry()
            return EmptyView()
        } retryAction: {
            retryCount += 1
        }

        _ = content.body

        XCTAssertEqual(receivedFailure, pipelineFailure)
        XCTAssertEqual(receivedRecovery, .retry)
        XCTAssertEqual(retryCount, 1)
    }

    func testPublicFoveaImageBodyBuildsLifecycleModifiers_UI_PT_019() throws {
        let view = FoveaImage(
            request: try renderedRequest(),
            loader: RenderingImageLoader(image: try renderedDecodedImage()),
            accessibility: .decorative,
            loadingPolicy: FoveaImageLoadingPolicy(placeholderDelayNanoseconds: 0),
            transitionPolicy: FoveaImageTransitionPolicy(opacityDuration: 0.15)
        ) {
            ProgressView()
        } failure: { _ in
            EmptyView()
        }

        guard #available(macOS 13.0, iOS 16.0, *) else { return }
        let renderer = ImageRenderer(content: view.frame(width: 80, height: 80))
        renderer.proposedSize = ProposedViewSize(width: 80, height: 80)
        XCTAssertNotNil(renderer.cgImage)
    }

    func testPhaseContentPreservesFitAndFillAspectSemantics_UI_PT_021() throws {
        guard #available(macOS 13.0, iOS 16.0, *) else { return }
        let image = try wideDecodedImage()

        let fit = FoveaImagePhaseContent(
            phase: .success(image),
            accessibility: .decorative,
            contentMode: .fit
        ) {
            EmptyView()
        } failure: { _ in
            EmptyView()
        } retryAction: {
        }

        let fill = FoveaImagePhaseContent(
            phase: .success(image),
            accessibility: .decorative,
            contentMode: .fill
        ) {
            EmptyView()
        } failure: { _ in
            EmptyView()
        } retryAction: {
        }

        let fitImage = try XCTUnwrap(render(view: fit))
        let fillImage = try XCTUnwrap(render(view: fill))

        XCTAssertEqual(alpha(in: fitImage, x: 50, y: 5), 0)
        XCTAssertGreaterThan(alpha(in: fillImage, x: 50, y: 5), 0)
    }

    func testResponsiveImageBodyBuildsGeometryLifecycle_UI_PT_019() throws {
        let view = FoveaResponsiveImage(
            loader: RenderingImageLoader(image: try renderedDecodedImage()),
            accessibility: .decorative,
            contentMode: .fill,
            geometryIsStable: true
        ) { target in
            try ImageRequest.publicImage(
                url: XCTUnwrap(URL(string: "https://example.test/responsive-rendering.png")),
                resolvedTarget: target,
                appID: "swiftui-rendering-tests"
            )
        } placeholder: {
            ProgressView()
        } failure: { _ in
            EmptyView()
        }

        guard #available(macOS 13.0, iOS 16.0, *) else { return }
        let renderer = ImageRenderer(content: view.frame(width: 80, height: 80))
        renderer.proposedSize = ProposedViewSize(width: 80, height: 80)
        XCTAssertNotNil(renderer.cgImage)
    }
}

private struct RenderingImageLoader: ImageLoading {
    let image: DecodedImage

    func image(for request: ImageRequest) async throws -> DecodedImage { image }
}

private func renderedRequest() throws -> ImageRequest {
    try ImageRequest.publicImage(
        url: XCTUnwrap(URL(string: "https://example.test/swiftui-rendering.png")),
        target: TargetPixels(width: 20, height: 20),
        appID: "swiftui-rendering-tests"
    )
}

@MainActor
private func render<V: View>(view: V) -> CGImage? {
    if #available(macOS 13.0, iOS 16.0, *) {
        let renderer = ImageRenderer(
            content:
                view
                .frame(width: 100, height: 100)
                .clipped()
        )
        renderer.proposedSize = ProposedViewSize(width: 100, height: 100)
        renderer.scale = 1
        return renderer.cgImage
    }
    return nil
}

private func alpha(in image: CGImage, x: Int, y: Int) -> UInt8 {
    var bytes = [UInt8](repeating: 0, count: 100 * 100 * 4)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let address = buffer.baseAddress,
            let context = CGContext(
                data: address,
                width: 100,
                height: 100,
                bitsPerComponent: 8,
                bytesPerRow: 400,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        return true
    }
    guard rendered else { return 0 }
    return bytes[(y * 100 + x) * 4 + 3]
}

private func wideDecodedImage() throws -> DecodedImage {
    try ImageIOImageDecoder().decode(
        data: makePNG(width: 40, height: 20),
        target: TargetPixels(width: 40, height: 20)
    )
}

private func renderedDecodedImage() throws -> DecodedImage {
    try ImageIOImageDecoder().decode(
        data: makePNG(width: 20, height: 20),
        target: TargetPixels(width: 20, height: 20)
    )
}
