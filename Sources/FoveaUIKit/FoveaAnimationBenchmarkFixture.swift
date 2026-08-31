#if canImport(UIKit)
    import CoreGraphics
    import Foundation
    import FoveaCore
    import ImageCraftCore
    import UIKit

    @_spi(BenchmarkDiagnostics)
    public enum FoveaAnimationBenchmarkCadenceMode: String, Sendable {
        case maximumRefresh
        case timelineAligned

        fileprivate var coreMode: FoveaAnimationDisplayCadenceMode {
            switch self {
            case .maximumRefresh: .maximumRefresh
            case .timelineAligned: .timelineAlignedExperiment
            }
        }
    }

    private enum FoveaAnimationBenchmarkFixtureError: Error {
        case invalidConfiguration
        case imageCreationFailed
    }

    private actor FoveaSyntheticAnimationFrameProvider: AnimationFrameProvider {
        private let delayNanoseconds: UInt64
        private var isCancelled = false

        init(delayNanoseconds: UInt64) {
            self.delayNanoseconds = delayNanoseconds
        }

        func frames(in range: Range<Int>) async throws -> [AnimationProviderFrame] {
            try Task.checkCancellation()
            guard !isCancelled else { throw CancellationError() }
            if delayNanoseconds > 0 {
                try await Task<Never, Never>.sleep(nanoseconds: delayNanoseconds)
            }
            try Task.checkCancellation()
            guard !isCancelled else { throw CancellationError() }
            return try range.map { index in
                AnimationProviderFrame(
                    index: index,
                    image: try Self.image(for: index)
                )
            }
        }

        func cancel() {
            isCancelled = true
        }

        private static func image(for index: Int) throws -> DecodedImage {
            let bytes = Data([
                UInt8(truncatingIfNeeded: index),
                UInt8(truncatingIfNeeded: index >> 8),
                UInt8(truncatingIfNeeded: index >> 16),
                255,
            ])
            guard let provider = CGDataProvider(data: bytes as CFData),
                let image = CGImage(
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(
                        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    ),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: false,
                    intent: .defaultIntent
                )
            else {
                throw FoveaAnimationBenchmarkFixtureError.imageCreationFailed
            }
            return DecodedImage(cgImage: image)
        }
    }

    extension FoveaImageView {
        /// Starts an in-memory synthetic animation for physical presentation diagnostics only.
        ///
        /// The fixture performs no network or codec work. It exists solely to exercise the real UIKit
        /// presentation bridge, playback cursor, bounded provider, frame memory, and lifecycle gates.
        @_spi(BenchmarkDiagnostics)
        @MainActor
        public func startSyntheticAnimationPresentationBenchmark(
            frameCount: Int = 240,
            frameDurationNanoseconds: UInt64 = 16_666_667,
            providerDelayNanoseconds: UInt64 = 0
        ) async throws {
            try await startSyntheticAnimationPresentationBenchmark(
                frameCount: frameCount,
                frameDurationNanoseconds: frameDurationNanoseconds,
                providerDelayNanoseconds: providerDelayNanoseconds,
                cadenceMode: .maximumRefresh
            )
        }

        /// Benchmark-only opt-in for device cadence A/B. Product callers remain on maximum refresh.
        @_spi(BenchmarkDiagnostics)
        @MainActor
        public func startSyntheticAnimationPresentationBenchmark(
            frameCount: Int,
            frameDurationNanoseconds: UInt64,
            providerDelayNanoseconds: UInt64,
            cadenceMode: FoveaAnimationBenchmarkCadenceMode
        ) async throws {
            guard frameCount > 1, frameCount <= 10_000 else {
                throw FoveaAnimationBenchmarkFixtureError.invalidConfiguration
            }
            try await startSyntheticAnimationPresentationBenchmark(
                frameDurationsNanoseconds: Array(
                    repeating: frameDurationNanoseconds,
                    count: frameCount
                ),
                providerDelayNanoseconds: providerDelayNanoseconds,
                cadenceMode: cadenceMode
            )
        }

        /// Benchmark-only variable-duration timeline used by cross-player W5 scheduling experiments.
        @_spi(BenchmarkDiagnostics)
        @MainActor
        public func startSyntheticAnimationPresentationBenchmark(
            frameDurationsNanoseconds: [UInt64],
            providerDelayNanoseconds: UInt64 = 0,
            cadenceMode: FoveaAnimationBenchmarkCadenceMode = .maximumRefresh
        ) async throws {
            guard frameDurationsNanoseconds.count > 1,
                frameDurationsNanoseconds.count <= 10_000,
                frameDurationsNanoseconds.allSatisfy({ $0 > 0 }),
                providerDelayNanoseconds <= 1_000_000_000
            else {
                throw FoveaAnimationBenchmarkFixtureError.invalidConfiguration
            }
            let target = try TargetPixels(width: 1, height: 1)
            var identityBytes = Data("fovea-animation-presentation-benchmark-v2".utf8)
            for duration in frameDurationsNanoseconds {
                var bigEndian = duration.bigEndian
                withUnsafeBytes(of: &bigEndian) { identityBytes.append(contentsOf: $0) }
            }
            let contentID = ContentID(data: identityBytes)
            guard
                let decodeKey = AnimationDecodeKey(
                    contentID: contentID,
                    target: target,
                    contentMode: .fit,
                    colorPolicy: .convertToSRGB,
                    codecFingerprint: "dev.fovea.synthetic.animation-benchmark#1",
                    animationPolicyVersion: 1,
                    timingPolicyVersion: 1,
                    frameStrategy: .predecodeAll
                )
            else {
                throw FoveaAnimationBenchmarkFixtureError.invalidConfiguration
            }
            let timeline = try AnimationPlaybackTimeline(
                frameDurationsNanoseconds: frameDurationsNanoseconds,
                additionalRepeatCount: nil,
                zeroDurationReplacementNanoseconds: 1,
                timingPolicyVersion: 1
            )
            let runtime = AnimationPlaybackRuntime(
                frameMemoryCostLimit: max(64 * 1024, frameDurationsNanoseconds.count * 16)
            )
            let provider = FoveaSyntheticAnimationFrameProvider(
                delayNanoseconds: providerDelayNanoseconds
            )
            let handle = try await runtime.makeHandle(
                namespace: .publicNamespace(appID: "fovea-animation-presentation-benchmark"),
                generation: NamespaceGeneration(1),
                decodeKey: decodeKey,
                timeline: timeline,
                playbackPolicy: AnimationPlaybackPolicy(requestedMode: .normal),
                reduceMotionEnabled: false,
                provider: provider,
                windowPolicy: AnimationFrameWindowPolicy(
                    normalFrameCount: 1,
                    warningFrameCount: 1
                ),
                maximumPredecodeAllFrameCount: frameDurationsNanoseconds.count,
                maximumQueuedAdvances: 1
            )
            setAnimation(
                handle: handle,
                runtime: runtime,
                accessibility: .decorative,
                clearCurrentImage: true,
                displayCadenceMode: cadenceMode.coreMode
            )
        }
    }
#endif
