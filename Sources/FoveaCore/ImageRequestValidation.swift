import Foundation
import FoveaHTTP

/// 集中执行请求身份与安全边界的规范化，确保缓存键和实际网络目的地使用同一语义。
/// 所有长度上限均在分配昂贵资源之前检查，URL 凭据和不安全远端 HTTP 默认拒绝。
package enum ImageRequestValidation {
    package static let maximumLogicalSourceBytes = 16 * 1024
    package static let maximumNamespaceBytes = 4 * 1024
    package static let maximumAuthorizationContextBytes = 4 * 1024
    package static let maximumGeometryFingerprintBytes = 1024
    private static let maximumURLBytes = 16 * 1024

    package static func normalizedHTTPURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ImageRequestError.invalidURL
        }
        let scheme = components.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw ImageRequestError.unsupportedURLScheme(components.scheme)
        }
        guard let host = components.host, !host.isEmpty else {
            throw ImageRequestError.missingURLHost
        }
        let normalizedHost = host.lowercased()
        guard components.user == nil, components.password == nil else {
            throw ImageRequestError.embeddedURLCredentials
        }
        guard let candidateURL = components.url,
            HTTPURLSecurityPolicy.permits(candidateURL)
        else {
            throw ImageRequestError.insecureRemoteHTTP
        }

        components.scheme = scheme
        components.host = normalizedHost
        if (scheme == "http" && components.port == 80)
            || (scheme == "https" && components.port == 443)
        {
            components.port = nil
        }
        components.fragment = nil
        if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        guard let normalized = components.url else { throw ImageRequestError.invalidURL }
        guard normalized.absoluteString.utf8.count <= Self.maximumURLBytes else {
            throw ImageRequestError.urlTooLong
        }
        return normalized
    }

    package static func validateIdentityComponent(
        _ value: String,
        name: String,
        maximumBytes: Int
    ) throws {
        guard !value.isEmpty,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw ImageRequestError.invalidIdentityComponent(name)
        }
        guard value.utf8.count <= maximumBytes else {
            throw ImageRequestError.identityComponentTooLarge(name)
        }
    }

    package static func normalizedFingerprints(
        _ fingerprints: [String: HeaderVariantFingerprint]
    ) throws -> [String: HeaderVariantFingerprint] {
        guard fingerprints.count <= HTTPMetadataLimits.maximumHeaderCount else {
            throw ImageRequestError.headerCollectionTooLarge
        }
        var totalBytes = 0
        var result: [String: HeaderVariantFingerprint] = [:]
        for (name, fingerprint) in fingerprints {
            let normalized = name.lowercased()
            guard HTTPMetadataLimits.isValidFieldName(normalized) else {
                throw ImageRequestError.invalidHeaderName(name)
            }
            guard result[normalized] == nil else {
                throw ImageRequestError.duplicateHeaderName(normalized)
            }
            let addition = totalBytes.addingReportingOverflow(
                normalized.utf8.count + fingerprint.sha256Hex.utf8.count
            )
            guard !addition.overflow else { throw ImageRequestError.headerCollectionTooLarge }
            totalBytes = addition.partialValue
            guard totalBytes <= HTTPMetadataLimits.maximumHeaderBytes else {
                throw ImageRequestError.headerCollectionTooLarge
            }
            result[normalized] = fingerprint
        }
        return result
    }

    package static func normalizedHeaderNames(_ names: Set<String>) throws -> Set<String> {
        guard names.count <= HTTPMetadataLimits.maximumHeaderCount else {
            throw ImageRequestError.headerCollectionTooLarge
        }
        var totalBytes = 0
        var result: Set<String> = []
        for name in names {
            let normalized = name.lowercased()
            guard HTTPMetadataLimits.isValidFieldName(normalized) else {
                throw ImageRequestError.invalidHeaderName(name)
            }
            let addition = totalBytes.addingReportingOverflow(normalized.utf8.count)
            guard !addition.overflow else { throw ImageRequestError.headerCollectionTooLarge }
            totalBytes = addition.partialValue
            guard totalBytes <= HTTPMetadataLimits.maximumHeaderBytes else {
                throw ImageRequestError.headerCollectionTooLarge
            }
            result.insert(normalized)
        }
        return result
    }

    package static func normalizedHeaders(_ headers: [String: String]) throws -> [String: String] {
        guard headers.count <= HTTPMetadataLimits.maximumHeaderCount else {
            throw ImageRequestError.headerCollectionTooLarge
        }
        var totalBytes = 0
        var result: [String: String] = [:]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            let normalized = name.lowercased()
            guard HTTPMetadataLimits.isValidFieldName(normalized) else {
                throw ImageRequestError.invalidHeaderName(name)
            }
            guard HTTPMetadataLimits.isValidFieldValue(value) else {
                throw ImageRequestError.invalidHeaderValue(name)
            }
            guard result[normalized] == nil else {
                throw ImageRequestError.duplicateHeaderName(normalized)
            }
            let addition = totalBytes.addingReportingOverflow(
                normalized.utf8.count + value.utf8.count + 4
            )
            guard !addition.overflow else { throw ImageRequestError.headerCollectionTooLarge }
            totalBytes = addition.partialValue
            guard totalBytes <= HTTPMetadataLimits.maximumHeaderBytes else {
                throw ImageRequestError.headerCollectionTooLarge
            }
            result[normalized] = value
        }
        return result
    }

}
