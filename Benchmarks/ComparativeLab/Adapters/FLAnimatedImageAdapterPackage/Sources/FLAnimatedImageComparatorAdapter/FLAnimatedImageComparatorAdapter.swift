import ComparativeLabCore
import FLAnimatedImage
import FLAnimatedImageBenchmarkShim
import Foundation

#if canImport(UIKit)
    import UIKit
#endif

private enum FLAnimatedImageComparatorError: Error {
    case unsupportedWorkload
    case unsupportedFormat
    case decodeFailed
    case invalidFrameCount(Int)
    case missingFrameDuration(Int)
    case invalidFrameDuration(Int)
}

public final class FLAnimatedImageComparatorAdapter: ComparatorAnimatedPlayerAdapter,
    @unchecked Sendable
{
    public let identity: ComparatorIdentity

    public init() throws {
        identity = try ComparatorIdentity(
            name: "FLAnimatedImage",
            version: "1.0.17",
            exactCommit: "d4f07b6f164d53c1212c3e54d6460738b1981e9f"
        )
    }

    public func makeLoad(_ request: ComparatorRequest) async throws -> ComparatorLoad {
        _ = request
        throw FLAnimatedImageComparatorError.unsupportedWorkload
    }

    public func purgeMemory() async {}

    public func purgeDisk() async throws {}

    public func revoke(namespace: String) async throws {
        _ = namespace
    }

    public func cancelAll() async {}
}

