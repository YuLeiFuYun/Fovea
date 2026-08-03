import Foundation
import FoveaHTTP

/// 连接 transport 完成与下游 decode/persist 可见性之间的短暂窗口。
///
/// 只有明确可复用且仍新鲜的 200 响应可以进入该 exact-key handoff。它不是 HTTP
/// 缓存：租约固定有界、进程内、不可跨身份，并在最后一个加入者释放后重新计时。
package enum FetchCompletionHandoffPolicy {
    package static let maximumRetentionNanoseconds: UInt64 = 250_000_000

    package static func retentionNanoseconds(
        head: TransportResponseHead,
        requestTime: Date,
        responseTime: Date,
        request: ImageRequest
    ) -> UInt64 {
        guard head.statusCode == 200 else { return 0 }
        let varySelectionAvailable: Bool
        switch HTTPCachePolicy.varyFieldNames(in: head.headers) {
        case .wildcard, .unrepresentable:
            varySelectionAvailable = false
        case .fields(let fields):
            varySelectionAvailable = request.varySelection(fieldNames: fields) != nil
        }
        let disposition = HTTPCachePolicy.disposition(
            headers: head.headers,
            isPrivateNamespace: request.authorizationContext != .public,
            varySelectionAvailable: varySelectionAvailable
        )
        guard disposition != .noStore,
            !HTTPCachePolicy.requiresRevalidation(headers: head.headers),
            let expiresAt = HTTPCachePolicy.expiration(
                requestTime: requestTime,
                responseTime: responseTime,
                headers: head.headers
            ),
            expiresAt > responseTime
        else { return 0 }
        return maximumRetentionNanoseconds
    }
}
