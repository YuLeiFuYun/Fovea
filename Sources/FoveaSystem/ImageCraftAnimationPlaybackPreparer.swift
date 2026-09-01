import FoveaCore
import ImageCraftCore
import ImageCraftImageIO

package enum ImageCraftAnimationPlaybackAdapterError: Error, Equatable, Sendable {
    case encodedByteCountMismatch
    case frameDescriptorMismatch
}

/// FoveaSystem adapter for the pinned public ImageCraft animation decoder.
///
/// Timing normalization remains explicit and caller-versioned; ImageCraft owns encoded animation
/// parsing/decoding while Fovea owns authorization, request geometry, playback policy and memory admission.
package struct ImageCraftAnimationPlaybackPreparer: EncodedAnimationPlaybackPreparing {
    private let decoder: any ImageAnimationDecoding
    private let limits: ImageAnimationDecodeLimits
    private let zeroDurationReplacementNanoseconds: UInt64
    private let timingPolicyVersion: UInt16

    package init(
        decoder: any ImageAnimationDecoding = ImageIOAnimatedImageDecoder(),
        limits: ImageAnimationDecodeLimits = ImageAnimationDecodeLimits(),
        zeroDurationReplacementNanoseconds: UInt64,
        timingPolicyVersion: UInt16
    ) {
        self.decoder = decoder
        self.limits = limits
        self.zeroDurationReplacementNanoseconds = zeroDurationReplacementNanoseconds
        self.timingPolicyVersion = timingPolicyVersion
    }

    package func prepareAnimation(
        source: AuthorizedEncodedData,
        request: ImageRequest
    ) async throws -> PreparedAnimationPlaybackAsset {
        try Task.checkCancellation()
        let asset = try await decoder.prepareAnimation(
            source: .encoded(source.data),
            limits: limits
        )
        do {
            try Task.checkCancellation()
            guard asset.metadata.encodedByteCount == source.data.count else {
                throw ImageCraftAnimationPlaybackAdapterError.encodedByteCountMismatch
            }
            let timeline = try AnimationPlaybackTimeline(
                frameDurationsNanoseconds: asset.metadata.frames.map {
                    $0.duration.roundedUpNanoseconds
                },
                additionalRepeatCount: asset.metadata.loopCount.additionalRepeatCount,
                zeroDurationReplacementNanoseconds: zeroDurationReplacementNanoseconds,
                timingPolicyVersion: timingPolicyVersion
            )
            let decodeRequest = ImageDecodeRequest(
                target: request.target,
                contentMode: request.contentMode,
                colorPolicy: request.colorPolicy
            )
            let provider = ImageCraftAnimationFrameProvider(
                asset: asset,
                request: decodeRequest,
                maximumFrameDecodeWindow: limits.maximumFrameDecodeWindow
            )
            let wholeTrackCostEstimate = asset.wholeTrackCostEstimate(for: decodeRequest)
            return PreparedAnimationPlaybackAsset(
                timeline: timeline,
                codecFingerprint: asset.metadata.codecFingerprint,
                provider: provider,
                wholeTrackDecodedByteCostUpperBound:
                    wholeTrackCostEstimate?.residentDecodedByteCostUpperBound,
                wholeTrackProviderRetainedByteCostUpperBound:
                    wholeTrackCostEstimate?.providerRetainedByteCostUpperBound,
                wholeTrackPredecodePeakByteCostUpperBound:
                    wholeTrackCostEstimate?.predecodePeakByteCostUpperBound
            )
        } catch {
            await asset.cancel()
            throw error
        }
    }
}

private actor ImageCraftAnimationFrameProvider: AnimationFrameProvider {
    private let asset: AnimatedImageAsset
    private let request: ImageDecodeRequest
    private let maximumFrameDecodeWindow: Int
    private var isCancelled = false

    init(
        asset: AnimatedImageAsset,
        request: ImageDecodeRequest,
        maximumFrameDecodeWindow: Int
    ) {
        self.asset = asset
        self.request = request
        self.maximumFrameDecodeWindow = max(1, maximumFrameDecodeWindow)
    }

    func frames(in range: Range<Int>) async throws -> [AnimationProviderFrame] {
        try Task.checkCancellation()
        guard !isCancelled else { throw CancellationError() }
        var result: [AnimationProviderFrame] = []
        result.reserveCapacity(range.count)
        var lowerBound = range.lowerBound
        while lowerBound < range.upperBound {
            try Task.checkCancellation()
            guard !isCancelled else { throw CancellationError() }
            let upperBound = min(
                range.upperBound,
                lowerBound + maximumFrameDecodeWindow
            )
            let chunkRange = lowerBound..<upperBound
            let frames = try await asset.frames(in: chunkRange, request: request)
            guard frames.count == chunkRange.count else {
                throw ImageCraftAnimationPlaybackAdapterError.frameDescriptorMismatch
            }
            for (expected, frame) in zip(chunkRange, frames) {
                guard frame.descriptor.index == expected else {
                    throw ImageCraftAnimationPlaybackAdapterError.frameDescriptorMismatch
                }
                result.append(
                    AnimationProviderFrame(index: frame.descriptor.index, image: frame.image)
                )
            }
            lowerBound = upperBound
        }
        try Task.checkCancellation()
        guard !isCancelled else { throw CancellationError() }
        return result
    }

    func frameWindowPredecodePeakByteCostUpperBound(frameCount: Int) async -> Int? {
        guard frameCount > 0 else { return nil }
        var remaining = frameCount
        var callerRetainedOutputBytes = 0
        var peakByteCost = 0

        // Fovea 的 decode plan 可以跨 loop 边界或大于 ImageCraft 单次 decode window。
        // 逐 chunk 复用 ImageCraft 的公开保守模型，并把前一 chunk 已返回、仍由 Fovea
        // 临时数组持有的输出作为 coexistence 成本加入下一 chunk，得到整个 provider 调用
        // 的保守峰值，而不是在 >maximumFrameDecodeWindow 时退化为猜测。
        while remaining > 0 {
            let chunkFrameCount = min(remaining, maximumFrameDecodeWindow)
            guard
                let estimate = asset.frameWindowCostEstimate(
                    for: request,
                    frameCount: chunkFrameCount
                ),
                let coexistencePeak = estimate.coexistencePeakByteCostUpperBound(
                    callerRetainedOutputBytes: callerRetainedOutputBytes
                )
            else { return nil }
            peakByteCost = max(peakByteCost, coexistencePeak)
            let retained = callerRetainedOutputBytes.addingReportingOverflow(
                estimate.decodedOutputByteCostUpperBound
            )
            guard !retained.overflow else { return nil }
            callerRetainedOutputBytes = retained.partialValue
            remaining -= chunkFrameCount
        }
        return peakByteCost > 0 ? peakByteCost : nil
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        await asset.cancel()
    }
}
