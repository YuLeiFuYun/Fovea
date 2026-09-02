import AnimatedImage
import ComparativeLabCore
import Foundation
import ImageIO

#if canImport(UIKit)
    import UIKit
#endif

private enum AnimatedImageComparatorError: Error {
    case unsupportedWorkload
    case unsupportedFormat
    case invalidFrameCount
    case invalidFrameGeometry
    case invalidReferenceTimeline
    case preparationFailed
    case effectiveTimelineMismatch
}

/// W5-only adapter for AnimatedImage 0.2.4.
///
/// The retained comparator's `AnimatedImageState` advances all selected frames with a single
/// uniform delay. With maxLevelOfIntegrity=1 every source frame is retained, so the effective
/// player timeline is the first decoded GIF delay repeated for every frame. Reporting that
/// effective timeline (rather than the encoded source metadata) makes the primary variable-delay
/// W5 semantic gate fail closed while permitting a separate uniform-delay mechanism fixture.
public final class AnimatedImageComparatorAdapter: ComparatorAnimatedPlayerAdapter,
    @unchecked Sendable
{
    public let identity: ComparatorIdentity

    public init() throws {
        identity = try ComparatorIdentity(
            name: "AnimatedImage",
            version: "0.2.4",
            exactCommit: "d64237a33ce91b0513dd850589fea32fa28f4f80"
        )
    }

    public func makeLoad(_ request: ComparatorRequest) async throws -> ComparatorLoad {
        _ = request
        throw AnimatedImageComparatorError.unsupportedWorkload
    }

    public func purgeMemory() async {}

    public func purgeDisk() async throws {}

    public func revoke(namespace: String) async throws {
        _ = namespace
    }

    public func cancelAll() async {}
}

