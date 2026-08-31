import AkashicCore
import Foundation
import FoveaHTTP
import FoveaStorage
import ImageCraftCore

/// 在已选中的新鲜 HTTP 表征内协调派生工件命中、再授权和后台创建。
final class DerivedRasterLoadCoordinator: Sendable {
    private let runtime: DerivedRasterRuntime
    private let cache: PipelineCache
    private let delivery: ImageDeliveryCoordinator
    private let namespaceRegistry: NamespaceRegistry
    private let clock: any WallClock

    init(
        runtime: DerivedRasterRuntime,
        cache: PipelineCache,
        delivery: ImageDeliveryCoordinator,
        namespaceRegistry: NamespaceRegistry,
        clock: any WallClock
    ) {
        self.runtime = runtime
        self.cache = cache
        self.delivery = delivery
        self.namespaceRegistry = namespaceRegistry
        self.clock = clock
    }

    func lookupArtifactKey(
        contentID: ContentID,
        request: ImageRequest,
        representation: RepresentationRecord,
        generation: NamespaceGeneration,
        format: DerivedRasterFormatIdentity
    ) -> DerivedRasterArtifactKey? {
        guard
            let key = DerivedRasterArtifactKey(
                validatedRequest: request,
                validatedRepresentation: representation,
                representedContentID: contentID,
                namespaceGeneration: generation,
                renderKey: delivery.renderKey(contentID: contentID, request: request),
                format: format
            ), DerivedRasterContainer.isCompatible(with: key)
        else { return nil }
        return key
    }

    func creationArtifactKey(
        contentID: ContentID,
        request: ImageRequest,
        image: DecodedImage,
        representation: RepresentationRecord,
        generation: NamespaceGeneration
    ) -> DerivedRasterArtifactKey? {
        guard
            let format = DerivedRasterContainer.creationFormatIdentity(
                for: image,
                colorPolicy: request.colorPolicy
            ),
            let key = DerivedRasterArtifactKey(
                validatedRequest: request,
                validatedRepresentation: representation,
                representedContentID: contentID,
                namespaceGeneration: generation,
                renderKey: delivery.renderKey(contentID: contentID, request: request),
                format: format
            ),
            DerivedRasterContainer.isCompatible(with: key)
        else { return nil }
        return key
    }

    func imageIfPresent(
        key: DerivedRasterArtifactKey,
        request: ImageRequest,
        representation: RepresentationRecord,
        generation: NamespaceGeneration
    ) async throws -> DecodedImage? {
        guard let loaded = try await runtime.load(key: key) else { return nil }
        try Task.checkCancellation()
        guard
            await reuseIsCurrentlyAuthorized(
                key: key,
                request: request,
                generation: generation,
                requiresNamespaceActiveCheck: false
            )
        else { return nil }
        return try await delivery.publishDerivedRaster(
            loaded,
            request: request,
            generation: generation
        )
    }

    func scheduleCreation(
        key: DerivedRasterArtifactKey,
        request: ImageRequest,
        image: DecodedImage,
        representation: RepresentationRecord,
        originalByteCount: Int,
        originalDecodeNanoseconds: UInt64,
        generation: NamespaceGeneration
    ) async {
        _ = await runtime.scheduleCreation(
            key: key,
            request: request,
            image: image,
            representation: representation,
            originalByteCount: originalByteCount,
            originalDecodeNanoseconds: originalDecodeNanoseconds,
            authorization: { [weak self] in
                guard let self else { return false }
                return await self.reuseIsCurrentlyAuthorized(
                    key: key,
                    request: request,
                    generation: generation
                )
            }
        )
    }

