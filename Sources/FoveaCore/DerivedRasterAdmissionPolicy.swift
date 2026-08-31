import Foundation
import FoveaHTTP
import FoveaStorage

/// 一个精确像素派生光栅表征的包内格式身份。
///
/// 它刻意不是公共 codec 或缓存格式。标识符与语义版本阻止不同实验格式仅因
/// 当前解码出相同像素就共享持久身份。
package struct DerivedRasterFormatIdentity: Hashable, Sendable {
    package let identifier: String
    package let semanticVersion: UInt16
    package let pixelLayoutFingerprint: String

    package init?(
        identifier: String,
        semanticVersion: UInt16,
        pixelLayoutFingerprint: String
    ) {
        guard semanticVersion > 0,
            Self.isValidComponent(identifier, maximumBytes: 96),
            Self.isValidComponent(pixelLayoutFingerprint, maximumBytes: 128)
        else { return nil }
        self.identifier = identifier
        self.semanticVersion = semanticVersion
        self.pixelLayoutFingerprint = pixelLayoutFingerprint
    }

    private static func isValidComponent(_ value: String, maximumBytes: Int) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= maximumBytes
            && bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }
}

/// 面向特定目标精确像素工件的持久派生身份。
///
/// 该键同时绑定像素语义与选中的 HTTP 表征，但它不是授权令牌。每次读取仍必须通过
/// `DerivedRasterReusePolicy`，因为同一 variant 之后可能变为 `no-store`、过期、
/// 必须再验证或已撤销。
package struct DerivedRasterArtifactKey: Hashable, Sendable {
    package static let currentSchemaVersion: UInt16 = 7

    package let schemaVersion: UInt16
    package let baseKeyDigest: String
    package let variantKeyDigest: String
    package let namespaceFingerprint: StorageNamespaceFingerprint
    package let namespaceGeneration: NamespaceGeneration
    package let renderKey: RenderKey
    package let format: DerivedRasterFormatIdentity
    private let representedContentID: String
    package let digestHex: String

    package init?(
        request: ImageRequest,
        representation: RepresentationRecord,
        namespaceGeneration: NamespaceGeneration,
        renderKey: RenderKey,
        format: DerivedRasterFormatIdentity
    ) {
        let expectedNamespace = request.storageNamespaceFingerprint
        guard request.renderCacheAdmission == .stable,
            representation.isValidPersistentRecord(),
            representation.disposition != .noStore,
            representation.securityNamespaceFingerprint == expectedNamespace,
            representation.namespaceGeneration == namespaceGeneration.value,
            representation.baseKeyDigest == request.fetchBaseDigest,
            let representedContent = ContentID(
                persistentDescription: representation.contentID,
                expectedByteCount: representation.payloadLength
            ),
            representedContent == renderKey.decodeKey.contentID,
            renderKey.decodeKey.targetWidth == request.target.width,
            renderKey.decodeKey.targetHeight == request.target.height,
            renderKey.decodeKey.contentMode == request.contentMode,
            renderKey.decodeKey.geometryPolicyFingerprint
                == request.geometryPolicyFingerprint,
            renderKey.decodeKey.colorPolicy == request.colorPolicy
        else { return nil }

        schemaVersion = Self.currentSchemaVersion
        baseKeyDigest = representation.baseKeyDigest
        variantKeyDigest = representation.variantKeyDigest
        namespaceFingerprint = expectedNamespace
        self.namespaceGeneration = namespaceGeneration
        self.renderKey = renderKey
        self.format = format
        self.representedContentID = representation.contentID
        digestHex = Self.makeDigest(
            schemaVersion: Self.currentSchemaVersion,
            baseKeyDigest: representation.baseKeyDigest,
            variantKeyDigest: representation.variantKeyDigest,
            namespaceFingerprint: expectedNamespace,
            namespaceGeneration: namespaceGeneration,
            renderKey: renderKey,
            format: format
        )
    }

    /// 为已由 `PipelineCache.records` 验证的 representation 提供热路径构造。
    /// 传入的 ContentID 必须来自同一份不可变 record；Debug 会重证契约，Release 命中时避免重复解析持久化 record。
    package init?(
        validatedRequest request: ImageRequest,
        validatedRepresentation representation: RepresentationRecord,
        representedContentID: ContentID,
        namespaceGeneration: NamespaceGeneration,
        renderKey: RenderKey,
        format: DerivedRasterFormatIdentity
    ) {
        assert(representation.isValidPersistentRecord())
        assert(
            ContentID(
                persistentDescription: representation.contentID,
                expectedByteCount: representation.payloadLength
            ) == representedContentID
        )
        let expectedNamespace = request.storageNamespaceFingerprint
        guard request.renderCacheAdmission == .stable,
            representation.disposition != .noStore,
            representation.securityNamespaceFingerprint == expectedNamespace,
            representation.namespaceGeneration == namespaceGeneration.value,
            representation.baseKeyDigest == request.fetchBaseDigest,
            representedContentID == renderKey.decodeKey.contentID,
            renderKey.decodeKey.targetWidth == request.target.width,
            renderKey.decodeKey.targetHeight == request.target.height,
            renderKey.decodeKey.contentMode == request.contentMode,
            renderKey.decodeKey.geometryPolicyFingerprint
                == request.geometryPolicyFingerprint,
            renderKey.decodeKey.colorPolicy == request.colorPolicy
        else { return nil }

        schemaVersion = Self.currentSchemaVersion
        baseKeyDigest = representation.baseKeyDigest
        variantKeyDigest = representation.variantKeyDigest
        namespaceFingerprint = expectedNamespace
        self.namespaceGeneration = namespaceGeneration
        self.renderKey = renderKey
        self.format = format
        self.representedContentID = representation.contentID
        digestHex = Self.makeDigest(
            schemaVersion: Self.currentSchemaVersion,
            baseKeyDigest: representation.baseKeyDigest,
            variantKeyDigest: representation.variantKeyDigest,
            namespaceFingerprint: expectedNamespace,
            namespaceGeneration: namespaceGeneration,
            renderKey: renderKey,
            format: format
        )
    }

    package func hash(into hasher: inout Hasher) {
        // `digestHex` 已是全部 identity 字段的 canonical SHA-256，只用作 hash 加速；合成的 Equatable 仍逐字段精确比较。
        hasher.combine(digestHex)
    }

    /// 对已构造的精确 artifact key 重验实时授权输入，不再次构造并 hash 完全相同的 canonical key。
    package func matchesLiveAuthorization(
        request: ImageRequest,
        representation: RepresentationRecord,
        namespaceGeneration: NamespaceGeneration
    ) -> Bool {
        let expectedNamespace = request.storageNamespaceFingerprint
        guard request.renderCacheAdmission == .stable,
            representation.isValidPersistentRecord(),
            representation.disposition != .noStore,
            representation.securityNamespaceFingerprint == expectedNamespace,
            representation.namespaceGeneration == namespaceGeneration.value,
            representation.baseKeyDigest == request.fetchBaseDigest,
            representation.baseKeyDigest == baseKeyDigest,
            representation.variantKeyDigest == variantKeyDigest,
            namespaceFingerprint == expectedNamespace,
            self.namespaceGeneration == namespaceGeneration,
            representation.contentID == representedContentID,
            representation.payloadLength == renderKey.decodeKey.contentID.byteCount,
            renderKey.decodeKey.targetWidth == request.target.width,
            renderKey.decodeKey.targetHeight == request.target.height,
            renderKey.decodeKey.contentMode == request.contentMode,
            renderKey.decodeKey.geometryPolicyFingerprint
                == request.geometryPolicyFingerprint,
            renderKey.decodeKey.colorPolicy == request.colorPolicy
        else { return false }
        return true
    }

    /// 对 package-only cache snapshot/exact lookup 已验证的 record 执行同样的实时授权检查；这里只跳过不可变持久化形状验证，
    /// request、representation、generation 与 content 绑定检查全部保留。
    package func matchesValidatedLiveAuthorization(
        request: ImageRequest,
        representation: RepresentationRecord,
        namespaceGeneration: NamespaceGeneration
    ) -> Bool {
        assert(representation.isValidPersistentRecord())
        let expectedNamespace = request.storageNamespaceFingerprint
        guard request.renderCacheAdmission == .stable,
            representation.disposition != .noStore,
            representation.securityNamespaceFingerprint == expectedNamespace,
            representation.namespaceGeneration == namespaceGeneration.value,
            representation.baseKeyDigest == request.fetchBaseDigest,
            representation.baseKeyDigest == baseKeyDigest,
            representation.variantKeyDigest == variantKeyDigest,
            namespaceFingerprint == expectedNamespace,
            self.namespaceGeneration == namespaceGeneration,
            representation.contentID == representedContentID,
            representation.payloadLength == renderKey.decodeKey.contentID.byteCount,
            renderKey.decodeKey.targetWidth == request.target.width,
            renderKey.decodeKey.targetHeight == request.target.height,
            renderKey.decodeKey.contentMode == request.contentMode,
            renderKey.decodeKey.geometryPolicyFingerprint
                == request.geometryPolicyFingerprint,
            renderKey.decodeKey.colorPolicy == request.colorPolicy
        else { return false }
        return true
    }

    private static func makeDigest(
        schemaVersion: UInt16,
        baseKeyDigest: String,
        variantKeyDigest: String,
        namespaceFingerprint: StorageNamespaceFingerprint,
        namespaceGeneration: NamespaceGeneration,
        renderKey: RenderKey,
        format: DerivedRasterFormatIdentity
    ) -> String {
        var encoder = DerivedRasterCanonicalEncoder()
        encoder.append(schemaVersion)
        encoder.append(baseKeyDigest)
        encoder.append(variantKeyDigest)
        encoder.append(namespaceFingerprint.value)
        encoder.append(namespaceGeneration.value)
        encoder.append(renderKey.decodeKey.contentID.digestHex)
        encoder.append(UInt64(renderKey.decodeKey.contentID.byteCount))
        encoder.append(UInt64(renderKey.decodeKey.targetWidth))
        encoder.append(UInt64(renderKey.decodeKey.targetHeight))
        encoder.append(renderKey.decodeKey.contentMode.rawValue)
        encoder.append(renderKey.decodeKey.geometryPolicyFingerprint)
        encoder.append(renderKey.decodeKey.colorPolicy.rawValue)
        encoder.append(renderKey.decodeKey.codecContractVersion)
        encoder.append(renderKey.decodeKey.codecFingerprint)
        encoder.append(renderKey.transformerFingerprint)
        encoder.append(renderKey.renderVersion)
        encoder.append(format.identifier)
        encoder.append(format.semanticVersion)
        encoder.append(format.pixelLayoutFingerprint)
        return encoder.data.sha256Hex
    }
}

