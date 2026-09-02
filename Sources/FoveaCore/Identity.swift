import CryptoKit
import Foundation
import ImageCraftCore

/// 由调用方定义、独立于当前 URL 的图像来源稳定身份。

public struct LogicalSourceID: Hashable, Sendable, Codable {
    public let value: String
    public init(_ value: String) { self.value = value }
    init(normalizedHTTPURL: URL) { self.value = normalizedHTTPURL.absoluteString }
}

/// 缓存、凭证与撤销状态的显式隔离边界。

public struct SecurityNamespaceID: Hashable, Sendable, Codable {
    public let value: String
    public init(_ value: String) { self.value = value }
    public static func publicNamespace(appID: String) -> Self { .init("public:\(appID)") }

    package var isPublicNamespace: Bool {
        value.hasPrefix("public:") && value.count > "public:".count
    }
}

/// 单个安全命名空间内单调递增的撤销代际。

public struct NamespaceGeneration: Hashable, Sendable, Codable {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
}

/// 标识其凭证可以影响请求的授权上下文。

public struct AuthorizationContextID: Hashable, Sendable, Codable {
    public let value: String
    public init(_ value: String) { self.value = value }
    public static let `public` = AuthorizationContextID("public")
}

/// 一个授权上下文所用凭证的单调版本。

public struct CredentialGeneration: Hashable, Sendable, Codable {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
}

/// 尚未知响应驱动表征变体时使用的持久获取身份。

public struct FetchBaseKey: Hashable, Sendable {
    public let schemaVersion: UInt16
    public let source: LogicalSourceID
    public let namespace: SecurityNamespaceID
    public let authorizationContext: AuthorizationContextID
    public let method: String

    package init(
        schemaVersion: UInt16 = 1,
        source: LogicalSourceID,
        namespace: SecurityNamespaceID,
        authorizationContext: AuthorizationContextID = .public,
        method: String = "GET"
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.namespace = namespace
        self.authorizationContext = authorizationContext
        self.method = method.uppercased()
    }

    public var canonicalBytes: Data {
        var encoder = CanonicalEncoder()
        encoder.append(schemaVersion)
        encoder.append(source.value)
        encoder.append(namespace.value)
        encoder.append(authorizationContext.value)
        encoder.append(method)
        return encoder.data
    }

    public var digestHex: String { canonicalBytes.sha256Hex }
}

/// 由 Vary 语义选中的一个 HTTP 表征身份。

public struct FetchVariantKey: Hashable, Sendable {
    public let schemaVersion: UInt16
    public let baseDigest: String
    public let requestVariants: [String: String]

    package init(
        schemaVersion: UInt16 = 2,
        base: FetchBaseKey,
        requestVariants: [String: String] = [:]
    ) {
        self.init(
            schemaVersion: schemaVersion,
            baseDigest: base.digestHex,
            requestVariants: requestVariants
        )
    }

    package init(
        schemaVersion: UInt16 = 2,
        baseDigest: String,
        requestVariants: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.baseDigest = baseDigest
        self.requestVariants = Dictionary(
            uniqueKeysWithValues: requestVariants.map { ($0.key.lowercased(), $0.value) }
        )
    }

    public var canonicalBytes: Data {
        var encoder = CanonicalEncoder()
        encoder.append(schemaVersion)
        encoder.append(baseDigest)
        encoder.append(UInt32(requestVariants.count))
        for (key, value) in requestVariants.sorted(by: { $0.key < $1.key }) {
            encoder.append(key)
            encoder.append(value)
        }
        return encoder.data
    }

    public var digestHex: String { canonicalBytes.sha256Hex }
}

/// 包含临时策略与凭证状态的请求执行身份。

public struct FetchExecutionKey: Hashable, Sendable {
    public let schemaVersion: UInt16
    public let baseDigest: String
    public let selectedVariantDigest: String?
    public let resolvedLocator: String
    public let requestHeaderFingerprint: String
    public let credentialGeneration: CredentialGeneration?
    public let revalidationFingerprint: String
    public let transportPolicyFingerprint: String

    package init(
        schemaVersion: UInt16 = 2,
        base: FetchBaseKey,
        selectedVariant: FetchVariantKey? = nil,
        resolvedLocator: String,
        requestHeaderFingerprint: String,
        credentialGeneration: CredentialGeneration? = nil,
        revalidationFingerprint: String = "unconditional",
        transportPolicyFingerprint: String = "phase0b-default"
    ) {
        self.init(
            schemaVersion: schemaVersion,
            baseDigest: base.digestHex,
            selectedVariantDigest: selectedVariant?.digestHex,
            resolvedLocator: resolvedLocator,
            requestHeaderFingerprint: requestHeaderFingerprint,
            credentialGeneration: credentialGeneration,
            revalidationFingerprint: revalidationFingerprint,
            transportPolicyFingerprint: transportPolicyFingerprint
        )
    }

    package init(
        schemaVersion: UInt16 = 2,
        baseDigest: String,
        selectedVariantDigest: String? = nil,
        resolvedLocator: String,
        requestHeaderFingerprint: String,
        credentialGeneration: CredentialGeneration? = nil,
        revalidationFingerprint: String = "unconditional",
        transportPolicyFingerprint: String = "phase0b-default"
    ) {
        self.schemaVersion = schemaVersion
        self.baseDigest = baseDigest
        self.selectedVariantDigest = selectedVariantDigest
        self.resolvedLocator = resolvedLocator
        self.requestHeaderFingerprint = requestHeaderFingerprint
        self.credentialGeneration = credentialGeneration
        self.revalidationFingerprint = revalidationFingerprint
        self.transportPolicyFingerprint = transportPolicyFingerprint
    }

