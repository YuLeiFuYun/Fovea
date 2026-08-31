import Foundation
import FoveaHTTP

package enum AuthorizedEncodedDataOrigin: String, Hashable, Sendable {
    case reusableCache
    case network
}

/// 已通过请求 ACL、授权、新鲜度与 namespace generation 校验的原编码资产。
///
/// `requestExecutionKeyDigest` 绑定本次请求的凭证、头与网络执行身份；缓存命中另保留
/// `representationKeyDigest` 绑定已选择的 Vary 表征。两者都不替代不可变内容 `contentID`。
package struct AuthorizedEncodedData: Sendable {
    package let data: Data
    package let contentID: ContentID
    package let namespace: SecurityNamespaceID
    package let generation: NamespaceGeneration
    package let baseKeyDigest: String
    package let requestExecutionKeyDigest: String
    package let representationKeyDigest: String?
    package let origin: AuthorizedEncodedDataOrigin

    fileprivate init(
        data: Data,
        contentID: ContentID,
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration,
        baseKeyDigest: String,
        requestExecutionKeyDigest: String,
        representationKeyDigest: String?,
        origin: AuthorizedEncodedDataOrigin
    ) {
        self.data = data
        self.contentID = contentID
        self.namespace = namespace
        self.generation = generation
        self.baseKeyDigest = baseKeyDigest
        self.requestExecutionKeyDigest = requestExecutionKeyDigest
        self.representationKeyDigest = representationKeyDigest
        self.origin = origin
    }

    package func matches(_ request: ImageRequest) -> Bool {
        guard namespace == request.namespace,
            baseKeyDigest == request.fetchBaseDigest,
            requestExecutionKeyDigest == request.fetchExecutionKey.digestHex,
            contentID.byteCount == data.count
        else { return false }
        switch origin {
        case .network:
            return representationKeyDigest == nil
        case .reusableCache:
            return representationKeyDigest != nil
        }
    }
}

/// 负责原编码字节入口；不会触发容器探测、像素解码或未验证内容持久化。
final class EncodedDataCoordinator: Sendable {
    private let transportReusePolicy: TransportReusePolicy
    private let cache: PipelineCache
    private let fetchStage: FetchStage
    private let namespaceRegistry: NamespaceRegistry
    private let diagnostics: any DiagnosticsSink
    private let clock: any WallClock

    init(
        transportReusePolicy: TransportReusePolicy,
        cache: PipelineCache,
        fetchStage: FetchStage,
        namespaceRegistry: NamespaceRegistry,
        diagnostics: any DiagnosticsSink,
        clock: any WallClock
    ) {
        self.transportReusePolicy = transportReusePolicy
        self.cache = cache
        self.fetchStage = fetchStage
        self.namespaceRegistry = namespaceRegistry
        self.diagnostics = diagnostics
        self.clock = clock
    }

    func loadAuthorized(request: ImageRequest) async throws -> AuthorizedEncodedData {
        let generation = try await namespaceRegistry.generation(for: request.namespace)
        if transportReusePolicy.allowsCrossRequestReuse,
            let cached = try await cachedData(request: request, generation: generation)
        {
            return cached
        }

        guard request.cachePolicy != .onlyIfCached else {
            throw PipelineFailure.onlyIfCachedMiss
        }
        let response = try await fetchStage.response(
            for: request,
            conditionalRecord: nil,
            generation: generation
        )
        return try await validatedBody(
            response,
            request: request,
            generation: generation
        )
    }

