import Foundation
import FoveaHTTP
import ImageCraftCore

/// 负责 200/304 响应的表示语义、OriginalEncoded 提交与 record 刷新。
/// 解码和 RenderedMemory 发布由 `ImageDeliveryCoordinator` 完成。
final class HTTPImageResponseProcessor: Sendable {
    private let cache: PipelineCache
    private let fetchStage: FetchStage
    private let delivery: ImageDeliveryCoordinator
    private let namespaceRegistry: NamespaceRegistry
    private let diagnostics: any DiagnosticsSink

    private enum Cached304Body {
        case data(Data)
        case recovered(DecodedImage)
    }

    private struct RevalidationMetadata {
        let vary: HTTPVarySelection
        let disposition: CacheDisposition
        let cacheControlPresent: Bool
    }

    private struct Prepared200Execution {
        let data: Data
        let prepared: Prepared200Response
        let progressivePreparation: ImageDecodePreparation?
        let representation: RepresentationRecord?
        let allowsReusableState: Bool
    }

    init(
        cache: PipelineCache,
        fetchStage: FetchStage,
        delivery: ImageDeliveryCoordinator,
        namespaceRegistry: NamespaceRegistry,
        diagnostics: any DiagnosticsSink
    ) {
        self.cache = cache
        self.fetchStage = fetchStage
        self.delivery = delivery
        self.namespaceRegistry = namespaceRegistry
        self.diagnostics = diagnostics
    }

