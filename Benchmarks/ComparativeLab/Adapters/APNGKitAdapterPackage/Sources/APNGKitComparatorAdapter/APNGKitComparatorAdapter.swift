import APNGKit
import ComparativeLabCore
import Foundation

#if canImport(UIKit)
    import UIKit
#endif

private enum APNGKitComparatorError: Error {
    case unsupportedWorkload
    case unsupportedFormat
    case decodeFailed
    case invalidFrameCount(Int)
    case invalidFrameDuration(Int)
    case invalidFrameGeometry
}

public final class APNGKitComparatorAdapter: ComparatorAnimatedPlayerAdapter, @unchecked Sendable {
    public let identity: ComparatorIdentity

    public init() throws {
        identity = try ComparatorIdentity(
            name: "APNGKit",
            version: "2.4.0",
            exactCommit: "341383f61000e8d2e55d45db0f0756b239d0a2f1"
        )
    }

    public func makeLoad(_ request: ComparatorRequest) async throws -> ComparatorLoad {
        _ = request
        throw APNGKitComparatorError.unsupportedWorkload
    }

    public func purgeMemory() async {}
    public func purgeDisk() async throws {}
    public func revoke(namespace: String) async throws { _ = namespace }
    public func cancelAll() async {}
}

#if canImport(UIKit)
    private final class APNGObservationLayer: CALayer {
        nonisolated(unsafe) var frameSink: ((CGImage, UInt64) -> Void)?

        override var contents: Any? {
            didSet {
                guard let value = contents else { return }
                let cfValue = value as CFTypeRef
                guard CFGetTypeID(cfValue) == CGImage.typeID else { return }
                let frame = unsafeDowncast(cfValue, to: CGImage.self)
                let timestamp = DispatchTime.now().uptimeNanoseconds
                frameSink?(frame, timestamp)
            }
        }
    }

    @MainActor
    private final class APNGBenchmarkView: APNGImageView {
        override class var layerClass: AnyClass { APNGObservationLayer.self }

        var observationLayer: APNGObservationLayer {
            precondition(layer is APNGObservationLayer)
            return layer as! APNGObservationLayer
        }
    }

    private final class APNGKitEventState: @unchecked Sendable {
        private let lock = NSLock()
        private var sequence = 0
        private var lastFrameIndex: Int?

        func next(
            frame: CGImage,
            timestamp: UInt64,
            frameCount: Int
        ) -> ComparatorAnimatedPlayerFrameEvent? {
            guard let frameIndex = Self.sourceFrameIndex(frame: frame, frameCount: frameCount)
            else {
                return nil
            }
            return lock.withLock {
                guard frameIndex != lastFrameIndex else { return nil }
                lastFrameIndex = frameIndex
                defer { sequence += 1 }
                return try? ComparatorAnimatedPlayerFrameEvent(
                    sequence: sequence,
                    monotonicNanoseconds: timestamp,
                    sourceFrameIndex: frameIndex
                )
            }
        }

        private static func sourceFrameIndex(frame: CGImage, frameCount: Int) -> Int? {
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
            context.draw(frame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
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
    }

    @MainActor
    private final class APNGKitPlayerController {
        private let animatedImage: APNGImage
        private let frameCount: Int
        private let window: UIWindow
        private let imageView: APNGBenchmarkView
        private let continuation: AsyncStream<ComparatorAnimatedPlayerFrameEvent>.Continuation
        private let state: APNGKitEventState
        private var stopped = false

        init(
            animatedImage: APNGImage,
            frameCount: Int,
            continuation: AsyncStream<ComparatorAnimatedPlayerFrameEvent>.Continuation,
            state: APNGKitEventState
        ) {
            self.animatedImage = animatedImage
            self.frameCount = frameCount
            self.continuation = continuation
            self.state = state

            let frame = CGRect(origin: .zero, size: animatedImage.size)
            let imageView = APNGBenchmarkView(frame: frame)
            imageView.autoStartAnimationWhenSetImage = false
            imageView.runLoopMode = .common
            imageView.image = animatedImage
            self.imageView = imageView

            let controller = UIViewController()
            controller.view.backgroundColor = .clear
            controller.view.frame = frame
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
        }

        func start() {
            guard !stopped else { return }
            imageView.observationLayer.frameSink = {
                [state, continuation, frameCount] frame, timestamp in
                guard
                    let event = state.next(
                        frame: frame,
                        timestamp: timestamp,
                        frameCount: frameCount
                    )
                else { return }
                continuation.yield(event)
            }
            window.makeKeyAndVisible()
            imageView.image = nil
            imageView.image = animatedImage
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
            imageView.observationLayer.frameSink = nil
            imageView.image = nil
            window.isHidden = true
            window.rootViewController = nil
            continuation.finish()
        }

        isolated deinit {
            imageView.stopAnimating()
            imageView.observationLayer.frameSink = nil
            imageView.image = nil
            window.isHidden = true
            window.rootViewController = nil
            continuation.finish()
        }
    }

    extension APNGKitComparatorAdapter {
        @MainActor
        public func makeAnimatedPlayer(
            _ request: ComparatorAnimatedPlayerRequest
        ) throws -> ComparatorAnimatedPlayerSession {
            guard request.format == .apng else { throw APNGKitComparatorError.unsupportedFormat }
            let image: APNGImage
            do {
                image = try APNGImage(
                    data: request.encodedData,
                    scale: 1,
                    decodingOptions: [.fullFirstPass]
                )
            } catch {
                throw APNGKitComparatorError.decodeFailed
            }
            guard image.numberOfFrames == request.referenceFrameDurationsNanoseconds.count,
                image.numberOfFrames > 1
            else {
                throw APNGKitComparatorError.invalidFrameCount(image.numberOfFrames)
            }
            guard image.size.width > 0, image.size.height > 0 else {
                throw APNGKitComparatorError.invalidFrameGeometry
            }

            let pair = AsyncStream<ComparatorAnimatedPlayerFrameEvent>.makeStream(
                bufferingPolicy: .bufferingNewest(4_096)
            )
            let state = APNGKitEventState()
            let controller = APNGKitPlayerController(
                animatedImage: image,
                frameCount: image.numberOfFrames,
                continuation: pair.continuation,
                state: state
            )
            guard image.loadedFrames.count == image.numberOfFrames else {
                controller.stop()
                throw APNGKitComparatorError.invalidFrameCount(image.loadedFrames.count)
            }

            var durations: [UInt64] = []
            durations.reserveCapacity(image.numberOfFrames)
            for (index, frame) in image.loadedFrames.enumerated() {
                let numerator = UInt64(frame.frameControl.delayNumerator)
                let denominator = UInt64(
                    frame.frameControl.delayDenominator == 0
                        ? 100 : frame.frameControl.delayDenominator
                )
                let product = numerator.multipliedReportingOverflow(by: 1_000_000_000)
                guard !product.overflow, denominator > 0 else {
                    controller.stop()
                    throw APNGKitComparatorError.invalidFrameDuration(index)
                }
                let quotient = product.partialValue / denominator
                let remainder = product.partialValue % denominator
                let rounded = quotient + (remainder >= (denominator + 1) / 2 ? 1 : 0)
                guard rounded > 0 else {
                    controller.stop()
                    throw APNGKitComparatorError.invalidFrameDuration(index)
                }
                durations.append(rounded)
            }

            pair.continuation.onTermination = { @Sendable _ in
                Task { @MainActor in controller.stop() }
            }
            return try ComparatorAnimatedPlayerSession(
                sourceFrameDurationsNanoseconds: durations,
                sourceLoopCount: UInt(image.numberOfPlays ?? 0),
                inputPath: .encodedNative,
                events: pair.stream,
                start: { controller.start() },
                pause: { controller.pause() },
                stop: { controller.stop() }
            )
        }
    }
#endif
