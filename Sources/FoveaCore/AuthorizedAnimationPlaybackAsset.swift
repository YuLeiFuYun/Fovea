import Foundation

/// 具体动画 decoder 完成容器验证后交给 Fovea 的最小播放事实。
package struct PreparedAnimationPlaybackAsset: Sendable {
    package let timeline: AnimationPlaybackTimeline
    package let codecFingerprint: String
    package let provider: any AnimationFrameProvider
    /// Conservative upper bound for the sum of `DecodedImage.estimatedByteCost` across the full
    /// prepared track under this request. `nil` means the preparer cannot prove such a bound.
    package let wholeTrackDecodedByteCostUpperBound: Int?
    /// Conservative upper bound for decoder/provider-owned payload, palette, checkpoint, or
    /// equivalent retained bytes that remain alive with the prepared asset.
    package let wholeTrackProviderRetainedByteCostUpperBound: Int?
    /// Conservative peak byte-cost upper bound for whole-track predecode, including provider-retained
    /// and transient/materialization costs. Automatic admission requires all three bounds.
    package let wholeTrackPredecodePeakByteCostUpperBound: Int?

    package init(
        timeline: AnimationPlaybackTimeline,
        codecFingerprint: String,
        provider: any AnimationFrameProvider,
        wholeTrackDecodedByteCostUpperBound: Int? = nil,
        wholeTrackProviderRetainedByteCostUpperBound: Int? = nil,
        wholeTrackPredecodePeakByteCostUpperBound: Int? = nil
    ) {
        self.timeline = timeline
        self.codecFingerprint = codecFingerprint
        self.provider = provider
        let providerRetainedUpperBound: Int?
        if let wholeTrackProviderRetainedByteCostUpperBound,
            wholeTrackProviderRetainedByteCostUpperBound >= 0
        {
            providerRetainedUpperBound = wholeTrackProviderRetainedByteCostUpperBound
        } else {
            providerRetainedUpperBound = nil
        }
        self.wholeTrackProviderRetainedByteCostUpperBound = providerRetainedUpperBound

        if let wholeTrackDecodedByteCostUpperBound,
            wholeTrackDecodedByteCostUpperBound > 0,
            let providerRetainedUpperBound,
            let wholeTrackPredecodePeakByteCostUpperBound,
            wholeTrackPredecodePeakByteCostUpperBound > 0
        {
            let steadyState = wholeTrackDecodedByteCostUpperBound.addingReportingOverflow(
                providerRetainedUpperBound
            )
            if !steadyState.overflow,
                wholeTrackPredecodePeakByteCostUpperBound >= steadyState.partialValue
            {
                self.wholeTrackDecodedByteCostUpperBound = wholeTrackDecodedByteCostUpperBound
                self.wholeTrackPredecodePeakByteCostUpperBound =
                    wholeTrackPredecodePeakByteCostUpperBound
                return
            }
        }
        self.wholeTrackDecodedByteCostUpperBound = nil
        self.wholeTrackPredecodePeakByteCostUpperBound = nil
    }
}

/// FoveaSystem 与具体动画 decoder 之间的 package-only preparation seam。
package protocol EncodedAnimationPlaybackPreparing: Sendable {
    func prepareAnimation(
        source: AuthorizedEncodedData,
        request: ImageRequest
    ) async throws -> PreparedAnimationPlaybackAsset
}

