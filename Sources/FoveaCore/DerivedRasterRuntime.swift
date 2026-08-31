import AkashicCore
import CoreGraphics
import CryptoKit
import Foundation
import FoveaHTTP
import FoveaStorage
import ImageCraftCore

/// 将默认关闭的派生光栅读取、后台创建与撤销清理收敛在一个包内协作者中。
///
/// 它不选择 HTTP 表征，也不授予复用权限。调用方在读取前后与发布期间都必须提供
/// 当前表征授权；任何派生失败均回退到原编码路径。
package final class DerivedRasterRuntime: Sendable {
    package typealias PublicationAuthorization = @Sendable () async -> Bool

    private let configuration: DerivedRasterRuntimeConfiguration
    private let store: any DerivedRasterStoring
    private let namespaceRegistry: NamespaceRegistry
    private let diagnostics: any DiagnosticsSink
    private let clock: any WallClock
    private let costEstimator: any DerivedRasterCostEstimating
    private let creationCoordinator: DerivedRasterCreationCoordinator
    private let creationPermits: AsyncPermitPool
    private let reuseObservations = DerivedRasterReuseObservationTracker()
    private let hotArtifacts: FoveaCompactSieveCache<
        DerivedRasterArtifactKey, DerivedRasterCompressedSurface
    >
    private let creationExecutor = DispatchWorkExecutor(
        label: "dev.fovea.derived-raster.creation",
        qos: .utility,
        concurrent: true
    )

    package init(
        configuration: DerivedRasterRuntimeConfiguration,
        store: any DerivedRasterStoring,
        namespaceRegistry: NamespaceRegistry,
        diagnostics: any DiagnosticsSink,
        clock: any WallClock,
        costEstimator: any DerivedRasterCostEstimating = LiveDerivedRasterCostEstimator()
    ) {
        self.configuration = configuration
        self.store = store
        self.namespaceRegistry = namespaceRegistry
        self.diagnostics = diagnostics
        self.clock = clock
        self.costEstimator = costEstimator
        creationCoordinator = DerivedRasterCreationCoordinator(
            maximumEntryCount:
                configuration.maximumConcurrentCreations + configuration.maximumQueuedCreations
        )
        creationPermits = AsyncPermitPool(
            limit: configuration.maximumConcurrentCreations,
            queueLimit: configuration.maximumQueuedCreations
        )
        hotArtifacts = FoveaCompactSieveCache(
            costLimit: configuration.maximumHotContainerMemoryBytes
        )
    }

    package func load(
        key: DerivedRasterArtifactKey
    ) async throws -> DerivedRasterLoadedImage? {
        try await DerivedRasterArtifactReader(
            store: store,
            diagnostics: diagnostics,
            hotArtifacts: hotArtifacts
        ).load(key: key)
    }

    @discardableResult
    package func scheduleCreation(
        key: DerivedRasterArtifactKey,
        request: ImageRequest,
        image: DecodedImage,
        representation: RepresentationRecord,
        originalByteCount: Int,
        originalDecodeNanoseconds: UInt64,
        authorization: @escaping PublicationAuthorization
    ) async -> Bool {
        guard DerivedRasterContainer.isCompatible(with: key) else {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .cacheWriteFailed,
                    keyDigest: key.digestHex,
                    reason: "derived-raster-format-unsupported"
                )
            )
            return false
        }
        guard
            await creationInputIsValid(
                key: key,
                image: image,
                originalByteCount: originalByteCount,
                originalDecodeNanoseconds: originalDecodeNanoseconds
            )
        else { return false }

        let observation = await reuseObservations.observe(key)
        guard observation.shouldAttemptCreation else { return false }

        return await creationCoordinator.schedule(
            key: key,
            create: { [self] in
                do {
                    return try await createProduct(
                        key: key,
                        request: request,
                        image: image,
                        representation: representation,
                        originalByteCount: originalByteCount,
                        originalDecodeNanoseconds: originalDecodeNanoseconds,
                        observedReuseHits: observation.hitCount
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as DerivedRasterRuntimeError {
                    throw error
                } catch let error as DerivedRasterCreationStageFailure {
                    await recordCreationRejection(key: key, reason: error.reason)
                    throw error
                } catch {
                    await recordCreationRejection(
                        key: key,
                        reason: error is DerivedRasterContainerError
                            ? "derived-raster-container-create-failed"
                            : "derived-raster-create-failed"
                    )
                    throw error
                }
            },
            publish: { [self] product, lease in
                try await publish(
                    product,
                    key: key,
                    lease: lease,
                    authorization: authorization
                )
            }
        )
    }

    package func revoke(namespaceFingerprint: StorageNamespaceFingerprint) async -> Bool {
        hotArtifacts.removeAll { $0.namespaceFingerprint == namespaceFingerprint }
        await creationCoordinator.cancelAll(namespaceFingerprint: namespaceFingerprint)
        await reuseObservations.removeAll(namespaceFingerprint: namespaceFingerprint)
        do {
            try await store.removeAll(namespaceFingerprint: namespaceFingerprint)
            return false
        } catch {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .cacheWriteFailed,
                    reason: "derived-raster-namespace-cleanup"
                )
            )
            return true
        }
    }

    @discardableResult
    package func purgeHotContainers() -> Int {
        hotArtifacts.removeAllAndReport().itemCount
    }

    package func cancelAllCreations() async {
        await creationCoordinator.cancelAll()
        await reuseObservations.removeAll()
    }

    package func creationActivity() async -> DerivedRasterCreationActivity {
        await creationCoordinator.activitySnapshot()
    }

    package func waitUntilCreationQuiescent(
        after baseline: DerivedRasterCreationActivity
    ) async -> DerivedRasterCreationActivity {
        await creationCoordinator.waitUntilQuiescent(after: baseline)
    }

    private func creationInputIsValid(
        key: DerivedRasterArtifactKey,
        image: DecodedImage,
        originalByteCount: Int,
        originalDecodeNanoseconds: UInt64
    ) async -> Bool {
        let reason: String?
        if !DerivedRasterContainer.isCompatible(with: key) {
            reason = "derived-raster-format-unsupported"
        } else if image.alphaMode != .none {
            reason = "derived-raster-alpha-unsupported"
        } else if originalByteCount <= 0 || originalDecodeNanoseconds == 0 {
            reason = "derived-raster-invalid-source-metrics"
        } else {
            reason = nil
        }
        guard let reason else { return true }
        await diagnostics.record(
            DiagnosticEvent(kind: .cacheWriteFailed, keyDigest: key.digestHex, reason: reason)
        )
        return false
    }

    private func createProduct(
        key: DerivedRasterArtifactKey,
        request: ImageRequest,
        image: DecodedImage,
        representation: RepresentationRecord,
        originalByteCount: Int,
        originalDecodeNanoseconds: UInt64,
        observedReuseHits: Int
    ) async throws -> DerivedRasterCreationProduct {
        let permit = try await creationPermits.acquire(
            priority: .background,
            workEstimate: max(1, image.estimatedByteCost)
        )
        return try await permit.withPermit {
            let started = DispatchTime.now().uptimeNanoseconds
            let candidate = try await encodeCandidate(image: image, key: key)
            let creationNanoseconds = DispatchTime.now().uptimeNanoseconds &- started
            let createdAt = try await requireAdmission(
                candidate: candidate,
                key: key,
                request: request,
                representation: representation,
                originalByteCount: originalByteCount,
                originalDecodeNanoseconds: originalDecodeNanoseconds,
                observedReuseHits: observedReuseHits,
                creationNanoseconds: creationNanoseconds
            )
            let product = try makeProduct(candidate: candidate, key: key, createdAt: createdAt)
            guard
                DerivedRasterArtifactValidator.validatedSurface(
                    record: product.record,
                    container: product.container,
                    matching: key
                ) != nil
            else {
                await recordCreationRejection(
                    key: key,
                    byteCount: product.container.count,
                    reason: "derived-raster-product-mismatch"
                )
                throw DerivedRasterContainerError.integrityMismatch
            }
            return product
        }
    }

    private func encodeCandidate(
        image: DecodedImage,
        key: DerivedRasterArtifactKey
    ) async throws -> DerivedRasterEncodedCandidate {
        try await DerivedRasterCandidateEncoder.encode(
            image: image,
            key: key,
            configuration: configuration,
            executor: creationExecutor
        )
    }



    private func requireAdmission(
        candidate: DerivedRasterEncodedCandidate,
        key: DerivedRasterArtifactKey,
        request: ImageRequest,
        representation: RepresentationRecord,
        originalByteCount: Int,
        originalDecodeNanoseconds: UInt64,
        observedReuseHits: Int,
        creationNanoseconds: UInt64
    ) async throws -> Date {
        let createdAt = await clock.now()
        let measuredRead = Self.saturatedAdd(
            candidate.measuredReadNanoseconds,
            configuration.estimatedPersistentReadOverheadNanoseconds
        )
        guard
            let cost = costEstimator.estimate(
                key: key,
                measuredOriginalDecodeNanoseconds: originalDecodeNanoseconds,
                measuredDerivedReadNanoseconds: measuredRead
            )
        else {
            await reuseObservations.recordTransientFailure(key)
            await recordCreationRejection(
                key: key,
                reason: "derived-raster-cost-sample-unavailable"
            )
            throw DerivedRasterRuntimeError.admissionRejected
        }
        let decision = DerivedRasterAdmissionPolicy.evaluate(
            request: request,
            representation: representation,
            namespaceGeneration: key.namespaceGeneration,
            namespaceIsActive: await namespaceRegistry.isActive(
                key.namespaceGeneration,
                for: key.namespaceFingerprint
            ),
            renderKey: key.renderKey,
            format: key.format,
            now: createdAt,
            creationRunsInBackground: true,
            observedReuseHits: observedReuseHits,
            originalDecodeNanoseconds: cost.originalDecodeNanoseconds,
            derivedReadNanoseconds: cost.derivedReadNanoseconds,
            creationNanoseconds: creationNanoseconds,
            maximumCreationNanoseconds: configuration.maximumCreationNanoseconds,
            derivedByteCount: candidate.container.count,
            maximumDerivedByteCount: maximumDerivedBytes(originalByteCount),
            safetyMarginHits: configuration.safetyMarginHits
        )
        guard case .admit = decision else {
            if case .reject(let rejection) = decision {
                await reuseObservations.recordRejection(rejection, for: key)
                await recordCreationRejection(
                    key: key,
                    byteCount: candidate.container.count,
                    durationNanoseconds: creationNanoseconds,
                    reason: Self.reason(for: rejection)
                )
            }
            throw DerivedRasterRuntimeError.admissionRejected
        }
        return createdAt
    }

    private func makeProduct(
        candidate: DerivedRasterEncodedCandidate,
        key: DerivedRasterArtifactKey,
        createdAt: Date
    ) throws -> DerivedRasterCreationProduct {
        let contentID = ContentID(data: candidate.container)
        let format = key.format
        let record = try DerivedRasterRecord(
            artifactKeyDigest: key.digestHex,
            baseKeyDigest: key.baseKeyDigest,
            variantKeyDigest: key.variantKeyDigest,
            namespaceFingerprint: key.namespaceFingerprint,
            namespaceGeneration: key.namespaceGeneration.value,
            containerContentID: contentID.description,
            containerByteCount: contentID.byteCount,
            formatIdentifier: format.identifier,
            formatSemanticVersion: format.semanticVersion,
            pixelLayoutFingerprint: format.pixelLayoutFingerprint,
            pixelDigestHex: candidate.surface.pixelDigestHex,
            pixelWidth: candidate.surface.width,
            pixelHeight: candidate.surface.height,
            createdAt: createdAt
        )
        return DerivedRasterCreationProduct(container: candidate.container, record: record)
    }

    private func publish(
        _ product: DerivedRasterCreationProduct,
        key: DerivedRasterArtifactKey,
        lease: any DerivedRasterPublicationPermission,
        authorization: @escaping PublicationAuthorization
    ) async throws {
        let permission = DerivedRasterDynamicPublicationPermission(
            base: lease,
            authorization: authorization
        )
        do {
            try await store.commit(
                container: product.container,
                record: product.record,
                publicationPermission: permission
            )
            await reuseObservations.markPublished(key)
        } catch {
            await reuseObservations.recordTransientFailure(key)
            let storeError = error as? DerivedRasterStoreError
            let reason = storeError?.diagnosticReason ?? "derived-raster-publication-failed"
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .cacheWriteFailed,
                    keyDigest: key.digestHex,
                    byteCount: storeError?.logicalWriteChargeBytes ?? product.container.count,
                    reason: reason
                )
            )
            throw error
        }
    }

    private func recordCreationRejection(
        key: DerivedRasterArtifactKey,
        byteCount: Int? = nil,
        durationNanoseconds: UInt64? = nil,
        reason: String
    ) async {
        await diagnostics.record(
            DiagnosticEvent(
                kind: .cacheWriteFailed,
                keyDigest: key.digestHex,
                byteCount: byteCount,
                reason: reason,
                durationNanoseconds: durationNanoseconds
            )
        )
    }

    private func maximumDerivedBytes(_ originalByteCount: Int) -> Int {
        min(
            configuration.maximumContainerBytes,
            Self.scaledByteBudget(
                originalByteCount,
                permille: configuration.maximumContainerToOriginalPermille
            )
        )
    }

    private static func reason(for rejection: DerivedRasterAdmissionRejection) -> String {
        if rejection == .invalidArtifactIdentity { return "derived-raster-invalid-identity" }
        if rejection == .unsupportedFormatForRender { return "derived-raster-format-unsupported" }
        if rejection == .foregroundCreation { return "derived-raster-foreground-creation" }
        if rejection == .inactiveNamespace { return "derived-raster-namespace-inactive" }
        if rejection == .staleRepresentation { return "derived-raster-representation-stale" }
        if rejection == .requiresRevalidation { return "derived-raster-revalidation-required" }
        if rejection == .invalidMetrics { return "derived-raster-invalid-metrics" }
        if rejection == .noReadSavings { return "derived-raster-no-read-savings" }
        return budgetReason(for: rejection)
    }

    private static func budgetReason(for rejection: DerivedRasterAdmissionRejection) -> String {
        switch rejection {
        case .creationBudgetExceeded: "derived-raster-creation-budget"
        case .byteBudgetExceeded: "derived-raster-byte-budget"
        case .insufficientObservedReuse: "derived-raster-insufficient-observed-reuse"
        default: preconditionFailure("Non-budget rejection reached budgetReason")
        }
    }


    private static func scaledByteBudget(_ bytes: Int, permille: Int) -> Int {
        let product = bytes.multipliedReportingOverflow(by: permille)
        guard !product.overflow else { return Int.max }
        return max(1, product.partialValue / 1000)
    }

    private static func saturatedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }
}

private enum DerivedRasterRuntimeError: Error {
    case admissionRejected
}

struct DerivedRasterCreationStageFailure: Error, Sendable {
    let reason: String
}

private struct DerivedRasterDynamicPublicationPermission: DerivedRasterPublicationPermission {
    let base: any DerivedRasterPublicationPermission
    let authorization: DerivedRasterRuntime.PublicationAuthorization

    func permitsPublication() async -> Bool {
        guard await base.permitsPublication() else { return false }
        return await authorization()
    }
}
