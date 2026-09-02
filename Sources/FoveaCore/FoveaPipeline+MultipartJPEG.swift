import Foundation
import FoveaHTTP

package struct MultipartJPEGPipelinePreparation: Sendable {
    package let frameDecoder: PipelineMultipartJPEGFrameDecoder
    package let transportRequest: TransportRequest
    package let diagnostics: any DiagnosticsSink
    package let diagnosticKeyDigest: String
    package let namespaceGeneration: NamespaceGeneration
}

extension FoveaPipeline {
    /// 在普通图片 FetchStage 的同一并发与排队许可内执行 live transport。
    package func executeMultipartJPEGLiveTransport(
        _ request: TransportRequest,
        priority: ImageRequestPriority,
        keyDigest: String
    ) async throws -> TransportProgressCompletion {
        try await fetchStage.executeLiveTransport(
            request,
            priority: priority,
            keyDigest: keyDigest
        )
    }

    /// 创建与普通请求安全策略一致的 MJPEG transport 和逐帧 DecodeStage 输入。
    package func prepareMultipartJPEG(
        for request: ImageRequest
    ) async throws -> MultipartJPEGPipelinePreparation {
        let decoder = try await makeMultipartJPEGFrameDecoder(for: request)
        let urlRequest = FetchRequestPreparation.authorizedRequest(
            for: request,
            conditionalRecord: nil
        )
        let transportRequest = try TransportRequest(
            request: urlRequest,
            maximumBytes: configuration.maximumTransportBytes,
            memoryThreshold: configuration.transportMemoryThreshold,
            credentialHeaderNames: request.credentialHeaderNames,
            priority: request.priority.transportPriority
        )
        let diagnosticKey = request.fetchExecutionKey(
            selectedVariant: nil,
            revalidationFingerprint: "mjpeg-live",
            transportPolicyFingerprint: "mjpeg-live-v1"
        ).digestHex
        return MultipartJPEGPipelinePreparation(
            frameDecoder: decoder,
            transportRequest: transportRequest,
            diagnostics: diagnostics,
            diagnosticKeyDigest: diagnosticKey,
            namespaceGeneration: decoder.generation
        )
    }

    /// 创建一个与当前 request profile、namespace generation 和普通 DecodeStage 绑定的
    /// MJPEG frame decoder。该入口不启动网络，也不改变普通图片缓存层级。
    package func makeMultipartJPEGFrameDecoder(
        for request: ImageRequest
    ) async throws -> PipelineMultipartJPEGFrameDecoder {
        guard profileAccessPolicy.permits(request) else {
            throw PipelineFailure.profileAccessDenied
        }
        if request.containsCredentialHeaders {
            guard request.authorizationContext != .public,
                request.credentialGeneration != nil
            else { throw PipelineFailure.missingAuthorizationContext }
        }
        let generation = try await namespaceRegistry.generation(for: request.namespace)
        return PipelineMultipartJPEGFrameDecoder(
            decodeStage: decodeStage,
            namespaceRegistry: namespaceRegistry,
            request: request,
            generation: generation
        )
    }
}
