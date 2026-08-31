import Foundation
import FoveaHTTP
import XCTest

final class MultipartJPEGTransportSessionTests: XCTestCase {
    func testTransportSessionStreamsFramesAndPreservesRequestLimits_W5_PT_059() async throws {
        let first = sessionJPEG(payload: Data([1, 2]))
        let second = sessionJPEG(payload: Data([3, 4]))
        let body = sessionMultipart(boundary: "session", frames: [first, second])
        let transport = SessionTestTransport(mode: .success(body: body, boundary: "session"))
        let request = try sessionRequest(
            maximumBytes: body.count + 10,
            memoryThreshold: 17,
            credentialHeaderNames: ["x-session-secret"],
            priority: .high
        )

        let session = try MultipartJPEGTransport.start(
            transport: transport,
            request: request,
            maximumBufferedParts: 4
        )
        var parts: [MultipartJPEGPart] = []
        for try await part in session.stream { parts.append(part) }

        XCTAssertEqual(parts.map(\.data), [first, second])
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.executeCount, 1)
        XCTAssertEqual(snapshot.maximumBytes, body.count + 10)
        XCTAssertEqual(snapshot.memoryThreshold, 17)
        XCTAssertEqual(snapshot.credentialHeaderNames, ["x-session-secret"])
        XCTAssertEqual(snapshot.priority, .high)
        XCTAssertTrue(snapshot.usedDeferredBodyDelivery)
        XCTAssertTrue(snapshot.hadPriorityController)
    }

    func testTransportErrorTerminatesPartStream_W5_PT_060() async throws {
        let transport = SessionTestTransport(mode: .failure(.incompleteBody))
        let session = try MultipartJPEGTransport.start(
            transport: transport,
            request: try sessionRequest()
        )

        var iterator = session.stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Transport failure did not terminate MJPEG stream")
        } catch {
            XCTAssertEqual(error as? TransportError, .incompleteBody)
        }
    }

    func testTransportReturnWithoutCompleteFailsAsUnexpectedEnd_W5_PT_061() async throws {
        let frame = sessionJPEG(payload: Data([1]))
        let body = sessionMultipart(boundary: "missing", frames: [frame])
        let transport = SessionTestTransport(
            mode: .returnWithoutComplete(body: body, boundary: "missing")
        )
        let session = try MultipartJPEGTransport.start(
            transport: transport,
            request: try sessionRequest(maximumBytes: body.count + 1)
        )

        var iterator = session.stream.makeAsyncIterator()
        let part = try await iterator.next()
        XCTAssertEqual(part?.data, frame)
        do {
            _ = try await iterator.next()
            XCTFail("Transport return without completion was accepted")
        } catch {
            XCTAssertEqual(error as? MultipartJPEGStreamError, .unexpectedEnd)
        }
    }

    func testSessionCancelCancelsTransportAndConsumer_W5_PT_062() async throws {
        let transport = SessionTestTransport(mode: .suspendAfterResponse(boundary: "live"))
        let session = try MultipartJPEGTransport.start(
            transport: transport,
            request: try sessionRequest()
        )
        try await waitUntil("MJPEG transport starts") {
            await transport.snapshot().executeCount == 1
        }

        session.cancel()
        session.cancel()
        try await waitUntil("MJPEG transport observes cancellation") {
            await transport.snapshot().cancellationCount == 1
        }

        var iterator = session.stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Cancelled MJPEG session left stream open")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testConsumerTaskCancellationCancelsTransportTask_W5_PT_063() async throws {
        let transport = SessionTestTransport(mode: .suspendAfterResponse(boundary: "live"))
        let session = try MultipartJPEGTransport.start(
            transport: transport,
            request: try sessionRequest()
        )
        let consumer = Task {
            for try await _ in session.stream {}
        }
        try await waitUntil("MJPEG transport starts for consumer cancellation") {
            await transport.snapshot().executeCount == 1
        }

        consumer.cancel()
        _ = try? await consumer.value
        try await waitUntil("MJPEG consumer cancellation cancels transport") {
            await transport.snapshot().cancellationCount == 1
        }
    }
}