package enum DerivedRasterAdmissionRejection: Equatable, Sendable {
    case invalidArtifactIdentity
    case unsupportedFormatForRender
    case foregroundCreation
    case inactiveNamespace
    case staleRepresentation
    case requiresRevalidation
    case invalidMetrics
    case noReadSavings
    case creationBudgetExceeded(actual: UInt64, maximum: UInt64)
    case byteBudgetExceeded(actual: Int, maximum: Int)
    case insufficientObservedReuse(required: Int, observed: Int)
}

package enum DerivedRasterAdmissionDecision: Equatable, Sendable {
    case admit(key: DerivedRasterArtifactKey, requiredObservedHits: Int)
    case reject(DerivedRasterAdmissionRejection)
}

/// 面向未来目标派生持久化的保守准入模型。
///
/// 该策略不创建、读取或发布工件，只规定后续存储实现可以开始后台创建的最低条件。
/// 首次显示绝不能等待该决定完成。
/// 每次未来派生光栅命中都必须重新验证可达性。
///
/// 仅摘要相同永远不充分；当前 HTTP 记录仍须允许复用、保持新鲜且无需强制再验证，
/// 并且属于活动 namespace generation。
package enum DerivedRasterReusePolicy {
    package static func permits(
        key: DerivedRasterArtifactKey,
        request: ImageRequest,
        currentRepresentation: RepresentationRecord,
        namespaceGeneration: NamespaceGeneration,
        namespaceIsActive: Bool,
        now: Date
    ) -> Bool {
        guard namespaceIsActive,
            DerivedRasterContainer.isCompatible(with: key),
            currentRepresentation.disposition != .noStore,
            !currentRepresentation.requiresRevalidation,
            currentRepresentation.isFresh(at: now),
            key.matchesLiveAuthorization(
                request: request,
                representation: currentRepresentation,
                namespaceGeneration: namespaceGeneration
            )
        else { return false }
        return true
    }

    package static func permitsValidatedRepresentation(
        key: DerivedRasterArtifactKey,
        request: ImageRequest,
        currentRepresentation: RepresentationRecord,
        namespaceGeneration: NamespaceGeneration,
        namespaceIsActive: Bool,
        now: Date
    ) -> Bool {
        guard namespaceIsActive,
            DerivedRasterContainer.isCompatible(with: key),
            currentRepresentation.disposition != .noStore,
            !currentRepresentation.requiresRevalidation,
            currentRepresentation.isFresh(at: now),
            key.matchesValidatedLiveAuthorization(
                request: request,
                representation: currentRepresentation,
                namespaceGeneration: namespaceGeneration
            )
        else { return false }
        return true
    }
}

