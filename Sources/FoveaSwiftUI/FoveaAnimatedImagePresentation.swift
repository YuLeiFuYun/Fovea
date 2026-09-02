import Foundation
import FoveaCore
import ImageCraftCore

/// SwiftUI 动画展示使用的类型擦除 handle；只桥接像素、可见性和取消，不拥有解码策略。
package struct FoveaAnimatedImagePresentation: Identifiable, Sendable {
    package typealias OutputHandler = @Sendable (DecodedImage) async -> Void
    package typealias FailureHandler = @Sendable (any Error) async -> Void

    package let id: UUID
    private let startOperation:
        @Sendable (
            @escaping OutputHandler,
            @escaping FailureHandler,
            Bool
        ) async throws -> Void
    private let visibilityOperation: @Sendable (Bool) async throws -> Void
    private let cancelOperation: @Sendable () async -> Void

    package init(animationHandle: AnimationPlaybackHandle) {
        id = animationHandle.identifier
        startOperation = { output, failure, initiallyVisible in
            try await animationHandle.start(
                output: { value in
                    guard let image = value.image else { return }
                    await output(image)
                },
                failure: failure,
                initiallyVisible: initiallyVisible
            )
        }
        visibilityOperation = { visible in
            try await animationHandle.setVisible(visible)
        }
        cancelOperation = { await animationHandle.cancel() }
    }

    package init(liveHandle: MultipartJPEGLivePlaybackHandle) {
        id = liveHandle.identifier
        startOperation = { output, failure, initiallyVisible in
            try await liveHandle.start(
                output: { value in await output(value.image) },
                failure: failure,
                initiallyVisible: initiallyVisible
            )
        }
        visibilityOperation = { visible in
            await liveHandle.setVisible(visible)
        }
        cancelOperation = { await liveHandle.cancel() }
    }

    package func start(
        output: @escaping OutputHandler,
        failure: @escaping FailureHandler,
        initiallyVisible: Bool
    ) async throws {
        try await startOperation(output, failure, initiallyVisible)
    }

    package func setVisible(_ visible: Bool) async throws {
        try await visibilityOperation(visible)
    }

    package func cancel() async {
        await cancelOperation()
    }
}
