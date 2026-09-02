import ComparativeLabCore
import Foundation
import Gifu
import ImageIO

#if canImport(UIKit)
    import UIKit
#endif

private enum GifuComparatorError: Error {
    case unsupportedWorkload
    case unsupportedFormat
    case decodeFailed
    case invalidFrameCount(Int)
    case invalidFrameDuration(Int)
    case loopDurationMismatch
}

public final class GifuComparatorAdapter: ComparatorAnimatedPlayerAdapter, @unchecked Sendable {
    public let identity: ComparatorIdentity

    public init() throws {
        identity = try ComparatorIdentity(
            name: "Gifu",
            version: "retained-672a8d4",
            exactCommit: "672a8d4fea3faf234518be2db00815936e55f85f"
        )
    }

    public func makeLoad(_ request: ComparatorRequest) async throws -> ComparatorLoad {
        _ = request
        throw GifuComparatorError.unsupportedWorkload
    }

    public func purgeMemory() async {}
    public func purgeDisk() async throws {}
    public func revoke(namespace: String) async throws { _ = namespace }
    public func cancelAll() async {}
}

#if canImport(UIKit)
    @MainActor
    private final class GifuBenchmarkView: UIImageView, GIFAnimatable {
        lazy var animator: Animator? = Animator(withDelegate: self)
        var eventSink: ((Int, UInt64) -> Void)?
        private var recording = false
        private var lastRecordedFrameIndex: Int?
        private let sourceFrameCount: Int

        init(frame: CGRect, sourceFrameCount: Int) {
            self.sourceFrameCount = sourceFrameCount
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) {
            fatalError("Gifu comparator does not support NSCoder")
        }

        override func display(_ layer: CALayer) {
            if UIImageView.instancesRespond(to: #selector(display(_:))) {
                super.display(layer)
            }
            updateImageIfNeeded()
            guard recording else { return }
            let timestamp = DispatchTime.now().uptimeNanoseconds
            guard let image,
                let frameIndex = Self.sourceFrameIndex(image: image, frameCount: sourceFrameCount),
                frameIndex != lastRecordedFrameIndex
            else { return }
            lastRecordedFrameIndex = frameIndex
            eventSink?(frameIndex, timestamp)
        }

        func beginRecording() {
            recording = true
            lastRecordedFrameIndex = nil
            setNeedsDisplay()
            layer.setNeedsDisplay()
        }

        func endRecording() {
            recording = false
            lastRecordedFrameIndex = nil
        }

        private static func sourceFrameIndex(image: UIImage, frameCount: Int) -> Int? {
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
    }

    private final class GifuEventState: @unchecked Sendable {
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
    private final class GifuPlayerController {
        private let window: UIWindow
        private let imageView: GifuBenchmarkView
        private let encodedData: Data
        private let frameCount: Int
        private let expectedLoopDurationSeconds: Double
        private let maximumFrameBufferBytes: Int
        private let continuation: AsyncStream<ComparatorAnimatedPlayerFrameEvent>.Continuation
        private let state: GifuEventState
        private var stopped = false
        private var prepared = false

        init(
            encodedData: Data,
            frameCount: Int,
            pixelSize: CGSize,
            expectedLoopDurationSeconds: Double,
            maximumFrameBufferBytes: Int,
            continuation: AsyncStream<ComparatorAnimatedPlayerFrameEvent>.Continuation,
            state: GifuEventState
        ) {
            self.encodedData = encodedData
            self.frameCount = frameCount
            self.expectedLoopDurationSeconds = expectedLoopDurationSeconds
            self.maximumFrameBufferBytes = maximumFrameBufferBytes
            self.continuation = continuation
            self.state = state

            let frame = CGRect(origin: .zero, size: pixelSize)
            let imageView = GifuBenchmarkView(frame: frame, sourceFrameCount: frameCount)
            imageView.contentMode = .scaleToFill
            imageView.setShouldResizeFrames(false)
            let frameBytes = max(1, Int(pixelSize.width) * Int(pixelSize.height) * 4)
            imageView.setFrameBufferSize(
                min(frameCount, max(1, maximumFrameBufferBytes / frameBytes)))
            imageView.stopAnimatingGIF()
            imageView.eventSink = { frameIndex, timestamp in
                guard let event = state.next(frameIndex: frameIndex, timestamp: timestamp) else {
                    return
                }
                continuation.yield(event)
            }
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

        func start() throws {
            guard !stopped else { return }
            if !prepared {
                imageView.prepareForAnimation(withGIFData: encodedData, loopCount: 0)
                guard imageView.frameCount == frameCount else {
                    throw GifuComparatorError.invalidFrameCount(imageView.frameCount)
                }
                guard abs(imageView.gifLoopDuration - expectedLoopDurationSeconds) <= 0.001 else {
                    throw GifuComparatorError.loopDurationMismatch
                }
                prepared = true
            }
            imageView.beginRecording()
            window.makeKeyAndVisible()
            imageView.startAnimatingGIF()
        }

        func pause() {
            guard !stopped else { return }
            imageView.stopAnimatingGIF()
        }

        func stop() {
            guard !stopped else { return }
            stopped = true
            imageView.stopAnimatingGIF()
            imageView.endRecording()
            imageView.eventSink = nil
            imageView.prepareForReuse()
            window.isHidden = true
            window.rootViewController = nil
            continuation.finish()
        }

        isolated deinit {
            imageView.stopAnimatingGIF()
            imageView.endRecording()
            imageView.eventSink = nil
            imageView.prepareForReuse()
            window.isHidden = true
            window.rootViewController = nil
            continuation.finish()
        }
    }

    extension GifuComparatorAdapter {
        @MainActor
        public func makeAnimatedPlayer(
            _ request: ComparatorAnimatedPlayerRequest
        ) throws -> ComparatorAnimatedPlayerSession {
            guard request.format == .gif else { throw GifuComparatorError.unsupportedFormat }
            guard
                let source = CGImageSourceCreateWithData(request.encodedData as CFData, nil),
                CGImageSourceGetCount(source) > 1
            else { throw GifuComparatorError.decodeFailed }
            let frameCount = CGImageSourceGetCount(source)
            guard frameCount == request.referenceFrameDurationsNanoseconds.count else {
                throw GifuComparatorError.invalidFrameCount(frameCount)
            }
            guard
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0,
                height > 0
            else { throw GifuComparatorError.decodeFailed }

            var durations: [UInt64] = []
            durations.reserveCapacity(frameCount)
            for index in 0..<frameCount {
                guard
                    let frameProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                        as? [CFString: Any],
                    let gif = frameProperties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                else { throw GifuComparatorError.invalidFrameDuration(index) }
                let unclamped = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?
                    .doubleValue
                let clamped = (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
                let rawDuration: Double
                if let unclamped, let clamped, unclamped >= 0, clamped >= 0 {
                    rawDuration = unclamped
                } else {
                    rawDuration = 1.0 / 15.0
                }
                let effective = rawDuration < (0.02 - Double.ulpOfOne) ? 0.1 : rawDuration
                do {
                    durations.append(
                        try ComparatorAnimatedDurationNormalization.gifCentisecondNanoseconds(
                            seconds: effective
                        )
                    )
                } catch {
                    throw GifuComparatorError.invalidFrameDuration(index)
                }
            }

            let pair = AsyncStream<ComparatorAnimatedPlayerFrameEvent>.makeStream(
                bufferingPolicy: .bufferingNewest(4_096)
            )
            let state = GifuEventState()
            let controller = GifuPlayerController(
                encodedData: request.encodedData,
                frameCount: frameCount,
                pixelSize: CGSize(width: width, height: height),
                expectedLoopDurationSeconds: Double(durations.reduce(0, +)) / 1_000_000_000,
                maximumFrameBufferBytes: request.maximumFrameBufferBytes,
                continuation: pair.continuation,
                state: state
            )
            pair.continuation.onTermination = { @Sendable _ in
                Task { @MainActor in controller.stop() }
            }
            return try ComparatorAnimatedPlayerSession(
                sourceFrameDurationsNanoseconds: durations,
                sourceLoopCount: 0,
                inputPath: .encodedNative,
                events: pair.stream,
                start: { try controller.start() },
                pause: { controller.pause() },
                stop: { controller.stop() }
            )
        }
    }
#endif