/// 已由具体动画 decoder 准备、并绑定 Fovea 授权编码身份的播放资产。
///
/// ImageCraft adapter 只负责把容器 metadata 转为 `timeline` 并提供按需帧 provider；
/// namespace、generation、ContentID 与请求执行身份必须沿用 `authorization`，不得重建或猜测。
package struct AuthorizedAnimationPlaybackAsset: Sendable {
    package let authorization: AuthorizedEncodedData
    package let renderRequestIdentity: String
    package let timeline: AnimationPlaybackTimeline
    package let codecFingerprint: String
    package let provider: any AnimationFrameProvider
    package let wholeTrackDecodedByteCostUpperBound: Int?
    package let wholeTrackProviderRetainedByteCostUpperBound: Int?
    package let wholeTrackPredecodePeakByteCostUpperBound: Int?

    package init(
        authorization: AuthorizedEncodedData,
        request: ImageRequest,
        timeline: AnimationPlaybackTimeline,
        codecFingerprint: String,
        provider: any AnimationFrameProvider,
        wholeTrackDecodedByteCostUpperBound: Int? = nil,
        wholeTrackProviderRetainedByteCostUpperBound: Int? = nil,
        wholeTrackPredecodePeakByteCostUpperBound: Int? = nil
    ) {
        self.authorization = authorization
        self.renderRequestIdentity = request.renderAliasIdentity
        self.timeline = timeline
        self.codecFingerprint = codecFingerprint
        self.provider = provider
        self.wholeTrackDecodedByteCostUpperBound = wholeTrackDecodedByteCostUpperBound
        self.wholeTrackProviderRetainedByteCostUpperBound =
            wholeTrackProviderRetainedByteCostUpperBound
        self.wholeTrackPredecodePeakByteCostUpperBound = wholeTrackPredecodePeakByteCostUpperBound
    }

    package init(
        authorization: AuthorizedEncodedData,
        request: ImageRequest,
        prepared: PreparedAnimationPlaybackAsset
    ) {
        self.init(
            authorization: authorization,
            request: request,
            timeline: prepared.timeline,
            codecFingerprint: prepared.codecFingerprint,
            provider: prepared.provider,
            wholeTrackDecodedByteCostUpperBound: prepared.wholeTrackDecodedByteCostUpperBound,
            wholeTrackProviderRetainedByteCostUpperBound:
                prepared.wholeTrackProviderRetainedByteCostUpperBound,
            wholeTrackPredecodePeakByteCostUpperBound:
                prepared.wholeTrackPredecodePeakByteCostUpperBound
        )
    }
}

extension AnimationPlaybackRuntime {
    /// Preserves the existing explicit strategy contract.
    package func makeHandle(
        authorizedAsset asset: AuthorizedAnimationPlaybackAsset,
        request: ImageRequest,
        animationPolicyVersion: UInt16,
        frameStrategy: AnimationFrameStrategy,
        playbackPolicy: AnimationPlaybackPolicy,
        reduceMotionEnabled: Bool,
        windowPolicy: AnimationFrameWindowPolicy,
        maximumPredecodeAllFrameCount: Int = 0,
        maximumQueuedAdvances: Int = 8,
        clock: any AnimationPlaybackClock = SystemAnimationPlaybackClock()
    ) async throws -> AnimationPlaybackHandle {
        try await makeHandle(
            authorizedAsset: asset,
            request: request,
            animationPolicyVersion: animationPolicyVersion,
            frameStrategySelection: .fixed(frameStrategy),
            playbackPolicy: playbackPolicy,
            reduceMotionEnabled: reduceMotionEnabled,
            windowPolicy: windowPolicy,
            maximumPredecodeAllFrameCount: maximumPredecodeAllFrameCount,
            maximumQueuedAdvances: maximumQueuedAdvances,
            clock: clock
        )
    }