    public var canonicalBytes: Data {
        var encoder = CanonicalEncoder()
        encoder.append(schemaVersion)
        encoder.append(baseDigest)
        encoder.appendOptional(selectedVariantDigest)
        encoder.append(resolvedLocator)
        encoder.append(requestHeaderFingerprint)
        encoder.appendOptional(credentialGeneration?.value)
        encoder.append(revalidationFingerprint)
        encoder.append(transportPolicyFingerprint)
        return encoder.data
    }

    public var digestHex: String { canonicalBytes.sha256Hex }
}

/// 规范内容标识的验证失败。

public enum ContentIDError: Error, Equatable, Sendable {
    case invalidDigest
    case invalidByteCount
}

/// 已验证编码字节的规范 SHA-256 身份。

public struct ContentID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let digestHex: String
    public let byteCount: Int

    public init(data: Data) {
        self.digestHex = data.sha256Hex
        self.byteCount = data.count
    }

    public init(digestHex: String, byteCount: Int) throws {
        guard byteCount >= 0 else { throw ContentIDError.invalidByteCount }
        guard digestHex.utf8.count == 64,
            digestHex.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            })
        else {
            throw ContentIDError.invalidDigest
        }
        self.digestHex = digestHex
        self.byteCount = byteCount
    }

    /// 从持久层使用的规范描述恢复内容身份。
    /// 该入口只接受 `sha256:<digest>:<byte-count>`，并重新验证摘要与长度。
    package init?(persistentDescription: String, expectedByteCount: Int) {
        let parts = persistentDescription.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "sha256",
            let storedByteCount = Int(parts[2]),
            storedByteCount == expectedByteCount,
            String(storedByteCount) == parts[2],
            let value = try? ContentID(digestHex: String(parts[1]), byteCount: storedByteCount)
        else { return nil }
        self = value
    }

    public var description: String { "sha256:\(digestHex):\(byteCount)" }

    private enum CodingKeys: String, CodingKey {
        case digestHex
        case byteCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            digestHex: container.decode(String.self, forKey: .digestHex),
            byteCount: container.decode(Int.self, forKey: .byteCount)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(digestHex, forKey: .digestHex)
        try container.encode(byteCount, forKey: .byteCount)
    }
}

/// 由内容与解码语义派生的解码操作身份。

public struct DecodeKey: Hashable, Sendable {
    public let contentID: ContentID
    public let targetWidth: Int
    public let targetHeight: Int
    public let contentMode: ImageContentMode
    public let geometryPolicyFingerprint: String
    public let colorPolicy: ImageColorPolicy
    public let codecContractVersion: UInt16
    /// 区分具体后端及其像素语义版本，避免不同 codec 复用同一解码/渲染身份。
    package let codecFingerprint: String

    package init(
        contentID: ContentID,
        targetWidth: Int,
        targetHeight: Int,
        contentMode: ImageContentMode,
        geometryPolicyFingerprint: String,
        colorPolicy: ImageColorPolicy = .preserveSource,
        codecContractVersion: UInt16,
        codecFingerprint: String
    ) {
        self.contentID = contentID
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.contentMode = contentMode
        self.geometryPolicyFingerprint = geometryPolicyFingerprint
        self.colorPolicy = colorPolicy
        self.codecContractVersion = codecContractVersion
        self.codecFingerprint = codecFingerprint
    }
}

/// 存储在渲染内存中的可显示表征身份。

public struct RenderKey: Hashable, Sendable {
    public let decodeKey: DecodeKey
    public let transformerFingerprint: String
    public let renderVersion: UInt16

    package init(
        decodeKey: DecodeKey,
        transformerFingerprint: String = "identity-transform-v1",
        renderVersion: UInt16
    ) {
        self.decodeKey = decodeKey
        self.transformerFingerprint = transformerFingerprint
        self.renderVersion = renderVersion
    }
}

private struct CanonicalEncoder {
    fileprivate var data = Data()

    mutating func append(_ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    mutating func append(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    mutating func append(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    mutating func append(_ value: String) {
        let bytes = Data(value.utf8)
        append(UInt32(bytes.count))
        data.append(bytes)
    }

    mutating func appendOptional(_ value: String?) {
        if let value {
            data.append(1)
            append(value)
        } else {
            data.append(0)
        }
    }

    mutating func appendOptional(_ value: UInt64?) {
        if let value {
            data.append(1)
            append(value)
        } else {
            data.append(0)
        }
    }
}

extension Data {
    var sha256Hex: String {
        lowercaseHexString(SHA256.hash(data: self))
    }
}

private let lowercaseHexDigits = Array("0123456789abcdef".utf8)

@inline(__always)
func lowercaseHexString<Bytes: Sequence>(_ bytes: Bytes) -> String
where Bytes.Element == UInt8 {
    var output = [UInt8]()
    output.reserveCapacity(bytes.underestimatedCount * 2)
    for byte in bytes {
        output.append(lowercaseHexDigits[Int(byte >> 4)])
        output.append(lowercaseHexDigits[Int(byte & 0x0f)])
    }
    return String(decoding: output, as: UTF8.self)
}
