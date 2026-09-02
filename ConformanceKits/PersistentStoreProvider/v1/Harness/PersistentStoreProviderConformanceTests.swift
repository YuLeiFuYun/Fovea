import Foundation
import FoveaAdvancedSystem
import FoveaCore
import FoveaHTTP
import FoveaSystem
import ImageCraftCore
import XCTest

final class PersistentStoreProviderConformanceTests: XCTestCase {
    private let appID = "persistent-store-provider-conformance-v1"

    override func setUp() async throws {
        try await super.setUp()
        ConformanceNetworkController.shared.reset(mode: .success)
    }

    func testProviderDescriptorAndFingerprintAreStable_PSP_CT_001() throws {
        let first = try ProviderUnderTest.make().descriptor
        let second = try ProviderUnderTest.make().descriptor

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.identifier.isEmpty)
        XCTAssertGreaterThan(first.implementationVersion, 0)
        XCTAssertFalse(first.compatibilityFingerprint.isEmpty)
        XCTAssertEqual(first.cacheFingerprint, second.cacheFingerprint)
    }

    func testFirstLoadAndNetworkFreeReopen_PSP_CT_002_003() async throws {
        let root = try temporaryRoot("reopen")
        let provider = try ProviderUnderTest.make()
        let request = try imageRequest()

        try await withSystem(root: root, provider: provider) { system in
            let image = try await system.pipeline.image(for: request)
            XCTAssertEqual(image.pixelWidth, 1)
            XCTAssertEqual(image.pixelHeight, 1)
            XCTAssertEqual(
                system.persistentStoreProviderFingerprint,
                provider.descriptor.cacheFingerprint
            )
        }
        let firstRequestCount = ConformanceNetworkController.shared.requestCount
        XCTAssertEqual(firstRequestCount, 1)

        ConformanceNetworkController.shared.setMode(.failure)
        try await withSystem(root: root, provider: try ProviderUnderTest.make()) { system in
            let image = try await system.pipeline.image(for: request)
            XCTAssertEqual(image.pixelWidth, 1)
            XCTAssertEqual(image.pixelHeight, 1)
        }
        let reopenedRequestCount = ConformanceNetworkController.shared.requestCount
        XCTAssertEqual(reopenedRequestCount, 1)
    }

    func testRevocationPersistsAcrossReopen_PSP_CT_004() async throws {
        let root = try temporaryRoot("revoke")
        let request = try imageRequest()

        try await withSystem(root: root, provider: try ProviderUnderTest.make()) { system in
            _ = try await system.pipeline.image(for: request)
            try await system.pipeline.revoke(
                namespace: .publicNamespace(appID: appID)
            )
        }
        let preReopenRequestCount = ConformanceNetworkController.shared.requestCount
        XCTAssertEqual(preReopenRequestCount, 1)

        ConformanceNetworkController.shared.setMode(.failure)
        try await withSystem(root: root, provider: try ProviderUnderTest.make()) { system in
            do {
                _ = try await system.pipeline.image(for: request)
                XCTFail("Revoked persistent state must not be resurrected after reopen")
            } catch {
                let revokedRequestCount = ConformanceNetworkController.shared.requestCount
                XCTAssertGreaterThan(revokedRequestCount, 1)
            }
        }
    }

    func testProviderReceivesBoundedOpenRequest_PSP_CT_005() async throws {
        let root = try temporaryRoot("limits")
        let provider = try ProviderUnderTest.make()
        let system = try await FoveaSystemPipeline.open(
            cacheRoot: root,
            persistentStoreProvider: provider,
            encodedSoftTotalBytes: 1_048_576,
            maximumEncodedBlobBytes: 262_144,
            automaticallyPurgesMemoryOnPressure: false,
            sessionConfiguration: sessionConfiguration(),
            transportReusePolicy: .reusable(
                contextIdentifier: "fovea-provider-conformance-v1"
            )
        )
        XCTAssertEqual(
            system.persistentStoreProviderFingerprint,
            provider.descriptor.cacheFingerprint
        )
        await system.invalidateAndCancel()
    }

    private func withSystem(
        root: URL,
        provider: any FoveaPersistentStoreBundleProviding,
        operation: (FoveaSystemPipeline) async throws -> Void
    ) async throws {
        let system = try await FoveaSystemPipeline.open(
            cacheRoot: root,
            persistentStoreProvider: provider,
            automaticallyPurgesMemoryOnPressure: false,
            sessionConfiguration: sessionConfiguration(),
            transportReusePolicy: .reusable(
                contextIdentifier: "fovea-provider-conformance-v1"
            )
        )
        try await operation(system)
        await system.invalidateAndCancel()
    }

    private func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.protocolClasses = [ConformanceURLProtocol.self]
        return configuration
    }

    private func imageRequest() throws -> ImageRequest {
        try ImageRequest.publicImage(
            url: try XCTUnwrap(
                URL(string: "https://conformance.invalid/image.png")
            ),
            target: TargetPixels(width: 1, height: 1),
            appID: appID
        )
    }

    private func temporaryRoot(_ suffix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "fovea-provider-conformance-\(suffix)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}

private final class ConformanceNetworkController: @unchecked Sendable {
    enum Mode: Sendable {
        case success
        case failure
    }

    static let shared = ConformanceNetworkController()

    private let lock = NSLock()
    private var count = 0
    private var mode: Mode = .success

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func reset(mode: Mode) {
        lock.lock()
        count = 0
        self.mode = mode
        lock.unlock()
    }

    func setMode(_ mode: Mode) {
        lock.lock()
        self.mode = mode
        lock.unlock()
    }

    func nextMode() -> Mode {
        lock.lock()
        count += 1
        let current = mode
        lock.unlock()
        return current
    }
}

private final class ConformanceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let png = Data([
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
        0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
        0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x56, 0xc7, 0x2f, 0x0d, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    ])

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "conformance.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        switch ConformanceNetworkController.shared.nextMode() {
        case .success:
            guard let url = request.url,
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "image/png",
                        "Cache-Control": "max-age=3600",
                    ]
                )
            else {
                client?.urlProtocol(
                    self,
                    didFailWithError: URLError(.badServerResponse)
                )
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.png)
            client?.urlProtocolDidFinishLoading(self)
        case .failure:
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.cannotConnectToHost)
            )
        }
    }

    override func stopLoading() {}
}
