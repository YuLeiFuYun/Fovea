import AppleNativeComparatorAdapter
import ComparativeLabCore
import Foundation
import Network
import XCTest

final class AppleNativeComparatorAdapterTests: XCTestCase {
    func testRuntimeConfigurationFreezesURLCacheAndDecodedMemoryBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apple-native-config-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = URLSessionConfiguration.ephemeral
        session.httpMaximumConnectionsPerHost = 6
        let adapter = try AppleNativeComparatorAdapter(
            identity: ComparatorIdentity(
                name: "Apple URLSession + URLCache + ImageIO",
                version: "test",
                platformBuild: ComparatorPlatformBuildIdentity(
                    xcodeBuild: "test-xcode",
                    osBuild: "test-os",
                    deviceProfileID: "test-device"
                )
            ),
            cacheDirectory: directory,
            sessionConfiguration: session
        )
        let parameters = try XCTUnwrap(adapter.runtimeConfiguration?.parameters)
        XCTAssertEqual(parameters["cache.decodedMemoryCostLimitBytes"], "134217728")
        XCTAssertEqual(parameters["cache.protocol"], "URLCache")
        XCTAssertEqual(parameters["cache.protocol.memoryCapacityBytes"], "0")
        XCTAssertEqual(parameters["cache.protocol.diskCapacityBytes"], "268435456")
        XCTAssertEqual(parameters["session.requestCachePolicy"], "useProtocolCachePolicy")
        XCTAssertEqual(parameters["session.httpMaximumConnectionsPerHost"], "6")
        XCTAssertEqual(parameters["session.urlCache"], "custom")
    }

    func testProtocolCachePolicyUsesURLCacheWithoutSecondOriginRequest() async throws {
        let origin = CacheableImageOrigin()
        let url = try await origin.start()
        defer { origin.stop() }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apple-native-urlcache-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let adapter = try AppleNativeComparatorAdapter(
            identity: ComparatorIdentity(
                name: "Apple URLSession + URLCache + ImageIO",
                version: "test",
                platformBuild: ComparatorPlatformBuildIdentity(
                    xcodeBuild: "test-xcode",
                    osBuild: "test-os",
                    deviceProfileID: "test-device"
                )
            ),
            cacheDirectory: directory,
            sessionConfiguration: .ephemeral
        )
        let request = try ComparatorRequest(
            resourceID: "cacheable-image",
            url: url,
            target: ComparatorPixelTarget(width: 1, height: 1),
            contentMode: .aspectFit,
            priority: .visible
        )

        let firstLoad = try await adapter.makeLoad(request)
        let first = await firstLoad.result()
        XCTAssertEqual(first.measurement.outcome, .completed)
        XCTAssertEqual(first.measurement.cacheSource, .network)
        XCTAssertEqual(origin.requestCount, 1)

        await adapter.purgeMemory()
        let secondLoad = try await adapter.makeLoad(request)
        let second = await secondLoad.result()
        XCTAssertEqual(second.measurement.outcome, .completed)
        XCTAssertEqual(second.measurement.cacheSource, .disk)
        XCTAssertEqual(origin.requestCount, 1)
    }
}

private final class CacheableImageOrigin: @unchecked Sendable {
    private final class StartGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, any Error>?

        init(_ continuation: CheckedContinuation<URL, any Error>) {
            self.continuation = continuation
        }

        func resume(with result: Result<URL, any Error>) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    private static let pngData = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZlV8AAAAASUVORK5CYII="
    )!

    private let queue = DispatchQueue(label: "dev.fovea.tests.apple-native-urlcache-origin")
    private let lock = NSLock()
    private var listener: NWListener?
    private var count = 0

    var requestCount: Int {
        lock.lock()
        let value = count
        lock.unlock()
        return value
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let gate = StartGate(continuation)
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters, on: .any)
                self.listener = listener
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard let port = listener.port,
                            let url = URL(string: "http://127.0.0.1:\(port.rawValue)/image.png")
                        else {
                            gate.resume(with: .failure(URLError(.badURL)))
                            return
                        }
                        gate.resume(with: .success(url))
                    case .failed(let error):
                        gate.resume(with: .failure(error))
                    case .cancelled:
                        gate.resume(with: .failure(URLError(.cancelled)))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
            } catch {
                gate.resume(with: .failure(error))
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var request = accumulated
            if let data { request.append(data) }
            if request.range(of: Data("\r\n\r\n".utf8)) == nil, !isComplete,
                request.count < 32_768
            {
                self.receiveRequest(on: connection, accumulated: request)
                return
            }
            self.lock.lock()
            self.count += 1
            self.lock.unlock()
            var response = Data(
                "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(Self.pngData.count)\r\nCache-Control: public, max-age=3600\r\nConnection: close\r\n\r\n"
                    .utf8
            )
            response.append(Self.pngData)
            connection.send(
                content: response,
                completion: .contentProcessed { _ in
                    connection.cancel()
                })
        }
    }
}