    private func reuseIsCurrentlyAuthorized(
        key: DerivedRasterArtifactKey,
        request: ImageRequest,
        generation: NamespaceGeneration,
        requiresNamespaceActiveCheck: Bool = true
    ) async -> Bool {
        if requiresNamespaceActiveCheck {
            guard
                await namespaceRegistry.isActive(
                    generation,
                    for: request.storageNamespaceFingerprint
                )
            else { return false }
        }
        let selected: RepresentationRecord
        if let unique = cache.uniqueRecord(
            for: key.variantKeyDigest,
            baseKeyDigest: key.baseKeyDigest,
            namespaceFingerprint: request.storageNamespaceFingerprint,
            generation: generation
        ) {
            guard
                HTTPCachePolicy.recordMatchesRequest(
                    unique,
                    requestHeaders: request.headers,
                    additionalSensitiveNames: request.credentialHeaderNames,
                    sensitiveFingerprints: request.headerVariantFingerprints
                )
            else { return false }
            selected = unique
        } else {
            let candidates = await cache.records(
                for: request.fetchBaseDigest,
                namespace: request.namespace,
                namespaceFingerprint: request.storageNamespaceFingerprint,
                generation: generation
            )
            guard
                let current = HTTPCachePolicy.selectRecord(
                    from: candidates,
                    requestHeaders: request.headers,
                    additionalSensitiveNames: request.credentialHeaderNames,
                    sensitiveFingerprints: request.headerVariantFingerprints
                ), current.variantKeyDigest == key.variantKeyDigest
            else { return false }
            selected = current
        }
        return DerivedRasterReusePolicy.permitsValidatedRepresentation(
            key: key,
            request: request,
            currentRepresentation: selected,
            namespaceGeneration: generation,
            namespaceIsActive: true,
            now: await clock.now()
        )
    }
}

/// 读取并验证持久化 derived artifact，但不参与 HTTP reuse authority；发布前仍由调用方执行实时 representation/namespace 授权。
struct DerivedRasterArtifactReader: Sendable {
    let store: any DerivedRasterStoring
    let diagnostics: any DiagnosticsSink
    let hotArtifacts:
        FoveaCompactSieveCache<
            DerivedRasterArtifactKey, DerivedRasterCompressedSurface
        >

    func load(key: DerivedRasterArtifactKey) async throws -> DerivedRasterLoadedImage? {
        if let loaded = try loadHotArtifact(key: key) { return loaded }
        guard let artifact = try await loadStoredArtifact(key: key) else { return nil }
        return try await validatedStoredArtifact(artifact, key: key)
    }

    private func loadHotArtifact(
        key: DerivedRasterArtifactKey
    ) throws -> DerivedRasterLoadedImage? {
        guard let surface = hotArtifacts.value(for: key) else { return nil }
        do {
            let image = try lazyImage(from: surface, matching: key)
            try Task.checkCancellation()
            return DerivedRasterLoadedImage(image: image, key: key)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 损坏或陈旧的内存值只属于本层；只有独立 store 读取也验证失败后，才删除 durable alias。
            hotArtifacts.remove(key)
            return nil
        }
    }

    private func loadStoredArtifact(
        key: DerivedRasterArtifactKey
    ) async throws -> DerivedRasterStoredArtifact? {
        do {
            return try await store.load(
                artifactKeyDigest: key.digestHex,
                namespaceFingerprint: key.namespaceFingerprint,
                namespaceGeneration: key.namespaceGeneration.value
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AkashicError where Self.isInvalidStoredArtifact(error) {
            await discardInvalidArtifact(key)
            return nil
        } catch {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .cacheReadFailed,
                    keyDigest: key.digestHex,
                    reason: "derived-raster-store-read-failed"
                )
            )
            return nil
        }
    }

    private func validatedStoredArtifact(
        _ artifact: DerivedRasterStoredArtifact,
        key: DerivedRasterArtifactKey
    ) async throws -> DerivedRasterLoadedImage? {
        do {
            if artifact.recordValidated && artifact.containerContentDigestVerified {
                return try validatedTrustedArtifact(artifact, key: key)
            }
            return try validatedUntrustedArtifact(artifact, key: key)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await discardInvalidArtifact(key)
            return nil
        }
    }

    private func validatedTrustedArtifact(
        _ artifact: DerivedRasterStoredArtifact,
        key: DerivedRasterArtifactKey
    ) throws -> DerivedRasterLoadedImage {
        guard
            let surface = DerivedRasterArtifactValidator.validatedCompressedSurface(
                record: artifact.record,
                container: artifact.container,
                matching: key,
                recordAlreadyValidated: true,
                containerContentDigestAlreadyVerified: true
            )
        else { throw DerivedRasterContainerError.integrityMismatch }
        let image = try lazyImage(from: surface, matching: key)
        try Task.checkCancellation()
        hotArtifacts.insert(surface, for: key, cost: surface.residentByteCount)
        return DerivedRasterLoadedImage(image: image, key: key)
    }

