import CryptoKit
import Foundation
import FoveaHTTP
import XCTest

final class T100URLSessionTransportProgressOnlyAdoptionTests: XCTestCase {
    func testProgressOnlyHashesWithoutCreatingStaging_T100_HTTP_PT_001() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [T100ChunkedURLProtocol.self]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "t100-progress-only-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("must-remain-absent", isDirectory: true)
        let transport = URLSessionTransport(
            configuration: configuration,
            stagingDirectory: staging
        )
        let url = try XCTUnwrap(URL(string: "https://t100-transport.example.test/progress-only"))
        let expected = T100ChunkedURLProtocol.body(for: url)
        let recorder = T100TransportProgressRecorder()
        let completion = try await transport.executeProgressOnly(
            try TransportRequest(
                request: URLRequest(url: url),
                maximumBytes: expected.count + 1,
                memoryThreshold: 1,
                credentialHeaderNames: [],
                priority: .normal,
                priorityController: TransportPriorityController(priority: .normal),
                progressObserver: { recorder.record($0) }
            )
        )

        let expectedDigest = SHA256.hash(data: expected)
            .map { String(format: "%02x", $0) }
            .joined()
        let snapshot = recorder.snapshot()
        XCTAssertEqual(completion.head.statusCode, 200)
        XCTAssertEqual(completion.byteCount, expected.count)
        XCTAssertEqual(completion.digestHex, expectedDigest)
        XCTAssertEqual(completion.metrics.receivedBytes, expected.count)
        XCTAssertFalse(completion.metrics.spilledToDisk)
        XCTAssertEqual(snapshot.kinds.first, .response)
        XCTAssertEqual(snapshot.kinds.last, .complete)
        XCTAssertEqual(snapshot.dataByteCounts.last, expected.count)
        XCTAssertEqual(snapshot.completionDigestHex, completion.digestHex)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testProgressOnlyRejectsOversizedChunkBeforeDataPublication_T100_HTTP_PT_002()
        async throws
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [T100OversizedChunkURLProtocol.self]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "t100-progress-only-limit-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("must-remain-absent", isDirectory: true)
        let transport = URLSessionTransport(
            configuration: configuration,
            stagingDirectory: staging
        )
        let url = try XCTUnwrap(URL(string: "https://t100-oversized.example.test/progress-only"))
        let recorder = T100TransportProgressRecorder()