    private func cachedData(
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws -> AuthorizedEncodedData? {
        let candidates = await cache.records(
            for: request.fetchBaseDigest,
            namespace: request.namespace,
            namespaceFingerprint: request.storageNamespaceFingerprint,
            generation: generation
        )
        guard
            let record = HTTPCachePolicy.selectRecord(
                from: candidates,
                requestHeaders: request.headers,
                additionalSensitiveNames: request.credentialHeaderNames,
                sensitiveFingerprints: request.headerVariantFingerprints
            ),
            record.isFresh(at: await clock.now()),
            record.disposition != .noStore
        else { return nil }

        do {
            let data = try await cache.read(record, namespace: request.namespace)
            return try await authorizeCachedData(
                data,
                record: record,
                request: request,
                generation: generation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as PipelineFailure where failure.disposition == .cancelled {
            throw failure
        } catch let failure as PipelineFailure where failure.category == .namespaceRevoked {
            throw failure
        } catch {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .cacheReadFailed,
                    keyDigest: record.variantKeyDigest,
                    reason: "encoded-data-read"
                )
            )
            await cache.removeRecord(
                record.variantKeyDigest,
                namespace: request.namespace,
                generation: generation
            )
            await fetchStage.invalidateCompletionHandoff(
                for: request,
                conditionalRecord: nil
            )
            return nil
        }
    }

    private func authorizeCachedData(
        _ data: Data,
        record: RepresentationRecord,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws -> AuthorizedEncodedData {
        try await requireActive(generation, for: request.namespace)
        guard record.isValidPersistentRecord(),
            record.securityNamespaceFingerprint == request.storageNamespaceFingerprint,
            record.namespaceGeneration == generation.value,
            record.baseKeyDigest == request.fetchBaseDigest,
            record.variantKeyDigest == request.fetchVariantKey(for: record.vary).digestHex,
            let contentID = ContentID(
                persistentDescription: record.contentID,
                expectedByteCount: data.count
            )
        else { throw PipelineFailure.invalidContentDigest }
        await diagnostics.record(
            DiagnosticEvent(
                kind: .originalEncodedHit,
                keyDigest: record.variantKeyDigest,
                byteCount: data.count
            )
        )
        return AuthorizedEncodedData(
            data: data,
            contentID: contentID,
            namespace: request.namespace,
            generation: generation,
            baseKeyDigest: record.baseKeyDigest,
            requestExecutionKeyDigest: request.fetchExecutionKey.digestHex,
            representationKeyDigest: record.variantKeyDigest,
            origin: .reusableCache
        )
    }

    private func validatedBody(
        _ response: TimedTransportResponse,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws -> AuthorizedEncodedData {
        try Task.checkCancellation()
        try await requireActive(generation, for: request.namespace)
        guard response.head.statusCode == 200 else {
            throw PipelineFailure.unsupportedStatus(response.head.statusCode)
        }
        try await validateContentType(response, request: request)
        let contentID: ContentID
        do {
            contentID = try ContentID(
                digestHex: response.transport.digestHex,
                byteCount: response.transport.bodyByteCount
            )
        } catch {
            throw PipelineFailure.invalidContentDigest
        }
        let data = try response.transport.materializedBody()
        try await requireActive(generation, for: request.namespace)
        guard data.count == contentID.byteCount else {
            throw PipelineFailure.invalidContentDigest
        }
        return AuthorizedEncodedData(
            data: data,
            contentID: contentID,
            namespace: request.namespace,
            generation: generation,
            baseKeyDigest: request.fetchBaseDigest,
            requestExecutionKeyDigest: request.fetchExecutionKey.digestHex,
            representationKeyDigest: nil,
            origin: .network
        )
    }

    private func validateContentType(
        _ response: TimedTransportResponse,
        request: ImageRequest
    ) async throws {
        if let contentType = response.head.value(forHeader: "Content-Type") {
            guard contentType.lowercased().hasPrefix("image/") else {
                throw PipelineFailure.nonImageResponse
            }
            return
        }
        await diagnostics.record(
            DiagnosticEvent(
                kind: .responseAnomaly,
                keyDigest: request.fetchBaseDigest,
                reason: "missing-content-type"
            )
        )
    }

    private func requireActive(
        _ generation: NamespaceGeneration,
        for namespace: SecurityNamespaceID
    ) async throws {
        guard await namespaceRegistry.isActive(generation, for: namespace) else {
            throw PipelineFailure.namespaceRevoked
        }
    }
}

/// Owns reusable-original prefetch policy and resumable transport state without decoding pixels.
/// This keeps ImageLoadCoordinator focused on display-oriented orchestration.
final class ValidatedOriginalPrefetchCoordinator: Sendable {
    private enum Reuse {
        case fresh
        case conditional(RepresentationRecord)
        case miss
    }

    private let configuration: PipelineConfiguration
    private let transportReusePolicy: TransportReusePolicy
    private let cache: PipelineCache
    private let fetchStage: FetchStage
    private let responseProcessor: HTTPImageResponseProcessor
    private let namespaceRegistry: NamespaceRegistry
    private let clock: any WallClock
    private let resumes = ValidatedOriginalResumeStore()

    init(
        configuration: PipelineConfiguration,
        transportReusePolicy: TransportReusePolicy,
        cache: PipelineCache,
        fetchStage: FetchStage,
        responseProcessor: HTTPImageResponseProcessor,
        namespaceRegistry: NamespaceRegistry,
        clock: any WallClock
    ) {
        self.configuration = configuration
        self.transportReusePolicy = transportReusePolicy
        self.cache = cache
        self.fetchStage = fetchStage
        self.responseProcessor = responseProcessor
        self.namespaceRegistry = namespaceRegistry
        self.clock = clock
    }

    func prefetch(request: ImageRequest) async throws {
        guard transportReusePolicy.allowsCrossRequestReuse else {
            throw ImagePrefetchError.reusableOriginalRequiresCrossRequestReuse
        }
        let generation = try await namespaceRegistry.generation(
            for: request.storageNamespaceFingerprint
        )
        let reuse = await reusableOriginal(request: request, generation: generation)
        if case .fresh = reuse {
            try await requireActive(generation, for: request)
            try Task.checkCancellation()
            return
        }
        guard request.cachePolicy != .onlyIfCached else {
            throw PipelineFailure.onlyIfCachedMiss
        }
        let conditionalRecord: RepresentationRecord?
        if case .conditional(let record) = reuse {
            conditionalRecord = record
        } else {
            conditionalRecord = nil
        }
        try await fetchAndPersist(
            request: request,
            generation: generation,
            conditionalRecord: conditionalRecord
        )
    }

    private func reusableOriginal(
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async -> Reuse {
        let candidates = await cache.records(
            for: request.fetchBaseDigest,
            namespace: request.namespace,
            namespaceFingerprint: request.storageNamespaceFingerprint,
            generation: generation
        )
        guard
            let selected = HTTPCachePolicy.selectRecord(
                from: candidates,
                requestHeaders: request.headers,
                additionalSensitiveNames: request.credentialHeaderNames,
                sensitiveFingerprints: request.headerVariantFingerprints
            )
        else { return .miss }
        if selected.isFresh(at: await clock.now()) {
            return await freshReuse(selected, request: request, generation: generation)
        }
        guard selected.etag != nil || selected.lastModified != nil else { return .miss }
        return .conditional(selected)
    }

    private func freshReuse(
        _ selected: RepresentationRecord,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async -> Reuse {
        guard
            await cache.encodedStore.physicalID(
                contentID: selected.contentID,
                namespace: request.namespace.value
            ) != nil
        else {
            await cache.removeRecord(
                selected.variantKeyDigest,
                namespace: request.namespace,
                generation: generation
            )
            return .miss
        }
        return .fresh
    }

    private func fetchAndPersist(
        request: ImageRequest,
        generation: NamespaceGeneration,
        conditionalRecord: RepresentationRecord?
    ) async throws {
        if conditionalRecord == nil,
            fetchStage.supportsProgressObservation,
            let resumeKey = resumeKey(request: request, generation: generation)
        {
            try await fetchAndPersistResumable(
                request: request,
                generation: generation,
                resumeKey: resumeKey
            )
            return
        }
        try await fetchAndPersistWithoutResume(
            request: request,
            generation: generation,
            conditionalRecord: conditionalRecord
        )
    }

    private func fetchAndPersistResumable(
        request: ImageRequest,
        generation: NamespaceGeneration,
        resumeKey: ValidatedOriginalResumeKey
    ) async throws {
        let seed = await resumes.take(resumeKey)
        let capture = ValidatedOriginalResumeCapture(
            seed: seed,
            maximumTransportBytes: configuration.maximumTransportBytes
        )
        do {
            let response = try await fetchStage.response(
                for: request,
                conditionalRecord: nil,
                generation: generation,
                byteRangeResume: seed?.requestDescriptor,
                memoryThresholdOverride: 0,
                bodyDelivery: .deferredFileIfStaged,
                progressObserver: { capture.observe($0) }
            )
            try await persistResumable(
                response,
                seed: seed,
                request: request,
                generation: generation
            )
        } catch {
            if let candidate = capture.candidate() {
                await resumes.store(candidate, for: resumeKey)
            }
            throw error
        }
    }

    private func persistResumable(
        _ response: TimedTransportResponse,
        seed: ValidatedOriginalResumeCandidate?,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws {
        if response.head.statusCode == 206 {
            guard let seed else { throw TransportError.invalidResponseHeader }
            let complete = try ValidatedOriginalResumption.reassemble(
                response,
                candidate: seed,
                maximumTransportBytes: configuration.maximumTransportBytes
            )
            try await responseProcessor.persistValidatedOriginalOnly(
                complete,
                request: request,
                generation: generation
            )
            return
        }
        try await responseProcessor.persistValidatedOriginalOnly(
            response,
            request: request,
            generation: generation
        )
    }

    private func resumeKey(
        request: ImageRequest,
        generation: NamespaceGeneration
    ) -> ValidatedOriginalResumeKey? {
        let reserved = Set(["range", "if-range"])
        guard request.headers.keys.allSatisfy({ !reserved.contains($0.lowercased()) }) else {
            return nil
        }
        let execution = request.fetchExecutionKey(
            selectedVariant: nil,
            revalidationFingerprint: "unconditional",
            transportPolicyFingerprint:
                "\(configuration.transportPolicyFingerprint):\(transportReusePolicy.executionFingerprint)"
        )
        return ValidatedOriginalResumeKey(
            executionDigest: execution.digestHex,
            namespace: request.namespace,
            generation: generation
        )
    }

    private func fetchAndPersistWithoutResume(
        request: ImageRequest,
        generation: NamespaceGeneration,
        conditionalRecord: RepresentationRecord?
    ) async throws {
        let response = try await fetchStage.response(
            for: request,
            conditionalRecord: conditionalRecord,
            generation: generation,
            memoryThresholdOverride: 0,
            bodyDelivery: .deferredFileIfStaged
        )
        guard response.head.statusCode == 304 else {
            try await responseProcessor.persistValidatedOriginalOnly(
                response,
                request: request,
                generation: generation
            )
            return
        }
        guard let conditionalRecord else { throw PipelineFailure.missingCachedBody }
        if try await responseProcessor.refreshValidatedOriginalOnly304(
            response,
            existing: conditionalRecord,
            request: request,
            generation: generation
        ) {
            return
        }
        let retry = try await fetchStage.response(
            for: request,
            conditionalRecord: nil,
            generation: generation,
            memoryThresholdOverride: 0,
            bodyDelivery: .deferredFileIfStaged
        )
        try await responseProcessor.persistValidatedOriginalOnly(
            retry,
            request: request,
            generation: generation
        )
    }

    private func requireActive(
        _ generation: NamespaceGeneration,
        for request: ImageRequest
    ) async throws {
        guard
            await namespaceRegistry.isActive(
                generation,
                for: request.storageNamespaceFingerprint
            )
        else { throw PipelineFailure.namespaceRevoked }
    }
}

extension FoveaPipeline {
    public func encodedData(for request: ImageRequest) async throws -> Data {
        try await authorizedEncodedData(for: request).data
    }

    /// 返回携带不可变内容身份与 namespace 授权代际的原编码资产。
    ///
    /// 该入口仅供包内动画/容器适配器使用；公开 `encodedData(for:)` 继续只暴露字节。
    package func authorizedEncodedData(
        for request: ImageRequest
    ) async throws -> AuthorizedEncodedData {
        let admission = SharedTaskAdmission.now()
        return try await SharedTaskAdmissionContext.$current.withValue(admission) {
            try await execute {
                try validateAccess(to: request)
                try validateAuthorization(of: request)
                let authorized = try await encodedCoordinator.loadAuthorized(request: request)
                try await validateAuthorizedEncodedData(authorized, for: request)
                return authorized
            }
        }
    }

    /// 在长耗时 decoder preparation 后重新确认请求身份和 namespace generation。
    package func validateAuthorizedEncodedData(
        _ authorized: AuthorizedEncodedData,
        for request: ImageRequest
    ) async throws {
        try Task.checkCancellation()
        try validateAccess(to: request)
        try validateAuthorization(of: request)
        guard authorized.matches(request) else {
            throw PipelineFailure.authorization(
                reasonCode: "authorized-encoded-identity-mismatch"
            )
        }
        guard
            await namespaceRegistry.isActive(
                authorized.generation,
                for: authorized.namespace
            )
        else {
            throw PipelineFailure.namespaceRevoked
        }
    }
}