package enum DerivedRasterAdmissionPolicy {
    package static let defaultSafetyMarginHits = 1

    private static func basicRejection(
        key: DerivedRasterArtifactKey,
        representation: RepresentationRecord,
        namespaceIsActive: Bool,
        now: Date,
        creationRunsInBackground: Bool,
        observedReuseHits: Int,
        safetyMarginHits: Int,
        derivedByteCount: Int,
        maximumDerivedByteCount: Int
    ) -> DerivedRasterAdmissionRejection? {
        guard DerivedRasterContainer.isCompatible(with: key) else {
            return .unsupportedFormatForRender
        }
        guard creationRunsInBackground else { return .foregroundCreation }
        guard namespaceIsActive else { return .inactiveNamespace }
        guard representation.isFresh(at: now) else { return .staleRepresentation }
        guard !representation.requiresRevalidation else { return .requiresRevalidation }
        guard observedReuseHits >= 0,
            safetyMarginHits >= 0,
            derivedByteCount > 0,
            maximumDerivedByteCount >= 0
        else { return .invalidMetrics }
        return nil
    }

    private static func budgetRejection(
        creationNanoseconds: UInt64,
        maximumCreationNanoseconds: UInt64,
        derivedByteCount: Int,
        maximumDerivedByteCount: Int,
        originalDecodeNanoseconds: UInt64,
        derivedReadNanoseconds: UInt64
    ) -> DerivedRasterAdmissionRejection? {
        guard creationNanoseconds <= maximumCreationNanoseconds else {
            return .creationBudgetExceeded(
                actual: creationNanoseconds,
                maximum: maximumCreationNanoseconds
            )
        }
        guard derivedByteCount <= maximumDerivedByteCount else {
            return .byteBudgetExceeded(actual: derivedByteCount, maximum: maximumDerivedByteCount)
        }
        guard originalDecodeNanoseconds > derivedReadNanoseconds else { return .noReadSavings }
        return nil
    }

    private static func requiredObservedHits(
        creationNanoseconds: UInt64,
        originalDecodeNanoseconds: UInt64,
        derivedReadNanoseconds: UInt64,
        safetyMarginHits: Int
    ) -> Int? {
        let perHitSavings = originalDecodeNanoseconds - derivedReadNanoseconds
        let amortizationHits =
            creationNanoseconds / perHitSavings
            + (creationNanoseconds % perHitSavings == 0 ? 0 : 1)
        let (requiredHits, overflow) = amortizationHits.addingReportingOverflow(
            UInt64(safetyMarginHits)
        )
        guard !overflow, requiredHits <= UInt64(Int.max) else { return nil }
        return Int(requiredHits)
    }

    package static func evaluate(
        request: ImageRequest,
        representation: RepresentationRecord,
        namespaceGeneration: NamespaceGeneration,
        namespaceIsActive: Bool,
        renderKey: RenderKey,
        format: DerivedRasterFormatIdentity,
        now: Date,
        creationRunsInBackground: Bool,
        observedReuseHits: Int,
        originalDecodeNanoseconds: UInt64,
        derivedReadNanoseconds: UInt64,
        creationNanoseconds: UInt64,
        maximumCreationNanoseconds: UInt64,
        derivedByteCount: Int,
        maximumDerivedByteCount: Int,
        safetyMarginHits: Int = defaultSafetyMarginHits
    ) -> DerivedRasterAdmissionDecision {
        guard
            let key = DerivedRasterArtifactKey(
                request: request,
                representation: representation,
                namespaceGeneration: namespaceGeneration,
                renderKey: renderKey,
                format: format
            )
        else { return .reject(.invalidArtifactIdentity) }
        if let rejection = basicRejection(
            key: key,
            representation: representation,
            namespaceIsActive: namespaceIsActive,
            now: now,
            creationRunsInBackground: creationRunsInBackground,
            observedReuseHits: observedReuseHits,
            safetyMarginHits: safetyMarginHits,
            derivedByteCount: derivedByteCount,
            maximumDerivedByteCount: maximumDerivedByteCount
        ) {
            return .reject(rejection)
        }
        if let rejection = budgetRejection(
            creationNanoseconds: creationNanoseconds,
            maximumCreationNanoseconds: maximumCreationNanoseconds,
            derivedByteCount: derivedByteCount,
            maximumDerivedByteCount: maximumDerivedByteCount,
            originalDecodeNanoseconds: originalDecodeNanoseconds,
            derivedReadNanoseconds: derivedReadNanoseconds
        ) {
            return .reject(rejection)
        }
        guard
            let required = requiredObservedHits(
                creationNanoseconds: creationNanoseconds,
                originalDecodeNanoseconds: originalDecodeNanoseconds,
                derivedReadNanoseconds: derivedReadNanoseconds,
                safetyMarginHits: safetyMarginHits
            )
        else {
            return .reject(.invalidMetrics)
        }
        guard observedReuseHits >= required else {
            return .reject(
                .insufficientObservedReuse(
                    required: required,
                    observed: observedReuseHits
                )
            )
        }
        return .admit(key: key, requiredObservedHits: required)
    }
}

