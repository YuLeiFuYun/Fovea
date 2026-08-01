import CryptoKit
import Foundation
import FoveaHTTP

/// 按队列消费预设响应并记录请求的确定性传输替身。
/// 它仍执行取消和最大响应体检查，避免单元测试绕过生产传输契约。
package actor FakeHTTPTransport: HTTPTransporting {
    package nonisolated let reusePolicy: TransportReusePolicy

    package struct Stub: Sendable {
        package let statusCode: Int
        package let headers: [String: String]
        package let body: Data
        package let delayNanoseconds: UInt64
        package let networkMetrics: TransportNetworkMetrics?

        package init(
            statusCode: Int,
            headers: [String: String] = [:],
            body: Data = Data(),
            delayNanoseconds: UInt64 = 0,
            networkMetrics: TransportNetworkMetrics? = nil
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.delayNanoseconds = delayNanoseconds
            self.networkMetrics = networkMetrics
        }
    }

    private var stubs: [Stub]
    private var requests: [URLRequest] = []

    package init(
        stubs: [Stub],
        reusePolicy: TransportReusePolicy = .reusable(
            contextIdentifier: "fovea-testing-fake-http-v1"
        )
    ) {
        self.stubs = stubs
        self.reusePolicy = reusePolicy
    }

    package func execute(_ request: TransportRequest) async throws -> TransportResponse {
        requests.append(request.request)
        guard !stubs.isEmpty else { throw URLError(.resourceUnavailable) }
        let stub = stubs.removeFirst()
        if stub.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: stub.delayNanoseconds)
        }
        try Task.checkCancellation()
        guard stub.body.count <= request.maximumBytes else { throw TransportError.bodyTooLarge }
        return TransportResponse(
            head: try TransportResponseHead(
                statusCode: stub.statusCode, headers: stub.headers, url: request.request.url),
            body: stub.body,
            metrics: TransportMetrics(
                receivedBytes: stub.body.count,
                spilledToDisk: stub.body.count > request.memoryThreshold,
                network: stub.networkMetrics
            )
        )
    }

    package func capturedRequests() -> [URLRequest] { requests }
}
