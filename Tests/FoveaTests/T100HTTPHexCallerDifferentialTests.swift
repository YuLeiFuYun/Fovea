import CryptoKit
import Foundation
import FoveaHTTP
import XCTest

final class T100HTTPHexCallerDifferentialTests: XCTestCase {
    func testBoundedStagingDigestMatchesIndependentSHAReferenceInMemoryAndSpilled_HTTP_HEX_PT_001() throws {
        let data = Data((0..<257).map { UInt8(truncatingIfNeeded: ($0 &* 37) ^ 0xA5) })
        let expected = legacyHTTPHex(SHA256.hash(data: data))

        for threshold in [data.count + 1, 0] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("fovea-t100-http-hex-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let accumulator = try BoundedStagingAccumulator(
                maximumBytes: data.count,
                memoryThreshold: threshold,
                stagingDirectory: directory
            )
            try accumulator.append(data.prefix(31))
            try accumulator.append(data.dropFirst(31))
            let body = try accumulator.finalize()

            XCTAssertEqual(body.digestHex, expected)
            XCTAssertEqual(body.byteCount, data.count)
            XCTAssertEqual(try body.materializedData(), data)
            XCTAssertEqual(body.metrics.receivedBytes, data.count)
            XCTAssertEqual(body.metrics.spilledToDisk, threshold == 0)
        }
    }

    func testDestinationPolicyFingerprintMatchesIndependentSortedOriginSHAReference_HTTP_HEX_PT_002() throws {
        let origins: Set<HTTPOrigin> = [
            try HTTPOrigin(url: XCTUnwrap(URL(string: "https://b.example.test:8443/a"))),
            try HTTPOrigin(url: XCTUnwrap(URL(string: "https://a.example.test/path"))),
            try HTTPOrigin(url: XCTUnwrap(URL(string: "http://127.0.0.1:8080/x")))
        ]
        let policy = try HTTPDestinationPolicy.allowOnly(origins)
        var material = Data("destination-origins-v1\u{0}".utf8)
        for origin in origins.map(\.description).sorted() {
            material.append(contentsOf: origin.utf8)
            material.append(0)
        }
        let expected = "destination-origins-v1:\(legacyHTTPHex(SHA256.hash(data: material)))"

        XCTAssertEqual(policy.executionFingerprint, expected)
        XCTAssertEqual(try HTTPDestinationPolicy.allowOnly(origins).executionFingerprint, expected)
    }

    func testURLSessionPolicyFingerprintMatchesIndependentPolicyMaterialSHAReference_HTTP_HEX_PT_003() throws {
        let origins: Set<HTTPOrigin> = [
            try HTTPOrigin(url: XCTUnwrap(URL(string: "https://example.test/resource")))
        ]
        let destination = try HTTPDestinationPolicy.allowOnly(origins)
        let policy = URLSessionTransportPolicy(
            waitsForConnectivity: false,
            requestTimeoutSeconds: 7,
            resourceTimeoutSeconds: 11,
            maximumConnectionsPerHost: 3,
            proxyPolicy: .requireNoProxyInTaskMetrics,
            destinationPolicy: destination
        )
        var destinationMaterial = Data("destination-origins-v1\u{0}".utf8)
        for origin in origins.map(\.description).sorted() {
            destinationMaterial.append(contentsOf: origin.utf8)
            destinationMaterial.append(0)
        }
        let destinationFingerprint =
            "destination-origins-v1:\(legacyHTTPHex(SHA256.hash(data: destinationMaterial)))"
        let policyMaterial = [
            "fovea-url-session-policy-v1",
            "waits:false",
            "request:7",
            "resource:11",
            "connections:3",
            "proxy:requireNoProxyInTaskMetrics",
            "destination:\(destinationFingerprint)"
        ].joined(separator: "\u{0}")
        let expected = legacyHTTPHex(SHA256.hash(data: Data(policyMaterial.utf8)))

        XCTAssertEqual(policy.fingerprint, expected)
    }
}

private func legacyHTTPHex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}
