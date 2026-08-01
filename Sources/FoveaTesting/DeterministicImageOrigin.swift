import CryptoKit
import Foundation
import FoveaHTTP

/// 内存中的确定性 HTTP 源站，用于复现缓存、重验证、重定向、失败与取消路径。
/// actor 串行化请求计数，使测试证据不受并发数据竞争影响。
package actor DeterministicImageOrigin: HTTPTransporting {
    package nonisolated let reusePolicy = TransportReusePolicy.reusable(
        contextIdentifier: "fovea-testing-deterministic-origin-v1"
    )

    package struct Resource: Sendable {
        package let url: URL
        package let body: Data
        package let headers: [String: String]
        package let delayNanoseconds: UInt64

        package init(
            url: URL,
            body: Data,
            contentType: String,
            cacheControl: String = "max-age=3600",
            etag: String? = nil,
            delayNanoseconds: UInt64 = 0
        ) {
            self.url = url
            self.body = body
            var headers = [
                "Content-Type": contentType,
                "Cache-Control": cacheControl,
            ]
            if let etag { headers["ETag"] = etag }
            self.headers = headers
            self.delayNanoseconds = delayNanoseconds
        }
    }

    package struct Metrics: Codable, Hashable, Sendable {
        package let requestCount: Int
        package let successfulResponseCount: Int
        package let notModifiedCount: Int
        package let cancellationCount: Int
        package let deliveredBytes: Int
        package let duplicateRequestCount: Int
        package let requestsByResource: [String: Int]

        package init(
            requestCount: Int,
            successfulResponseCount: Int,
            notModifiedCount: Int,
            cancellationCount: Int,
            deliveredBytes: Int,
            duplicateRequestCount: Int,
            requestsByResource: [String: Int]
        ) {
            self.requestCount = requestCount
            self.successfulResponseCount = successfulResponseCount
            self.notModifiedCount = notModifiedCount
            self.cancellationCount = cancellationCount
            self.deliveredBytes = deliveredBytes
            self.duplicateRequestCount = duplicateRequestCount
            self.requestsByResource = requestsByResource
        }
    }

    private let resources: [String: Resource]
    private var requestsByResource: [String: Int] = [:]
    private var successfulResponseCount = 0
    private var notModifiedCount = 0
    private var cancellationCount = 0
    private var deliveredBytes = 0

    package init(resources: [Resource]) {
        self.resources = Dictionary(
            uniqueKeysWithValues: resources.map { ($0.url.absoluteString, $0) })
    }

    package func execute(_ request: TransportRequest) async throws -> TransportResponse {
        guard let url = request.request.url,
            let resource = resources[url.absoluteString]
        else {
            throw URLError(.resourceUnavailable)
        }
        requestsByResource[url.absoluteString, default: 0] += 1

        do {
            if resource.delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: resource.delayNanoseconds)
            }
            try Task.checkCancellation()
        } catch {
            if error is CancellationError { cancellationCount += 1 }
            throw error
        }

        if let etag = header("ETag", in: resource.headers),
            request.request.value(forHTTPHeaderField: "If-None-Match") == etag
        {
            notModifiedCount += 1
            return TransportResponse(
                head: try TransportResponseHead(
                    statusCode: 304, headers: resource.headers, url: url),
                body: Data(),
                metrics: TransportMetrics(receivedBytes: 0, spilledToDisk: false)
            )
        }

        guard resource.body.count <= request.maximumBytes else { throw TransportError.bodyTooLarge }
        successfulResponseCount += 1
        deliveredBytes += resource.body.count
        return TransportResponse(
            head: try TransportResponseHead(statusCode: 200, headers: resource.headers, url: url),
            body: resource.body,
            metrics: TransportMetrics(
                receivedBytes: resource.body.count,
                spilledToDisk: resource.body.count > request.memoryThreshold
            )
        )
    }

    package func metrics() -> Metrics {
        let requestCount = requestsByResource.values.reduce(0, +)
        let duplicateRequestCount = requestsByResource.values.reduce(0) { total, count in
            total + max(0, count - 1)
        }
        return Metrics(
            requestCount: requestCount,
            successfulResponseCount: successfulResponseCount,
            notModifiedCount: notModifiedCount,
            cancellationCount: cancellationCount,
            deliveredBytes: deliveredBytes,
            duplicateRequestCount: duplicateRequestCount,
            requestsByResource: requestsByResource
        )
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
