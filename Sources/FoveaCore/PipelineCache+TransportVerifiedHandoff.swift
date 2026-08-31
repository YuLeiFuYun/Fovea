import AkashicCore
import AkashicMemory
import Foundation
import FoveaHTTP
import FoveaStorage
import ImageCraftCore

/// 标识一次仅具备传输完整性、尚未获得图像合法性证明的临时编码体。
///
/// 本文件负责 public/automatic 请求的短生命周期 handoff 准入、精确身份查询与撤销；
/// 它不得授予持久化权限，也不得跳过后续 probe、decode、namespace generation 和新鲜度门禁。
struct ScopedTransportVerifiedHandoffKey: Hashable, Sendable {
    let namespace: SecurityNamespaceID
    let generation: NamespaceGeneration
    let executionDigest: String
}

enum TransportVerifiedEncodedHandoffPayload: Sendable {
    case memory(Data)
    case stagedFile(TransportStagedFileLease)

    var byteCount: Int {
        switch self {
        case .memory(let data): data.count
        case .stagedFile(let lease): lease.byteCount
        }
    }

    func materializedData() throws -> Data {
        switch self {
        case .memory(let data): data
        case .stagedFile(let lease): try lease.mappedData()
        }
    }
}

struct TransportVerifiedEncodedHandoffMetadata: Codable, Sendable {
    let vary: HTTPVarySelection
    let requestTime: Date
    let responseTime: Date
    let responseDate: Date?
    let expiresAt: Date?
    let etag: String?
    let lastModified: String?
    let requiresRevalidation: Bool
    let contentID: ContentID
    let contentType: String?

    init?(
        record: RepresentationRecord,
        request: ImageRequest,
        generation: NamespaceGeneration,
        payloadByteCount: Int
    ) {
        guard record.isValidPersistentRecord(),
            record.securityNamespaceFingerprint
                == request.storageNamespaceFingerprint,
            record.namespaceGeneration == generation.value,
            record.baseKeyDigest == request.fetchBaseDigest,
            record.variantKeyDigest == request.fetchVariantKey(for: record.vary).digestHex,
            record.statusCode == 200,
            record.disposition == .reusable,
            record.payloadLength == payloadByteCount,
            let contentID = ContentID(
                persistentDescription: record.contentID,
                expectedByteCount: payloadByteCount
            )
        else { return nil }

        self.vary = record.vary
        self.requestTime = record.requestTime
        self.responseTime = record.responseTime
        self.responseDate = record.responseDate
        self.expiresAt = record.expiresAt
        self.etag = record.etag
        self.lastModified = record.lastModified
        self.requiresRevalidation = record.requiresRevalidation
        self.contentID = contentID
        self.contentType = record.contentType
    }

    func isFresh(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return date < expiresAt
    }

    func variantKeyDigest(for request: ImageRequest) -> String {
        request.fetchVariantKey(for: vary).digestHex
    }

    func representation(
        for request: ImageRequest,
        generation: NamespaceGeneration
    ) -> RepresentationRecord {
        RepresentationRecord(
            securityNamespace: request.namespace.value,
            namespaceGeneration: generation.value,
            baseKeyDigest: request.fetchBaseDigest,
            variantKeyDigest: variantKeyDigest(for: request),
            vary: vary,
            statusCode: 200,
            requestTime: requestTime,
            responseTime: responseTime,
            responseDate: responseDate,
            expiresAt: expiresAt,
            etag: etag,
            lastModified: lastModified,
            disposition: .reusable,
            requiresRevalidation: requiresRevalidation,
            contentID: contentID.description,
            payloadLength: contentID.byteCount,
            contentType: contentType
        )
    }
}

struct TransportVerifiedEncodedHandoffEntry: Sendable {
    let payload: TransportVerifiedEncodedHandoffPayload
    let metadata: TransportVerifiedEncodedHandoffMetadata

    var byteCount: Int { payload.byteCount }
    func materializedData() throws -> Data { try payload.materializedData() }

    func variantKeyDigest(for request: ImageRequest) -> String {
        metadata.variantKeyDigest(for: request)
    }

    func representation(
        for request: ImageRequest,
        generation: NamespaceGeneration
    ) -> RepresentationRecord {
        metadata.representation(for: request, generation: generation)
    }
}