#if canImport(UIKit)
    @MainActor
    private final class AnimatedImageBenchmarkView: AnimatedImageView {
        var observedImage: AnimatedImage?
        var eventSink: ((Int, UInt64, UInt64) -> Void)?
        private var isRecording = false
        private var lastRecordedFrameIndex: Int?

        func beginRecording() {
            isRecording = true
            lastRecordedFrameIndex = nil
        }

        func endRecording() {
            isRecording = false
            lastRecordedFrameIndex = nil
        }

        override func updateContents(for targetTimestamp: TimeInterval) {
            let callbackStarted = DispatchTime.now().uptimeNanoseconds
            let frameIndex = observedImage?.index(for: targetTimestamp)
            super.updateContents(for: targetTimestamp)
            guard isRecording,
                let frameIndex,
                frameIndex != lastRecordedFrameIndex,
                contents != nil
            else { return }
            lastRecordedFrameIndex = frameIndex
            let submitted = DispatchTime.now().uptimeNanoseconds
            eventSink?(frameIndex, submitted, submitted &- callbackStarted)
        }
    }

    private final class AnimatedImageEventState: @unchecked Sendable {
        private let lock = NSLock()
        private var sequence = 0

        func next(
            frameIndex: Int,
            timestamp: UInt64,
            callbackNanoseconds: UInt64
        ) -> ComparatorAnimatedPlayerFrameEvent? {
            lock.withLock {
                defer { sequence += 1 }
                return try? ComparatorAnimatedPlayerFrameEvent(
                    sequence: sequence,
                    monotonicNanoseconds: timestamp,
                    sourceFrameIndex: frameIndex,
                    mainThreadCallbackNanoseconds: callbackNanoseconds
                )
            }
        }
    }

    @MainActor
    private final class AnimatedImagePlayerController {
        private let sourceImage: AnimatedImage
        private let frameCount: Int
        private let size: CGSize
        private let effectiveFrameDurationSeconds: TimeInterval
        private let window: UIWindow
        private let imageView: AnimatedImageBenchmarkView
        private let continuation: AsyncStream<ComparatorAnimatedPlayerFrameEvent>.Continuation
        private var stopped = false
        private var preparedImage: AnimatedImage?

        init(
            sourceImage: AnimatedImage,
            frameCount: Int,
            size: CGSize,
            effectiveFrameDurationSeconds: TimeInterval,
            continuation: AsyncStream<ComparatorAnimatedPlayerFrameEvent>.Continuation,
            state: AnimatedImageEventState
        ) {
            self.sourceImage = sourceImage
            self.frameCount = frameCount
            self.size = size
            self.effectiveFrameDurationSeconds = effectiveFrameDurationSeconds
            self.continuation = continuation

            let imageView = AnimatedImageBenchmarkView(
                frame: CGRect(origin: .zero, size: size)
            )
            imageView.adjustAnimatedImageForSize = false
            imageView.contentMode = .scaleToFill
            imageView.eventSink = { frameIndex, timestamp, callbackNanoseconds in
                guard
                    let event = state.next(
                        frameIndex: frameIndex,
                        timestamp: timestamp,
                        callbackNanoseconds: callbackNanoseconds
                    )
                else { return }
                continuation.yield(event)
            }
            self.imageView = imageView

            let controller = UIViewController()
            controller.view.backgroundColor = .clear
            controller.view.frame = CGRect(origin: .zero, size: size)
            controller.view.addSubview(imageView)
            let window: UIWindow
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first
            {
                window = UIWindow(windowScene: scene)
                window.frame = CGRect(origin: .zero, size: size)
            } else {
                window = UIWindow(frame: CGRect(origin: .zero, size: size))
            }
            window.rootViewController = controller
            window.isHidden = true
            self.window = window
        }

        func start() async throws {
            guard !stopped else { return }
            let prepared = await sourceImage.prepareForDisplay(for: size, scale: 1)
            guard (0..<frameCount).allSatisfy({ prepared.image(at: $0) != nil }) else {
                throw AnimatedImageComparatorError.preparationFailed
            }
            // Bind the exact 0.2.4 public timestamp mapping before collecting evidence.
            // This detects a future retained-source change instead of silently reusing the adapter assumption.
            for index in 0..<frameCount {
                let probe = (Double(index) + 0.5) * effectiveFrameDurationSeconds
                guard prepared.index(for: probe) == index else {
                    throw AnimatedImageComparatorError.effectiveTimelineMismatch
                }
            }
            preparedImage = prepared
            imageView.observedImage = prepared
            imageView.beginRecording()
            imageView.image = prepared
            window.makeKeyAndVisible()
        }

        func pause() {
            guard !stopped else { return }
            window.isHidden = true
        }

        func stop() {
            guard !stopped else { return }
            stopped = true
            imageView.endRecording()
            imageView.eventSink = nil
            imageView.observedImage = nil
            imageView.image = nil
            preparedImage = nil
            window.isHidden = true
            window.rootViewController = nil
            continuation.finish()
        }

        isolated deinit {
            imageView.endRecording()
            imageView.eventSink = nil
            imageView.observedImage = nil
            imageView.image = nil
            window.isHidden = true
            window.rootViewController = nil
            continuation.finish()
        }
    }

    extension AnimatedImageComparatorAdapter {
        @MainActor
        public func makeAnimatedPlayer(
            _ request: ComparatorAnimatedPlayerRequest
        ) throws -> ComparatorAnimatedPlayerSession {
            guard request.format == .gif else {
                throw AnimatedImageComparatorError.unsupportedFormat
            }
            guard request.referenceFrameDurationsNanoseconds.count > 1,
                let firstDurationNanoseconds = request.referenceFrameDurationsNanoseconds.first,
                firstDurationNanoseconds > 0
            else {
                throw AnimatedImageComparatorError.invalidReferenceTimeline
            }
            guard
                let source = CGImageSourceCreateWithData(request.encodedData as CFData, nil),
                CGImageSourceGetCount(source) == request.referenceFrameDurationsNanoseconds.count
            else {
                throw AnimatedImageComparatorError.invalidFrameCount
            }
            guard
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0,
                height > 0
            else {
                throw AnimatedImageComparatorError.invalidFrameGeometry
            }

            let frameCount = request.referenceFrameDurationsNanoseconds.count
            let effectiveDurations = Array(
                repeating: firstDurationNanoseconds,
                count: frameCount
            )
            let configuration = AnimatedImage.Configuration(
                maxMemoryUsage: Measurement(
                    value: Double(request.maximumFrameBufferBytes),
                    unit: UnitInformationStorage.bytes
                ),
                maxSize: Size(width: width, height: height),
                maxLevelOfIntegrity: 1,
                interpolationQuality: .none
            )
            let sourceImage = AnimatedImage(
                imageSource: GifImageSource(
                    name: "fovea-w5-\(request.resourceID)",
                    data: request.encodedData
                ),
                withConfiguration: configuration
            )
            let pair = AsyncStream<ComparatorAnimatedPlayerFrameEvent>.makeStream(
                bufferingPolicy: .bufferingNewest(4_096)
            )
            let state = AnimatedImageEventState()
            let controller = AnimatedImagePlayerController(
                sourceImage: sourceImage,
                frameCount: frameCount,
                size: CGSize(width: width, height: height),
                effectiveFrameDurationSeconds: Double(firstDurationNanoseconds) / 1_000_000_000,
                continuation: pair.continuation,
                state: state
            )
            pair.continuation.onTermination = { @Sendable _ in
                Task { @MainActor in controller.stop() }
            }
            return try ComparatorAnimatedPlayerSession(
                sourceFrameDurationsNanoseconds: effectiveDurations,
                sourceLoopCount: 0,
                inputPath: .encodedNative,
                events: pair.stream,
                start: { try await controller.start() },
                pause: { controller.pause() },
                stop: { controller.stop() }
            )
        }
    }
#endif