private struct DerivedRasterCanonicalEncoder {
    fileprivate var data = Data()

    mutating func append(_ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    mutating func append(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    mutating func append(_ value: String) {
        let bytes = Data(value.utf8)
        append(UInt64(bytes.count))
        data.append(bytes)
    }
}

/// 创建与读取路径共享的派生工件结构、摘要和输出几何验证。
package enum DerivedRasterArtifactValidator {
    private struct RecordValidation {
        let expectedContainerDigestHex: String?
    }

    package static func validatedSurface(
        record: DerivedRasterRecord?,
        container: Data,
        matching key: DerivedRasterArtifactKey,
        containerContentDigestAlreadyVerified: Bool = false,
        verifyDecodedPixelDigest: Bool = false
    ) -> DerivedRasterSurface? {
        guard DerivedRasterContainer.isCompatible(with: key),
            let recordValidation = validateRecord(
                record,
                containerCount: container.count,
                key: key,
                recordAlreadyValidated: false
            )
        else { return nil }
        guard
            let surface = try? DerivedRasterContainer.decode(
                container,
                expectedContainerDigestHex: recordValidation.expectedContainerDigestHex,
                containerContentDigestAlreadyVerified: containerContentDigestAlreadyVerified,
                expectedFormat: key.format,
                verifyDecodedPixelDigest: verifyDecodedPixelDigest
            ),
            outputGeometryIsCompatible(
                width: surface.width,
                height: surface.height,
                key: key
            )
        else { return nil }
        if let record {
            guard surface.width == record.pixelWidth,
                surface.height == record.pixelHeight,
                surface.pixelDigestHex == record.pixelDigestHex
            else { return nil }
        }
        return surface
    }

    package static func validatedCompressedSurface(
        record: DerivedRasterRecord,
        container: Data,
        matching key: DerivedRasterArtifactKey,
        recordAlreadyValidated: Bool = false,
        containerContentDigestAlreadyVerified: Bool = false
    ) -> DerivedRasterCompressedSurface? {
        guard DerivedRasterContainer.isCompatible(with: key),
            let recordValidation = validateRecord(
                record,
                containerCount: container.count,
                key: key,
                recordAlreadyValidated: recordAlreadyValidated
            ),
            let surface = try? DerivedRasterContainer.validatedCompressedSurface(
                container,
                expectedContainerDigestHex: recordValidation.expectedContainerDigestHex,
                containerContentDigestAlreadyVerified: containerContentDigestAlreadyVerified,
                expectedFormat: key.format
            ),
            outputGeometryIsCompatible(width: surface.width, height: surface.height, key: key),
            surface.width == record.pixelWidth,
            surface.height == record.pixelHeight,
            surface.pixelDigestHex == record.pixelDigestHex
        else { return nil }
        return surface
    }

    private static func validateRecord(
        _ record: DerivedRasterRecord?,
        containerCount: Int,
        key: DerivedRasterArtifactKey,
        recordAlreadyValidated: Bool
    ) -> RecordValidation? {
        guard let record else { return RecordValidation(expectedContainerDigestHex: nil) }
        if recordAlreadyValidated {
            assert(record.isValidPersistentRecord(storedUnder: key.digestHex))
        } else if !record.isValidPersistentRecord(storedUnder: key.digestHex) {
            return nil
        }
        guard record.artifactKeyDigest == key.digestHex,
            record.baseKeyDigest == key.baseKeyDigest,
            record.variantKeyDigest == key.variantKeyDigest,
            record.namespaceFingerprint == key.namespaceFingerprint,
            record.namespaceGeneration == key.namespaceGeneration.value,
            record.formatIdentifier == key.format.identifier,
            record.formatSemanticVersion == key.format.semanticVersion,
            record.pixelLayoutFingerprint == key.format.pixelLayoutFingerprint,
            let contentID = ContentID(
                persistentDescription: record.containerContentID,
                expectedByteCount: record.containerByteCount
            ),
            contentID.byteCount == containerCount
        else { return nil }
        return RecordValidation(expectedContainerDigestHex: contentID.digestHex)
    }

    package static func outputGeometryIsCompatible(
        width: Int,
        height: Int,
        key: DerivedRasterArtifactKey
    ) -> Bool {
        let targetWidth = key.renderKey.decodeKey.targetWidth
        let targetHeight = key.renderKey.decodeKey.targetHeight
        switch key.renderKey.decodeKey.contentMode {
        case .fit:
            return width <= targetWidth && height <= targetHeight
        case .fill:
            return width == targetWidth && height == targetHeight
        }
    }
}