    func process304(
        _ response: TimedTransportResponse,
        existing: RepresentationRecord?,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws -> DecodedImage {
        guard let existing else { throw PipelineFailure.missingCachedBody }
        let cachedData: Data
        switch try await cached304Body(
            existing: existing,
            request: request,
            generation: generation
        ) {
        case .data(let data):
            cachedData = data
        case .recovered(let image):
            return image
        }

        await diagnostics.record(
            DiagnosticEvent(
                kind: .originalEncodedHit,
                keyDigest: existing.variantKeyDigest,
                byteCount: cachedData.count
            )
        )
        try await requireActive(generation, for: request.namespace)

        let metadata = revalidationMetadata(
            response: response,
            existing: existing,
            request: request
        )
        if metadata.disposition == .noStore {
            return try await deliverNoStore304(
                cachedData: cachedData,
                existing: existing,
                request: request,
                generation: generation
            )
        }

        let refreshed = refreshedRecord(
            response: response,
            existing: existing,
            request: request,
            generation: generation,
            metadata: metadata
        )
        try await refreshRecord(
            replacing: existing,
            with: refreshed,
            namespace: request.namespace,
            generation: generation
        )
        return try await delivery.imageFromReusableData(
            data: cachedData,
            request: request,
            generation: generation,
            representation: refreshed,
            keyDigest: refreshed.variantKeyDigest
        )
    }

    func process200(
        _ response: TimedTransportResponse,
        request: ImageRequest,
        generation: NamespaceGeneration,
        allowReusableState: Bool = true,
        onFullQualityPreview: (@Sendable (DecodedImage) async throws -> Void)? = nil,
        progressiveFinalization: PipelineProgressiveFinalization? = nil
    ) async throws -> DecodedImage {
        let execution = try await prepare200Execution(
            response,
            request: request,
            generation: generation,
            allowReusableState: allowReusableState,
            progressiveFinalization: progressiveFinalization
        )
        let data = execution.data
        let prepared = execution.prepared
        let progressivePreparation = execution.progressivePreparation
        let allowsReusableState = execution.allowsReusableState
        guard let representation = execution.representation else {
            return try await processTransient200(
                data: data,
                contentID: prepared.contentID,
                variantDigest: prepared.variant.digestHex,
                request: request,
                generation: generation,
                onFullQualityPreview: onFullQualityPreview,
                preparation: progressivePreparation
            )
        }
        async let decodedTask = delivery.decode(
            data: data,
            contentID: prepared.contentID,
            request: request,
            generation: generation,
            keyDigest: prepared.variant.digestHex,
            preparation: progressivePreparation
        )
        async let commitPreparationTask: OriginalCommitPreparation? = prepareOriginalCommitIfNeeded(
            data: data,
            contentID: prepared.contentID,
            representation: representation,
            namespace: request.namespace,
            generation: generation,
            keyDigest: prepared.variant.digestHex
        )
        let decoded: DecodedImage
        do {
            decoded = try await decodedTask
            try Task.checkCancellation()
            try await requireActive(generation, for: request.namespace)
        } catch {
            do {
                if let commitPreparation = try await commitPreparationTask {
                    await cache.discardOriginalCommit(commitPreparation)
                }
            } catch {
                // 解码失败是主失败；并发 staging 的失败不得覆盖它。
            }
            throw error
        }
        let rendered: PreparedRenderedImage
        do {
            rendered = try await delivery.prepareRenderedImage(
                decoded: decoded,
                contentID: prepared.contentID,
                request: request,
                generation: generation,
                allowsRenderedMemory: allowsReusableState,
                keyDigest: prepared.variant.digestHex
            )
        } catch {
            do {
                let commitPreparation = try await commitPreparationTask
                try await publishOriginalIfNeeded(
                    commitPreparation,
                    contentID: prepared.contentID,
                    representation: representation,
                    namespace: request.namespace,
                    generation: generation,
                    keyDigest: prepared.variant.digestHex
                )
            } catch {
                throw error
            }
            throw error
        }
        try Task.checkCancellation()
        try await requireActive(generation, for: request.namespace)
        if let onFullQualityPreview {
            do {
                try await onFullQualityPreview(rendered.image)
                await Task.yield()
            } catch {
                do {
                    if let commitPreparation = try await commitPreparationTask {
                        await cache.discardOriginalCommit(commitPreparation)
                    }
                } catch {
                    // UI 终止或取消是主失败；并发 staging 的失败不得覆盖它。
                }
                throw error
            }
        }
        let commitPreparation = try await commitPreparationTask
        try await publishOriginalIfNeeded(
            commitPreparation,
            contentID: prepared.contentID,
            representation: representation,
            namespace: request.namespace,
            generation: generation,
            keyDigest: prepared.variant.digestHex
        )
        return try await delivery.publishPreparedRenderedImage(
            rendered,
            request: request,
            generation: generation,
            representation: representation
        )
    }

    private func prepare200Execution(
        _ response: TimedTransportResponse,
        request: ImageRequest,
        generation: NamespaceGeneration,
        allowReusableState: Bool,
        progressiveFinalization: PipelineProgressiveFinalization?
    ) async throws -> Prepared200Execution {
        let prepared = try await prepare200Response(response, request: request)
        let data = try response.transport.materializedBody()
        let progressivePreparation = await validatedProgressivePreparation(
            progressiveFinalization,
            response: response,
            data: data
        )
        try Task.checkCancellation()
        let allowsReusableState = allowReusableState && prepared.disposition != .noStore
        let representation =
            allowsReusableState
            ? reusableRecord(
                response: response,
                request: request,
                generation: generation,
                prepared: prepared
            )
            : nil
        return Prepared200Execution(
            data: data,
            prepared: prepared,
            progressivePreparation: progressivePreparation,
            representation: representation,
            allowsReusableState: allowsReusableState
        )
    }

    private func processTransient200(
        data: Data,
        contentID: ContentID,
        variantDigest: String,
        request: ImageRequest,
        generation: NamespaceGeneration,
        onFullQualityPreview: (@Sendable (DecodedImage) async throws -> Void)?,
        preparation: ImageDecodePreparation?
    ) async throws -> DecodedImage {
        let decoded = try await delivery.decode(
            data: data,
            contentID: contentID,
            request: request,
            generation: generation,
            keyDigest: variantDigest,
            preparation: preparation
        )
        let rendered = try await delivery.prepareRenderedImage(
            decoded: decoded,
            contentID: contentID,
            request: request,
            generation: generation,
            allowsRenderedMemory: false,
            keyDigest: variantDigest
        )
        try Task.checkCancellation()
        try await requireActive(generation, for: request.namespace)
        if preparation == nil, let onFullQualityPreview {
            try await onFullQualityPreview(rendered.image)
        }
        return try await delivery.publishPreparedRenderedImage(
            rendered,
            request: request,
            generation: generation,
            representation: nil
        )
    }

    private func validatedProgressivePreparation(
        _ finalization: PipelineProgressiveFinalization?,
        response: TimedTransportResponse,
        data: Data
    ) async -> ImageDecodePreparation? {
        guard let finalization, let candidate = await finalization.value() else { return nil }
        let byteCount = response.transport.bodyByteCount
        guard candidate.transportDigestHex == response.transport.digestHex,
            candidate.transportByteCount == byteCount,
            candidate.sourceByteCount == byteCount,
            data.count == byteCount,
            candidate.preparation.probe.format == .jpeg
        else {
            await delivery.discardProgressivePreparation(candidate.preparation)
            return nil
        }
        return candidate.preparation
    }

    func retainTransportVerifiedOriginalOnly(
        _ response: TimedTransportResponse,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws {
        let prepared = try await prepare200Response(response, request: request)
        guard prepared.disposition != .noStore else { return }
        // 取消后的后台路径只保留 transport 已完整接收、受字节上限约束并由流式
        // SHA-256 绑定身份的编码体。容器结构、ImageIO probe、解码和变换全部推迟到
        // 真正存活的消费者；未经这些门禁的字节绝不会进入持久存储或像素发布。
        try Task.checkCancellation()
        try await requireActive(generation, for: request.namespace)
        let representation = reusableRecord(
            response: response,
            request: request,
            generation: generation,
            prepared: prepared
        )
        let payload: TransportVerifiedEncodedHandoffPayload
        if let stagedFileLease = response.transport.stagedFileLease {
            payload = .stagedFile(stagedFileLease)
        } else {
            payload = .memory(try response.transport.materializedBody())
        }
        try await cache.insertTransportVerifiedHandoff(
            payload: payload,
            record: representation,
            request: request,
            generation: generation
        )
    }

    func persistTransportVerifiedHandoff(
        _ entry: TransportVerifiedEncodedHandoffEntry,
        data: Data,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws {
        let contentID = entry.metadata.contentID
        guard contentID.byteCount == data.count else {
            throw PipelineFailure.invalidContentDigest
        }
        let representation = entry.representation(for: request, generation: generation)
        guard
            let preparation = try await cache.prepareOriginalCommit(
                data: data,
                contentID: contentID,
                record: representation,
                namespace: request.namespace,
                generation: generation
            )
        else { return }
        await diagnostics.record(
            DiagnosticEvent(
                kind: .originalCommitPrepared,
                keyDigest: representation.variantKeyDigest,
                byteCount: data.count
            )
        )
        try await cache.publishOriginalCommit(
            preparation,
            contentID: contentID,
            record: representation,
            namespace: request.namespace,
            generation: generation
        )
        await diagnostics.record(
            DiagnosticEvent(
                kind: .originalCommitPublished,
                keyDigest: representation.variantKeyDigest,
                byteCount: data.count
            )
        )
    }

    private func prepareOriginalCommitIfNeeded(
        data: Data,
        contentID: ContentID,
        representation: RepresentationRecord?,
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration,
        keyDigest: String
    ) async throws -> OriginalCommitPreparation? {
        guard let representation else { return nil }
        let preparation = try await cache.prepareOriginalCommit(
            data: data,
            contentID: contentID,
            record: representation,
            namespace: namespace,
            generation: generation
        )
        if preparation != nil {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .originalCommitPrepared,
                    keyDigest: keyDigest,
                    byteCount: data.count
                )
            )
        }
        return preparation
    }

    private func publishOriginalIfNeeded(
        _ preparation: OriginalCommitPreparation?,
        contentID: ContentID,
        representation: RepresentationRecord?,
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration,
        keyDigest: String
    ) async throws {
        guard let preparation, let representation else { return }
        try await cache.publishOriginalCommit(
            preparation,
            contentID: contentID,
            record: representation,
            namespace: namespace,
            generation: generation
        )
        await diagnostics.record(
            DiagnosticEvent(
                kind: .originalCommitPublished,
                keyDigest: keyDigest,
                byteCount: contentID.byteCount
            )
        )
    }

    private struct Prepared200Response {
        let varySelection: HTTPVarySelection?
        let variant: FetchVariantKey
        let contentID: ContentID
        let disposition: CacheDisposition
    }

    private func prepare200Response(
        _ response: TimedTransportResponse,
        request: ImageRequest
    ) async throws -> Prepared200Response {
        try Task.checkCancellation()
        guard response.head.statusCode == 200 else {
            throw PipelineFailure.unsupportedStatus(response.head.statusCode)
        }
        try await validateImageContentType(response, request: request)

        let varySelection = varySelection(response: response, request: request)
        let variant = request.fetchVariantKey(for: varySelection ?? .empty)
        let contentID: ContentID
        do {
            contentID = try ContentID(
                digestHex: response.transport.digestHex,
                byteCount: response.transport.bodyByteCount
            )
        } catch {
            throw PipelineFailure.invalidContentDigest
        }
        let disposition = HTTPCachePolicy.disposition(
            headers: response.head.headers,
            isPrivateNamespace: request.authorizationContext != .public,
            varySelectionAvailable: varySelection != nil
        )
        return Prepared200Response(
            varySelection: varySelection,
            variant: variant,
            contentID: contentID,
            disposition: disposition
        )
    }

    private func validateImageContentType(
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
                keyDigest: request.fetchBaseKey.digestHex,
                reason: "missing-content-type"
            )
        )
    }

    private func varySelection(
        response: TimedTransportResponse,
        request: ImageRequest
    ) -> HTTPVarySelection? {
        switch HTTPCachePolicy.varyFieldNames(in: response.head.headers) {
        case .wildcard, .unrepresentable:
            return nil
        case .fields(let fields):
            return request.varySelection(fieldNames: fields)
        }
    }

    private func reusableRecord(
        response: TimedTransportResponse,
        request: ImageRequest,
        generation: NamespaceGeneration,
        prepared: Prepared200Response
    ) -> RepresentationRecord {
        let record = RepresentationRecord(
            securityNamespace: request.namespace.value,
            namespaceGeneration: generation.value,
            baseKeyDigest: request.fetchBaseKey.digestHex,
            variantKeyDigest: prepared.variant.digestHex,
            vary: prepared.varySelection ?? .empty,
            statusCode: 200,
            requestTime: response.requestTime,
            responseTime: response.responseTime,
            responseDate: HTTPCachePolicy.responseDate(in: response.head.headers),
            expiresAt: HTTPCachePolicy.expiration(
                requestTime: response.requestTime,
                responseTime: response.responseTime,
                headers: response.head.headers
            ),
            etag: response.head.value(forHeader: "ETag"),
            lastModified: response.head.value(forHeader: "Last-Modified"),
            disposition: prepared.disposition,
            requiresRevalidation: HTTPCachePolicy.requiresRevalidation(
                headers: response.head.headers
            ),
            contentID: prepared.contentID.description,
            payloadLength: response.transport.bodyByteCount,
            contentType: response.head.value(forHeader: "Content-Type")
        )
        return record
    }

    private func cached304Body(
        existing: RepresentationRecord,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws -> Cached304Body {
        do {
            return .data(try await cache.read(existing, namespace: request.namespace))
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as PipelineFailure where failure.disposition == .cancelled {
            throw failure
        } catch {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .cacheReadFailed,
                    keyDigest: existing.variantKeyDigest,
                    reason: "validated-body-read"
                )
            )
            await cache.removeRecord(
                existing.variantKeyDigest,
                namespace: request.namespace,
                generation: generation
            )
            let retry = try await fetchStage.response(
                for: request,
                conditionalRecord: nil,
                generation: generation
            )
            return .recovered(
                try await process200(
                    retry,
                    request: request,
                    generation: generation
                )
            )
        }
    }

    private func revalidationMetadata(
        response: TimedTransportResponse,
        existing: RepresentationRecord,
        request: ImageRequest
    ) -> RevalidationMetadata {
        let cacheControlPresent =
            HTTPCachePolicy.header("Cache-Control", in: response.head.headers) != nil
        let varyHeaderPresent = HTTPCachePolicy.header("Vary", in: response.head.headers) != nil
        let vary: HTTPVarySelection?
        if varyHeaderPresent {
            switch HTTPCachePolicy.varyFieldNames(in: response.head.headers) {
            case .wildcard, .unrepresentable:
                vary = nil
            case .fields(let fields):
                vary = request.varySelection(fieldNames: fields)
            }
        } else {
            vary = existing.vary
        }
        let overridesDisposition = cacheControlPresent || varyHeaderPresent
        let disposition =
            overridesDisposition
            ? HTTPCachePolicy.disposition(
                headers: response.head.headers,
                isPrivateNamespace: request.authorizationContext != .public,
                varySelectionAvailable: vary != nil
            )
            : existing.disposition
        return RevalidationMetadata(
            vary: vary ?? existing.vary,
            disposition: disposition,
            cacheControlPresent: cacheControlPresent
        )
    }

    private func deliverNoStore304(
        cachedData: Data,
        existing: RepresentationRecord,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws -> DecodedImage {
        await cache.discardReusableState(
            record: existing,
            namespace: request.namespace,
            generation: generation
        )
        let contentID = ContentID(data: cachedData)
        let decoded = try await delivery.decode(
            data: cachedData,
            contentID: contentID,
            request: request,
            generation: generation,
            keyDigest: existing.variantKeyDigest
        )
        return try await delivery.transformAndPublish(
            decoded: decoded,
            contentID: contentID,
            request: request,
            generation: generation,
            allowsRenderedMemory: false,
            representation: nil,
            keyDigest: existing.variantKeyDigest
        )
    }

    private func refreshedRecord(
        response: TimedTransportResponse,
        existing: RepresentationRecord,
        request: ImageRequest,
        generation: NamespaceGeneration,
        metadata: RevalidationMetadata
    ) -> RepresentationRecord {
        let refreshedVariant = request.fetchVariantKey(for: metadata.vary)
        return RepresentationRecord(
            securityNamespace: request.namespace.value,
            namespaceGeneration: generation.value,
            baseKeyDigest: request.fetchBaseKey.digestHex,
            variantKeyDigest: refreshedVariant.digestHex,
            vary: metadata.vary,
            statusCode: existing.statusCode,
            requestTime: response.requestTime,
            responseTime: response.responseTime,
            responseDate: HTTPCachePolicy.responseDate(in: response.head.headers)
                ?? existing.responseDate,
            expiresAt: HTTPCachePolicy.expiration(
                requestTime: response.requestTime,
                responseTime: response.responseTime,
                headers: response.head.headers
            ) ?? existing.expiresAt,
            etag: HTTPCachePolicy.header("ETag", in: response.head.headers) ?? existing.etag,
            lastModified: HTTPCachePolicy.header("Last-Modified", in: response.head.headers)
                ?? existing.lastModified,
            disposition: metadata.disposition,
            requiresRevalidation: metadata.cacheControlPresent
                ? HTTPCachePolicy.requiresRevalidation(headers: response.head.headers)
                : existing.requiresRevalidation,
            contentID: existing.contentID,
            payloadLength: existing.payloadLength,
            contentType: existing.contentType
        )
    }

    private func refreshRecord(
        replacing oldRecord: RepresentationRecord,
        with newRecord: RepresentationRecord,
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration
    ) async throws {
        do {
            try await cache.refresh(
                replacing: oldRecord,
                with: newRecord,
                namespace: namespace,
                generation: generation
            )
        } catch let failure as PipelineFailure where failure.category == .namespaceRevoked {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .cacheWriteFailed,
                    keyDigest: newRecord.variantKeyDigest,
                    reason: "record-refresh-write"
                )
            )
        }
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