#if canImport(UIKit)
    private func flAnimatedSourceFrameIndex(image: UIImage, frameCount: Int) -> Int? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard
            let context = CGContext(
                data: &pixel,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            )
        else { return nil }
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let red = Int(pixel[0])
        let green = Int(pixel[1])
        let blue = Int(pixel[2])
        let index = ((red - 17 + 256) * 173) % 256
        guard index < frameCount,
            green == (index * 73 + 29) % 256,
            blue == (index * 109 + 43) % 256
        else { return nil }
        return index
    }

    private final class FLAnimatedEventState: @unchecked Sendable {
        private let lock = NSLock()
        private var sequence = 0

        func next(frameIndex: Int, timestamp: UInt64) -> ComparatorAnimatedPlayerFrameEvent? {
            lock.withLock {
                defer { sequence += 1 }
                return try? ComparatorAnimatedPlayerFrameEvent(
                    sequence: sequence,
                    monotonicNanoseconds: timestamp,
                    sourceFrameIndex: frameIndex
                )
            }
        }
    }

    @MainActor
    private final class FLAnimatedPlayerController {
        private let window: UIWindow
        private let imageView: FoveaFLAnimatedImageBenchmarkView
        private let continuation: AsyncStream<ComparatorAnimatedPlayerFrameEvent>.Continuation
        private let state: FLAnimatedEventState
        private let frameCount: Int
        private var lastRecordedFrameIndex: Int?
        private var stopped = false

        init(
            animatedImage: FLAnimatedImage,
            maximumFrameBufferBytes: Int,
            continuation: AsyncStream<ComparatorAnimatedPlayerFrameEvent>.Continuation,
            state: FLAnimatedEventState
        ) {
            let frame = CGRect(
                x: 0,
                y: 0,
                width: max(1, animatedImage.size.width),
                height: max(1, animatedImage.size.height)
            )
            let imageView = FoveaFLAnimatedImageBenchmarkView(frame: frame)
            imageView.runLoopMode = .common
            let width = max(
                1, Int(animatedImage.posterImage.size.width * animatedImage.posterImage.scale))
            let height = max(
                1, Int(animatedImage.posterImage.size.height * animatedImage.posterImage.scale))
            let frameBytes = max(1, width * height * 4)
            imageView.animatedImage = animatedImage
            animatedImage.frameCacheSizeMax = UInt(
                min(Int(animatedImage.frameCount), max(1, maximumFrameBufferBytes / frameBytes))
            )
            imageView.stopAnimating()
            let controller = UIViewController()
            controller.view.backgroundColor = .clear
            controller.view.addSubview(imageView)
            let window: UIWindow
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first
            {
                window = UIWindow(windowScene: scene)
                window.frame = frame
            } else {
                window = UIWindow(frame: frame)
            }
            window.rootViewController = controller
            window.isHidden = true

            self.window = window
            self.imageView = imageView
            self.continuation = continuation
            self.state = state
            self.frameCount = Int(animatedImage.frameCount)
        }

        func start() {
            guard !stopped else { return }
            lastRecordedFrameIndex = nil
            imageView.frameDisplayBlock = { [weak self] frame in
                guard let self, !self.stopped else { return }
                let timestamp = DispatchTime.now().uptimeNanoseconds
                guard
                    let frameIndex = flAnimatedSourceFrameIndex(
                        image: frame,
                        frameCount: self.frameCount
                    ), frameIndex != self.lastRecordedFrameIndex
                else { return }
                self.lastRecordedFrameIndex = frameIndex
                guard let event = self.state.next(frameIndex: frameIndex, timestamp: timestamp)
                else { return }
                self.continuation.yield(event)
            }
            window.makeKeyAndVisible()
            imageView.startAnimating()
        }

        func pause() {
            guard !stopped else { return }
            imageView.stopAnimating()
        }

        func stop() {
            guard !stopped else { return }
            stopped = true
            imageView.stopAnimating()
            imageView.frameDisplayBlock = nil
            lastRecordedFrameIndex = nil
            imageView.animatedImage = nil
            window.isHidden = true
            window.rootViewController = nil
            continuation.finish()
        }

        isolated deinit {
            imageView.stopAnimating()
            imageView.frameDisplayBlock = nil
            lastRecordedFrameIndex = nil
            imageView.animatedImage = nil
            window.isHidden = true
            window.rootViewController = nil
            continuation.finish()
        }
    }

    extension FLAnimatedImageComparatorAdapter {
        @MainActor
        public func makeAnimatedPlayer(
            _ request: ComparatorAnimatedPlayerRequest
        ) throws -> ComparatorAnimatedPlayerSession {
            guard request.format == .gif else {
                throw FLAnimatedImageComparatorError.unsupportedFormat
            }
            guard let animatedImage = FLAnimatedImage(animatedGIFData: request.encodedData) else {
                throw FLAnimatedImageComparatorError.decodeFailed
            }
            let frameCount = Int(animatedImage.frameCount)
            guard frameCount > 1 else {
                throw FLAnimatedImageComparatorError.invalidFrameCount(frameCount)
            }
            var durations: [UInt64] = []
            durations.reserveCapacity(frameCount)
            for index in 0..<frameCount {
                guard
                    let value = animatedImage.delayTimesForIndexes[NSNumber(value: index)]
                        as? NSNumber
                else {
                    throw FLAnimatedImageComparatorError.missingFrameDuration(index)
                }
                do {
                    durations.append(
                        try ComparatorAnimatedDurationNormalization.gifCentisecondNanoseconds(
                            seconds: value.doubleValue
                        )
                    )
                } catch {
                    throw FLAnimatedImageComparatorError.invalidFrameDuration(index)
                }
            }

            let pair = AsyncStream<ComparatorAnimatedPlayerFrameEvent>.makeStream(
                bufferingPolicy: .bufferingNewest(4_096)
            )
            let state = FLAnimatedEventState()
            let controller = FLAnimatedPlayerController(
                animatedImage: animatedImage,
                maximumFrameBufferBytes: request.maximumFrameBufferBytes,
                continuation: pair.continuation,
                state: state
            )
            pair.continuation.onTermination = { @Sendable _ in
                Task { @MainActor in controller.stop() }
            }
            return try ComparatorAnimatedPlayerSession(
                sourceFrameDurationsNanoseconds: durations,
                sourceLoopCount: UInt(animatedImage.loopCount),
                inputPath: .encodedNative,
                events: pair.stream,
                start: { controller.start() },
                pause: { controller.pause() },
                stop: { controller.stop() }
            )
        }
    }
#endif