private actor SessionTestTransport: TransportProgressObservationSupporting {
    enum Mode: Sendable {
        case success(body: Data, boundary: String)
        case failure(TransportError)
        case returnWithoutComplete(body: Data, boundary: String)
        case suspendAfterResponse(boundary: String)
    }

    struct Snapshot: Sendable {
        let executeCount: Int
        let cancellationCount: Int
        let maximumBytes: Int?
        let memoryThreshold: Int?
        let credentialHeaderNames: Set<String>
        let priority: TransportPriority?
        let usedDeferredBodyDelivery: Bool
        let hadPriorityController: Bool
    }

    nonisolated let reusePolicy: TransportReusePolicy = .taskLocal
    private let mode: Mode
    private var executeCount = 0
    private var cancellationCount = 0
    private var maximumBytes: Int?
    private var memoryThreshold: Int?
    private var credentialHeaderNames: Set<String> = []
    private var priority: TransportPriority?
    private var usedDeferredBodyDelivery = false
    private var hadPriorityController = false

    init(mode: Mode) {
        self.mode = mode
    }

    func execute(_ request: TransportRequest) async throws -> TransportResponse {
        executeCount += 1
        maximumBytes = request.maximumBytes
        memoryThreshold = request.memoryThreshold
        credentialHeaderNames = request.credentialHeaderNames
        priority = request.priority
        if case .deferredFileIfStaged = request.bodyDelivery {
            usedDeferredBodyDelivery = true
        }
        hadPriorityController = request.priorityController != nil

        switch mode {
        case .failure(let error):
            throw error
        case .success(let body, let boundary):
            let response = try makeResponse(body: body, boundary: boundary)
            request.progressObserver?(.response(response.head))
            request.progressObserver?(.data(body, cumulativeByteCount: body.count))
            request.progressObserver?(
                .complete(digestHex: response.digestHex, byteCount: body.count)
            )
            return response
        case .returnWithoutComplete(let body, let boundary):
            let response = try makeResponse(body: body, boundary: boundary)
            request.progressObserver?(.response(response.head))
            request.progressObserver?(.data(body, cumulativeByteCount: body.count))
            return response
        case .suspendAfterResponse(let boundary):
            let head = try TransportResponseHead(
                statusCode: 200,
                headers: [
                    "Content-Type": "multipart/x-mixed-replace; boundary=\(boundary)"
                ],
                url: nil
            )
            request.progressObserver?(.response(head))
            do {
                try await Task<Never, Never>.sleep(nanoseconds: UInt64.max)
                throw CancellationError()
            } catch is CancellationError {
                cancellationCount += 1
                throw CancellationError()
            }
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            executeCount: executeCount,
            cancellationCount: cancellationCount,
            maximumBytes: maximumBytes,
            memoryThreshold: memoryThreshold,
            credentialHeaderNames: credentialHeaderNames,
            priority: priority,
            usedDeferredBodyDelivery: usedDeferredBodyDelivery,
            hadPriorityController: hadPriorityController
        )
    }

    private func makeResponse(body: Data, boundary: String) throws -> TransportResponse {
        TransportResponse(
            head: try TransportResponseHead(
                statusCode: 200,
                headers: [
                    "Content-Type": "multipart/x-mixed-replace; boundary=\(boundary)"
                ],
                url: nil
            ),
            body: body,
            metrics: TransportMetrics(receivedBytes: body.count, spilledToDisk: false)
        )
    }
}

private func sessionRequest(
    maximumBytes: Int = 1_024,
    memoryThreshold: Int = 128,
    credentialHeaderNames: Set<String> = [],
    priority: TransportPriority = .normal
) throws -> TransportRequest {
    try TransportRequest(
        request: URLRequest(url: URL(string: "https://example.test/live.mjpeg")!),
        maximumBytes: maximumBytes,
        memoryThreshold: memoryThreshold,
        credentialHeaderNames: credentialHeaderNames,
        priority: priority
    )
}

private func sessionJPEG(payload: Data) -> Data {
    Data([0xff, 0xd8]) + payload + Data([0xff, 0xd9])
}

private func sessionMultipart(boundary: String, frames: [Data]) -> Data {
    var result = Data()
    for frame in frames {
        result.append(Data("--\(boundary)\r\n".utf8))
        result.append(Data("Content-Type: image/jpeg\r\n".utf8))
        result.append(Data("Content-Length: \(frame.count)\r\n\r\n".utf8))
        result.append(frame)
        result.append(Data("\r\n".utf8))
    }
    result.append(Data("--\(boundary)--\r\n".utf8))
    return result
}
