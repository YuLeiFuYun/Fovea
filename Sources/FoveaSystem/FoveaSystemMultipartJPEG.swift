import FoveaCore
import FoveaHTTP

extension FoveaSystemPipeline {
    /// 创建一条由官方 URLSession transport、严格 multipart parser、普通 DecodeStage
    /// 和系统动画生命周期 runtime 组成的 live MJPEG 会话。
    package func makeMultipartJPEGLivePlayback(
        for request: ImageRequest,
        playbackPolicy: MultipartJPEGLivePlaybackPolicy = MultipartJPEGLivePlaybackPolicy(),
        streamLimits: MultipartJPEGStreamLimits = MultipartJPEGStreamLimits(),
        maximumBufferedParts: Int = 8,
        reduceMotionEnabled: Bool = false,
        clock: any AnimationPlaybackClock = SystemAnimationPlaybackClock()
    ) async throws -> MultipartJPEGLivePlaybackHandle {
        let preparation = try await pipeline.prepareMultipartJPEG(for: request)
        let transportSession = try MultipartJPEGTransport.start(
            execute: { transportRequest in
                try await pipeline.executeMultipartJPEGLiveTransport(
                    transportRequest,
                    priority: request.priority,
                    keyDigest: preparation.diagnosticKeyDigest
                )
            },
            request: preparation.transportRequest,
            limits: streamLimits,
            maximumBufferedParts: maximumBufferedParts
        )
        let playback = MultipartJPEGLivePlaybackSession(
            stream: transportSession.stream,
            decoder: preparation.frameDecoder,
            policy: playbackPolicy,
            clock: clock,
            diagnostics: preparation.diagnostics,
            diagnosticKeyDigest: preparation.diagnosticKeyDigest,
            stopsAfterFirstFrame: playbackPolicy.stopsAfterFirstFrame(
                reduceMotionEnabled: reduceMotionEnabled
            ),
            cancellationHandler: { transportSession.cancel() }
        )
        do {
            return try await animationRuntime.registerLiveSession(
                playback,
                namespace: request.namespace,
                generation: preparation.namespaceGeneration
            )
        } catch {
            transportSession.cancel()
            throw error
        }
    }
}