    private func validatedUntrustedArtifact(
        _ artifact: DerivedRasterStoredArtifact,
        key: DerivedRasterArtifactKey
    ) throws -> DerivedRasterLoadedImage {
        guard
            let surface = DerivedRasterArtifactValidator.validatedSurface(
                record: artifact.record,
                container: artifact.container,
                matching: key,
                containerContentDigestAlreadyVerified: false,
                verifyDecodedPixelDigest: true
            ),
            let sourceProfile = DerivedRasterContainer.sourceColorProfile(for: key.format)
        else { throw DerivedRasterContainerError.integrityMismatch }
        let image = try DerivedRasterPixelBridge.image(
            from: surface,
            sourceColorProfile: sourceProfile
        )
        try Task.checkCancellation()
        return DerivedRasterLoadedImage(image: image, key: key)
    }

    private func lazyImage(
        from surface: DerivedRasterCompressedSurface,
        matching key: DerivedRasterArtifactKey
    ) throws -> DecodedImage {
        guard let sourceProfile = DerivedRasterContainer.sourceColorProfile(for: key.format)
        else { throw DerivedRasterContainerError.unsupportedFormat }
        return try DerivedRasterPixelBridge.lazyImage(
            from: surface,
            sourceColorProfile: sourceProfile
        )
    }

    private func discardInvalidArtifact(_ key: DerivedRasterArtifactKey) async {
        try? await store.remove(
            artifactKeyDigest: key.digestHex,
            namespaceFingerprint: key.namespaceFingerprint,
            namespaceGeneration: key.namespaceGeneration.value
        )
        await diagnostics.record(
            DiagnosticEvent(
                kind: .cacheReadFailed,
                keyDigest: key.digestHex,
                reason: "derived-raster-read-invalid"
            )
        )
    }

    private static func isInvalidStoredArtifact(_ error: AkashicError) -> Bool {
        switch error {
        case .notFound, .invalidIdentity, .integrityMismatch, .invalidManifest,
            .unsupportedSchema:
            true
        case .unsupportedCapability, .limitExceeded, .storageUnavailable,
            .transactionConflict:
            false
        }
    }
}

struct ReusableImageLookup {
    let conditionalRecord: RepresentationRecord?
    let image: DecodedImage?
}

/// 为已授权的单一 namespace generation 解析可复用图像层级；selection、rendered memory、derived raster 与原始 encoded reuse 的顺序保持显式。
struct ReusableImageLookupCoordinator: Sendable {
    let cache: PipelineCache
    let fetchStage: FetchStage
    let delivery: ImageDeliveryCoordinator
    let diagnostics: any DiagnosticsSink
    let clock: any WallClock
    let derivedRaster: DerivedRasterLoadCoordinator?

