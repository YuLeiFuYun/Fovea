import Foundation

/// URLSession redirect delegate 使用的纯策略边界。
package enum HTTPRedirectPolicy {
    package static func request(
        original: URLRequest?,
        proposed: URLRequest,
        additionalSensitiveNames: Set<String>,
        destinationPolicy: HTTPDestinationPolicy = .secureDefault
    ) throws -> URLRequest {
        guard let url = proposed.url, HTTPURLSecurityPolicy.permits(url) else {
            throw TransportError.insecureRedirect
        }
        guard destinationPolicy.permits(url) else {
            throw TransportError.destinationDisallowed
        }
        return CredentialHeaderPolicy.sanitizedRedirectRequest(
            original: original,
            proposed: proposed,
            additionalSensitiveNames: additionalSensitiveNames
        )
    }
}
