import Foundation

/// 具体动画 decoder 完成容器验证后交给 Fovea 的最小播放事实。
package struct PreparedAnimationPlaybackAsset: Sendable {
    package let timeline: AnimationPlaybackTimeline
    package let codecFingerprint: String
    package let provider: any AnimationFrameProvider
    /// 此请求完整 prepared track 上 `DecodedImage.estimatedByteCost` 总和的保守上界；nil 表示 preparer 无法证明该上界。
    package let wholeTrackDecodedByteCostUpperBound: Int?
    /// prepared asset 存活期间，由 decoder/provider 持有的 payload、palette、checkpoint 或等价保留字节的保守上界。
    package let wholeTrackProviderRetainedByteCostUpperBound: Int?
    /// 整轨预解码峰值字节成本的保守上界，包含 provider 保留和 transient/materialization 成本；自动准入要求三个上界全部可证明。
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
    /// 保留既有显式策略契约，不让自动策略改变调用方已选择的语义。
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

    /// 仅在 decoder 准备阶段提供保守解码字节上界后，才解析可选的自动整轨策略；自动选择有意限制在 AppKit compositor 快路径可消费的播放形态。
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