        do {
            _ = try await transport.executeProgressOnly(
                try TransportRequest(
                    request: URLRequest(url: url),
                    maximumBytes: 1_024,
                    memoryThreshold: 1,
                    credentialHeaderNames: [],
                    priority: .normal,
                    priorityController: TransportPriorityController(priority: .normal),
                    progressObserver: { recorder.record($0) }
                )
            )
            XCTFail("Progress-only transport accepted an oversized chunk")
        } catch let error as TransportError {
            XCTAssertEqual(error, .bodyTooLarge)
        }

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.kinds, [.response])
        XCTAssertTrue(snapshot.dataByteCounts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testProgressOnlyCancellationAfterDataClosesTaskAndPublishesNoCompletion_T100_HTTP_PT_003()
        async throws
    {
        T100CancellationURLProtocol.state.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [T100CancellationURLProtocol.self]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "t100-progress-only-cancel-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("must-remain-absent", isDirectory: true)
        let transport = URLSessionTransport(
            configuration: configuration,
            stagingDirectory: staging
        )
        let url = try XCTUnwrap(URL(string: "https://t100-cancel.example.test/progress-only"))
        let recorder = T100TransportProgressRecorder()
        let gate = T100ProgressDataGate()
        let request = try TransportRequest(
            request: URLRequest(url: url),
            maximumBytes: 64 * 1024,
            memoryThreshold: 1,
            credentialHeaderNames: [],
            priority: .normal,
            priorityController: TransportPriorityController(priority: .normal),
            progressObserver: { event in
                recorder.record(event)
                Task { await gate.record(event) }
            }
        )
        let task = Task { try await transport.executeProgressOnly(request) }

        await gate.waitUntilData()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled progress-only transport unexpectedly completed")
        } catch is CancellationError {
            // Expected stable Swift cancellation boundary.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !T100CancellationURLProtocol.state.wasStopped(), clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(T100CancellationURLProtocol.state.wasStopped())
        XCTAssertNil(recorder.snapshot().completionDigestHex)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }


    func testMaterializingExecutionCancellationAfterDataPreservesCancellation_T100_HTTP_PT_004()
        async throws
    {
        T100CancellationURLProtocol.state.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [T100CancellationURLProtocol.self]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "t100-materializing-cancel-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let transport = URLSessionTransport(
            configuration: configuration,
            stagingDirectory: staging
        )
        let url = try XCTUnwrap(URL(string: "https://t100-cancel.example.test/materializing"))
        let recorder = T100TransportProgressRecorder()
        let gate = T100ProgressDataGate()
        let request = try TransportRequest(
            request: URLRequest(url: url),
            maximumBytes: 64 * 1024,
            memoryThreshold: 1,
            credentialHeaderNames: [],
            priority: .normal,
            priorityController: TransportPriorityController(priority: .normal),
            progressObserver: { event in
                recorder.record(event)
                Task { await gate.record(event) }
            }
        )
        let task = Task { try await transport.execute(request) }

        await gate.waitUntilData()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled materializing transport unexpectedly completed")
        } catch is CancellationError {
            // Expected stable Swift cancellation boundary.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !T100CancellationURLProtocol.state.wasStopped(), clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(T100CancellationURLProtocol.state.wasStopped())
        XCTAssertNil(recorder.snapshot().completionDigestHex)
    }
}

private final class T100TransportProgressRecorder: @unchecked Sendable {
    enum Kind: Equatable {
        case response
        case data
        case complete
    }

    struct Snapshot {
        let kinds: [Kind]
        let dataByteCounts: [Int]
        let completionDigestHex: String?
    }

    private let lock = NSLock()
    private var kinds: [Kind] = []
    private var dataByteCounts: [Int] = []
    private var completionDigestHex: String?

    func record(_ event: TransportProgressEvent) {
        lock.withLock {
            switch event {
            case .response:
                kinds.append(.response)
            case .data(_, let cumulativeByteCount):
                kinds.append(.data)
                dataByteCounts.append(cumulativeByteCount)
            case .complete(let digestHex, _):
                kinds.append(.complete)
                completionDigestHex = digestHex
            }
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                kinds: kinds,
                dataByteCounts: dataByteCounts,
                completionDigestHex: completionDigestHex
            )
        }
    }
}

private actor T100ProgressDataGate {
    private var dataSeen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record(_ event: TransportProgressEvent) {
        guard case .data = event, !dataSeen else { return }
        dataSeen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll(keepingCapacity: false)
    }

    func waitUntilData() async {
        guard !dataSeen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class T100CancellationProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func reset() {
        lock.withLock { stopped = false }
    }

    func markStopped() {
        lock.withLock { stopped = true }
    }

    func wasStopped() -> Bool {
        lock.withLock { stopped }
    }
}

private final class T100CancellationURLProtocol: URLProtocol {
    static let state = T100CancellationProtocolState()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "t100-cancel.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/octet-stream",
                "Content-Length": String(64 * 1024),
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0x5a, count: 4096))
    }

    override func stopLoading() {
        Self.state.markStopped()
    }
}

private final class T100OversizedChunkURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "t100-oversized.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 7, count: 4096))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class T100ChunkedURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "t100-transport.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.body(for: url)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/octet-stream",
                "Content-Length": String(body.count),
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for start in stride(from: 0, to: body.count, by: 4096) {
            let end = min(body.count, start + 4096)
            client?.urlProtocol(self, didLoad: body.subdata(in: start..<end))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(for url: URL) -> Data {
        Data((0..<(128 * 1024)).map { UInt8($0 % 251) })
    }
}
