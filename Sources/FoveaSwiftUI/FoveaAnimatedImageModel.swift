import Foundation
import FoveaCore
import ImageCraftCore
import SwiftUI

package enum FoveaAnimatedImagePhase {
    case empty
    case image(DecodedImage)
    case failure(String)
}

package final class FoveaSwiftUIVisibilitySequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    package init() {}

    package func submit(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        lock.lock()
        let previous = tail
        let next = Task { [previous] in
            if let previous { await previous.value }
            guard !Task.isCancelled else { return }
            await operation()
        }
        previous?.cancel()
        tail = next
        lock.unlock()
    }

    package func cancel() {
        lock.lock()
        let pending = tail
        tail = nil
        lock.unlock()
        pending?.cancel()
    }

    package func waitUntilDrainedForTesting() async {
        let pending = currentTail()
        await pending?.value
    }

    private func currentTail() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }
}

/// SwiftUI 动画展示状态机。每次 presentation 替换都会推进 generation，旧 handle 的迟到像素
/// 和失败都不能覆盖新身份；视图消失仅暂停，显式替换或模型释放才取消底层会话。
@MainActor
package final class FoveaAnimatedImageModel: ObservableObject {
    @Published package private(set) var phase: FoveaAnimatedImagePhase = .empty
    package private(set) var presentationID: UUID?

    private var presentationGeneration = UUID()
    private var presentation: FoveaAnimatedImagePresentation?
    private var startTask: Task<Void, Never>?
    private let visibilitySequencer = FoveaSwiftUIVisibilitySequencer()

    package init() {}

    deinit {
        startTask?.cancel()
        visibilitySequencer.cancel()
        if let presentation { Task { await presentation.cancel() } }
    }

    package func present(
        _ next: FoveaAnimatedImagePresentation,
        initiallyVisible: Bool
    ) {
        if presentationID == next.id, presentation != nil {
            setVisible(initiallyVisible)
            return
        }
        cancelCurrent(clearImage: false)
        let generation = UUID()
        presentationGeneration = generation
        presentationID = next.id
        presentation = next
        startTask = Task { [weak self] in
            do {
                try await next.start(
                    output: { [weak self] image in
                        await self?.publish(image, generation: generation)
                    },
                    failure: { [weak self] error in
                        await self?.publishFailure(error, generation: generation)
                    },
                    initiallyVisible: initiallyVisible
                )
            } catch is CancellationError {
                return
            } catch {
                self?.publishFailure(error, generation: generation)
            }
        }
    }

    package func setVisible(_ visible: Bool) {
        guard let presentation else { return }
        let generation = presentationGeneration
        visibilitySequencer.submit { [weak self] in
            guard let self, generation == self.presentationGeneration else { return }
            do {
                try await presentation.setVisible(visible)
            } catch is CancellationError {
                return
            } catch {
                self.publishFailure(error, generation: generation)
            }
        }
    }

    package func cancel(clearImage: Bool = false) {
        cancelCurrent(clearImage: clearImage)
    }

    private func cancelCurrent(clearImage: Bool) {
        presentationGeneration = UUID()
        presentationID = nil
        startTask?.cancel()
        startTask = nil
        visibilitySequencer.cancel()
        let old = presentation
        presentation = nil
        if clearImage { phase = .empty }
        if let old { Task { await old.cancel() } }
    }

    private func publish(_ image: DecodedImage, generation: UUID) {
        guard generation == presentationGeneration else { return }
        phase = .image(image)
    }

    private func publishFailure(_ error: any Error, generation: UUID) {
        guard generation == presentationGeneration else { return }
        let typeName = String(reflecting: type(of: error))
        phase = .failure(typeName)
    }
}
