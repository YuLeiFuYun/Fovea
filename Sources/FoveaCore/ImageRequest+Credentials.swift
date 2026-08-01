import FoveaHTTP

/// 原子替换敏感请求头及其身份指纹；旧凭据必须先移除，不能与刷新结果合并残留。
extension ImageRequest {
    package func replacingCredentials(
        _ refreshed: CredentialRefreshResult
    ) throws -> ImageRequest {
        var mergedHeaders = CredentialHeaderPolicy.removingSensitiveHeaders(
            from: headers,
            additionalSensitiveNames: credentialHeaderNames
        )
        for (name, value) in refreshed.headers {
            mergedHeaders[name] = value
        }
        let refreshedCredentialNames = refreshed.credentialHeaderNames
            .union(refreshed.headers.keys.map { $0.lowercased() })
        var fingerprints = headerVariantFingerprints
        for (name, fingerprint) in refreshed.headerVariantFingerprints {
            fingerprints[name.lowercased()] = fingerprint
        }
        return try ImageRequest(
            url: url,
            logicalSource: logicalSource,
            target: target,
            contentMode: contentMode,
            geometryPolicyFingerprint: geometryPolicyFingerprint,
            colorPolicy: colorPolicy,
            renderCacheAdmission: renderCacheAdmission,
            namespace: namespace,
            authorizationContext: authorizationContext,
            credentialGeneration: refreshed.credentialGeneration,
            priority: priority,
            cachePolicy: cachePolicy,
            stalePolicy: stalePolicy,
            networkPolicy: networkPolicy,
            headers: mergedHeaders,
            credentialHeaderNames: refreshedCredentialNames,
            headerVariantFingerprints: fingerprints
        )
    }
}
