import Foundation
import ImageCraftCore
import Testing
@_spi(FoveaBenchmarking) @testable import FoveaCore

@Suite("Benchmark transport headers")
struct BenchmarkTransportHeaderTests {
    private func request(headers: [String: String] = [:]) throws -> ImageRequest {
        try ImageRequest(
            url: #require(URL(string: "https://example.com/image.jpg")),
            target: try TargetPixels(width: 320, height: 240),
            contentMode: .fill,
            namespace: SecurityNamespaceID("public"),
            headers: headers
        )
    }

    @Test("benchmark request id reaches transport without changing cache identity")
    func benchmarkHeaderIsTransportOnly() throws {
        let base = try request()
        let instrumented = try base.withBenchmarkTransportHeaders([
            "X-Benchmark-Request-ID": "w1-001-002-token"
        ])

        #expect(instrumented.fetchExecutionKey == base.fetchExecutionKey)
        #expect(instrumented.renderAliasIdentity == base.renderAliasIdentity)
        #expect(instrumented.displayIdentity == base.displayIdentity)

        let urlRequest = FetchRequestPreparation.authorizedRequest(
            for: instrumented,
            conditionalRecord: nil
        )
        #expect(
            urlRequest.value(forHTTPHeaderField: "X-Benchmark-Request-ID")
                == "w1-001-002-token"
        )
    }

    @Test("ordinary semantic header still changes exact execution identity")
    func semanticHeaderStillChangesIdentity() throws {
        let first = try request(headers: ["X-Variant": "a"])
        let second = try request(headers: ["X-Variant": "b"])
        #expect(first.fetchExecutionKey != second.fetchExecutionKey)
        #expect(first.renderAliasIdentity != second.renderAliasIdentity)
    }

    @Test("benchmark transport channel rejects unsafe headers")
    func rejectsUnsafeHeaders() throws {
        let base = try request(headers: ["X-Benchmark-Semantic": "a"])
        #expect(throws: ImageRequestError.self) {
            try base.withBenchmarkTransportHeaders(["Authorization": "Bearer secret"])
        }
        #expect(throws: ImageRequestError.self) {
            try base.withBenchmarkTransportHeaders(["X-Benchmark-Semantic": "b"])
        }
        #expect(throws: ImageRequestError.self) {
            try base.withBenchmarkTransportHeaders(["X-Benchmark-Other": "value"])
        }
        #expect(throws: ImageRequestError.self) {
            try base.withBenchmarkTransportHeaders(["X-Other": "value"])
        }
    }
}