extension PipelineCache {
    func insertTransportVerifiedHandoff(
        data: Data,
        record: RepresentationRecord,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws {
        try await insertTransportVerifiedHandoff(
            payload: .memory(data),
            record: record,
            request: request,
            generation: generation
        )
    }

    func insertTransportVerifiedHandoff(
        payload: TransportVerifiedEncodedHandoffPayload,
        record: RepresentationRecord,
        request: ImageRequest,
        generation: NamespaceGeneration
    ) async throws {
        let byteCount = payload.byteCount
        guard request.cachePolicy == .automatic,
            request.authorizationContext == .public,
            !request.containsCredentialHeaders,
            let metadata = TransportVerifiedEncodedHandoffMetadata(
                record: record,
                request: request,
                generation: generation,
                payloadByteCount: byteCount
            )
        else { return }
        guard byteCount <= transportVerifiedEncodedHandoffCostLimit else {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .encodedHandoffRejected,
                    keyDigest: request.fetchExecutionKey.digestHex,
                    byteCount: byteCount,
                    reason: "entry-exceeds-handoff-budget"
                )
            )
            return
        }
        try await requireActive(generation, for: request.namespace)
        let key = ScopedTransportVerifiedHandoffKey(
            namespace: request.namespace,
            generation: generation,
            executionDigest: request.fetchExecutionKey.digestHex
        )
        try await transportVerifiedHandoffs.insert(
            payload: payload,
            metadata: metadata,
            for: key
        )
        do {
            try await requireActive(generation, for: request.namespace)
        } catch {
            await transportVerifiedHandoffs.remove(key)
            throw error
        }
        await diagnostics.record(
            DiagnosticEvent(
                kind: .encodedHandoffStored,
                keyDigest: request.fetchExecutionKey.digestHex,
                byteCount: byteCount,
                itemCount: transportVerifiedHandoffs.count
            )
        )
    }

    func containsTransportVerifiedHandoff(
        for request: ImageRequest,
        generation: NamespaceGeneration
    ) -> Bool {
        transportVerifiedHandoffs.contains(
            ScopedTransportVerifiedHandoffKey(
                namespace: request.namespace,
                generation: generation,
                executionDigest: request.fetchExecutionKey.digestHex
            )
        )
    }

    func transportVerifiedHandoff(
        for request: ImageRequest,
        generation: NamespaceGeneration,
        currentDate: @Sendable () async -> Date
    ) async throws -> TransportVerifiedEncodedHandoffEntry? {
        guard request.cachePolicy == .automatic else { return nil }
        let key = ScopedTransportVerifiedHandoffKey(
            namespace: request.namespace,
            generation: generation,
            executionDigest: request.fetchExecutionKey.digestHex
        )
        // 常见 warm-disk 路径没有 transient transport handoff；不要仅为发现 index miss 就派发异步 file I/O。
        // positive snapshot 之后仍以 `entry` 为权威读取，并由它安全处理并发删除。
        guard transportVerifiedHandoffs.contains(key) else { return nil }
        let entry: TransportVerifiedEncodedHandoffEntry
        do {
            guard let stored = try await transportVerifiedHandoffs.entry(for: key) else {
                return nil
            }
            entry = stored
        } catch {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .cacheReadFailed,
                    keyDigest: request.fetchExecutionKey.digestHex,
                    reason: "transport-handoff-read"
                )
            )
            return nil
        }
        let date = await currentDate()
        guard entry.metadata.isFresh(at: date),
            entry.metadata.contentID.byteCount == entry.byteCount
        else {
            await transportVerifiedHandoffs.remove(key)
            return nil
        }
        try await requireActive(generation, for: request.namespace)
        await diagnostics.record(
            DiagnosticEvent(
                kind: .encodedHandoffHit,
                keyDigest: request.fetchExecutionKey.digestHex,
                byteCount: entry.byteCount,
                itemCount: transportVerifiedHandoffs.count
            )
        )
        return entry
    }

    func removeTransportVerifiedHandoff(
        for request: ImageRequest,
        generation: NamespaceGeneration
    ) async {
        await transportVerifiedHandoffs.remove(
            ScopedTransportVerifiedHandoffKey(
                namespace: request.namespace,
                generation: generation,
                executionDigest: request.fetchExecutionKey.digestHex
            )
        )
    }

    func transientHandoffSnapshot() -> (
        itemCount: Int,
        costBytes: Int,
        inFlightPreparationCount: Int,
        inFlightPreparationBytes: Int
    ) {
        transportVerifiedHandoffs.snapshot()
    }

    func discardTransientHandoffs() async {
        _ = await transportVerifiedHandoffs.invalidateAndRemoveAll()
    }

}