    func lookup(
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws -> ReusableImageLookup {
        guard let selected = await selectedRecord(request: request, generation: generation) else {
            return ReusableImageLookup(conditionalRecord: nil, image: nil)
        }
        guard selected.isFresh(at: await clock.now()), selected.disposition != .noStore else {
            return ReusableImageLookup(conditionalRecord: selected, image: nil)
        }
        guard
            let contentID = await validatedContentID(
                selected,
                request: request,
                generation: generation
            )
        else {
            return ReusableImageLookup(conditionalRecord: nil, image: nil)
        }
        return try await lookupFresh(
            selected,
            contentID: contentID,
            request: request,
            generation: generation
        )
    }

    private func selectedRecord(
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async -> RepresentationRecord? {
        let candidates = await cache.records(
            for: request.fetchBaseDigest,
            namespace: request.namespace,
            namespaceFingerprint: request.storageNamespaceFingerprint,
            generation: generation
        )
        return HTTPCachePolicy.selectRecord(
            from: candidates,
            requestHeaders: request.headers,
            additionalSensitiveNames: request.credentialHeaderNames,
            sensitiveFingerprints: request.headerVariantFingerprints
        )
    }

    private func validatedContentID(
        _ selected: RepresentationRecord,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async -> ContentID? {
        guard
            let contentID = ContentID(
                persistentDescription: selected.contentID,
                expectedByteCount: selected.payloadLength
            )
        else {
            await cache.removeRecord(
                selected.variantKeyDigest,
                namespace: request.namespace,
                generation: generation
            )
            return nil
        }
        return contentID
    }

    private func lookupFresh(
        _ selected: RepresentationRecord,
        contentID: ContentID,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws -> ReusableImageLookup {
        if let rendered = try await delivery.renderedImageIfPresent(
            contentID: contentID,
            request: request,
            generation: generation,
            keyDigest: selected.variantKeyDigest
        ) {
            return ReusableImageLookup(conditionalRecord: selected, image: rendered)
        }
        if let derived = try await derivedRasterImage(
            selected,
            contentID: contentID,
            request: request,
            generation: generation
        ) {
            return ReusableImageLookup(conditionalRecord: selected, image: derived)
        }
        return try await originalEncodedImage(
            selected,
            contentID: contentID,
            request: request,
            generation: generation
        )
    }

    private func derivedRasterImage(
        _ selected: RepresentationRecord,
        contentID: ContentID,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws -> DecodedImage? {
        guard let derivedRaster else { return nil }
        var constructedKey = false
        for format in DerivedRasterContainer.lookupFormatIdentities(for: request.colorPolicy) {
            guard
                let key = derivedRaster.lookupArtifactKey(
                    contentID: contentID,
                    request: request,
                    representation: selected,
                    generation: generation,
                    format: format
                )
            else { continue }
            constructedKey = true
            if let image = try await derivedRaster.imageIfPresent(
                key: key,
                request: request,
                representation: selected,
                generation: generation
            ) {
                return image
            }
        }
        if !constructedKey {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .cacheWriteFailed,
                    keyDigest: selected.variantKeyDigest,
                    reason: "derived-raster-key-ineligible"
                )
            )
        }
        return nil
    }

    private func originalEncodedImage(
        _ selected: RepresentationRecord,
        contentID: ContentID,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws -> ReusableImageLookup {
        guard
            let data = try await readCachedData(
                record: selected,
                request: request,
                generation: generation,
                failureReason: "original-encoded-read"
            )
        else { return ReusableImageLookup(conditionalRecord: nil, image: nil) }
        await diagnostics.record(
            DiagnosticEvent(
                kind: .originalEncodedHit,
                keyDigest: selected.variantKeyDigest,
                byteCount: data.count
            )
        )
        let started = DispatchTime.now().uptimeNanoseconds
        let image = try await delivery.imageFromReusableData(
            data: data,
            request: request,
            generation: generation,
            representation: selected,
            keyDigest: selected.variantKeyDigest
        )
        await scheduleDerivedRaster(
            image,
            dataByteCount: data.count,
            decodeNanoseconds: DispatchTime.now().uptimeNanoseconds &- started,
            selected: selected,
            contentID: contentID,
            request: request,
            generation: generation
        )
        return ReusableImageLookup(conditionalRecord: selected, image: image)
    }

    private func scheduleDerivedRaster(
        _ image: DecodedImage,
        dataByteCount: Int,
        decodeNanoseconds: UInt64,
        selected: RepresentationRecord,
        contentID: ContentID,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async {
        guard let derivedRaster,
            let key = derivedRaster.creationArtifactKey(
                contentID: contentID,
                request: request,
                image: image,
                representation: selected,
                generation: generation
            )
        else { return }
        await derivedRaster.scheduleCreation(
            key: key,
            request: request,
            image: image,
            representation: selected,
            originalByteCount: dataByteCount,
            originalDecodeNanoseconds: decodeNanoseconds,
            generation: generation
        )
    }

    func readCachedData(
        record: RepresentationRecord,
        request: ImageRequest,
        generation: NamespaceGeneration,
        failureReason: String
    ) async throws -> Data? {
        do {
            return try await cache.read(record, namespace: request.namespace)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as PipelineFailure where failure.disposition == .cancelled {
            throw failure
        } catch {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .cacheReadFailed,
                    keyDigest: record.variantKeyDigest,
                    reason: failureReason
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
}