    /// Resolves an optional automatic whole-track strategy only after decoder preparation has supplied
    /// a conservative decoded-byte upper bound. Automatic selection is intentionally limited to the
    /// playback shape that the AppKit compositor fast path can consume.
    package func makeHandle(
        authorizedAsset asset: AuthorizedAnimationPlaybackAsset,
        request: ImageRequest,
        animationPolicyVersion: UInt16,
        frameStrategySelection: AnimationFrameStrategySelection,
        playbackPolicy: AnimationPlaybackPolicy,
        reduceMotionEnabled: Bool,
        windowPolicy: AnimationFrameWindowPolicy,
        maximumPredecodeAllFrameCount: Int = 0,
        maximumQueuedAdvances: Int = 8,
        clock: any AnimationPlaybackClock = SystemAnimationPlaybackClock()
    ) async throws -> AnimationPlaybackHandle {
        do {
            try Task.checkCancellation()
            let authorization = asset.authorization
            let resolvedMode = playbackPolicy.resolvedMode(reduceMotionEnabled: reduceMotionEnabled)
            let resolved = resolveFrameStrategySelection(
                frameStrategySelection,
                timeline: asset.timeline,
                resolvedMode: resolvedMode,
                wholeTrackDecodedByteCostUpperBound: asset.wholeTrackDecodedByteCostUpperBound,
                wholeTrackProviderRetainedByteCostUpperBound:
                    asset.wholeTrackProviderRetainedByteCostUpperBound,
                wholeTrackPredecodePeakByteCostUpperBound:
                    asset.wholeTrackPredecodePeakByteCostUpperBound,
                explicitMaximumPredecodeAllFrameCount: maximumPredecodeAllFrameCount
            )
            let providerRetainedByteCost = asset.wholeTrackProviderRetainedByteCostUpperBound
            let automaticCosts = automaticWholeTrackCosts(
                selection: frameStrategySelection,
                resolvedStrategy: resolved.strategy,
                asset: asset
            )
            guard authorization.matches(request),
                asset.renderRequestIdentity == request.renderAliasIdentity,
                let decodeKey = AnimationDecodeKey(
                    contentID: authorization.contentID,
                    target: request.target,
                    contentMode: request.contentMode,
                    colorPolicy: request.colorPolicy,
                    codecFingerprint: asset.codecFingerprint,
                    animationPolicyVersion: animationPolicyVersion,
                    timingPolicyVersion: asset.timeline.timingPolicyVersion,
                    frameStrategy: resolved.strategy
                )
            else {
                throw AnimationPlaybackRuntimeError.invalidAuthorizedAsset
            }
            return try makeHandle(
                namespace: authorization.namespace,
                generation: authorization.generation,
                decodeKey: decodeKey,
                timeline: asset.timeline,
                playbackPolicy: playbackPolicy,
                reduceMotionEnabled: reduceMotionEnabled,
                provider: asset.provider,
                windowPolicy: windowPolicy,
                maximumPredecodeAllFrameCount: resolved.maximumPredecodeFrames,
                maximumQueuedAdvances: maximumQueuedAdvances,
                automaticWholeTrackDecodedByteCostUpperBound: automaticCosts.decoded,
                providerRetainedByteCost: providerRetainedByteCost,
                automaticWholeTrackPredecodePeakByteCost: automaticCosts.peak,
                automaticWholeTrackPredecodePriority:
                    automaticCosts.peak == nil ? .normal : request.priority,
                clock: clock
            )
        } catch {
            await asset.provider.cancel()
            throw error
        }
    }

    private func automaticWholeTrackCosts(
        selection: AnimationFrameStrategySelection,
        resolvedStrategy: AnimationFrameStrategy,
        asset: AuthorizedAnimationPlaybackAsset
    ) -> (decoded: Int?, peak: Int?) {
        guard case .automaticWholeTrack = selection, resolvedStrategy == .predecodeAll else {
            return (nil, nil)
        }
        return (
            asset.wholeTrackDecodedByteCostUpperBound,
            asset.wholeTrackPredecodePeakByteCostUpperBound
        )
    }
}

extension FoveaPipeline {
    /// 先取得授权原编码，再执行 decoder preparation，并在转移 provider 所有权前复核 generation。
    package func prepareAuthorizedAnimationPlayback(
        for request: ImageRequest,
        using preparer: any EncodedAnimationPlaybackPreparing
    ) async throws -> AuthorizedAnimationPlaybackAsset {
        let authorization = try await authorizedEncodedData(for: request)
        let prepared = try await preparer.prepareAnimation(
            source: authorization,
            request: request
        )
        do {
            try await validateAuthorizedEncodedData(authorization, for: request)
            return AuthorizedAnimationPlaybackAsset(
                authorization: authorization,
                request: request,
                prepared: prepared
            )
        } catch {
            await prepared.provider.cancel()
            throw error
        }
    }
}
