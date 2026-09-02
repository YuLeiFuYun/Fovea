import Foundation
import FoveaHTTP
import XCTest

final class MultipartJPEGProgressStreamTests: XCTestCase {
    func testProgressDecoderEmitsFramesAcrossArbitraryChunks_W5_PT_052() throws {
        let first = progressJPEG(payload: Data([1, 2, 3]))
        let second = progressJPEG(payload: Data([4, 5, 6, 7]))
        let body = progressMultipart(boundary: "progress", frames: [first, second])
        var decoder = MultipartJPEGProgressDecoder()
        XCTAssertTrue(try decoder.consume(progressResponse(boundary: "progress")).isEmpty)

        var emitted: [MultipartJPEGPart] = []
        var cumulative = 0
        for chunk in progressChunks(body, sizes: [1, 2, 7, 3, 19]) {
            cumulative += chunk.count
            emitted += try decoder.consume(.data(chunk, cumulativeByteCount: cumulative))
        }
        emitted += try decoder.consume(
            .complete(digestHex: String(repeating: "a", count: 64), byteCount: body.count)
        )

        XCTAssertEqual(emitted.map(\.index), [0, 1])
        XCTAssertEqual(emitted.map(\.data), [first, second])
        XCTAssertEqual(decoder.partCount, 2)
        XCTAssertEqual(decoder.receivedByteCount, body.count)
        XCTAssertEqual(decoder.completionDigestHex, String(repeating: "a", count: 64))
        XCTAssertTrue(decoder.isComplete)
    }

    func testProgressDecoderRejectsOrderingStatusAndCumulativeGaps_W5_PT_053() throws {
        let frame = progressJPEG(payload: Data([1]))
        let body = progressMultipart(boundary: "b", frames: [frame])

        var missingResponse = MultipartJPEGProgressDecoder()
        XCTAssertThrowsError(
            try missingResponse.consume(.data(body, cumulativeByteCount: body.count))
        ) { error in
            XCTAssertEqual(error as? MultipartJPEGProgressError, .responseRequired)
        }

        var invalidStatus = MultipartJPEGProgressDecoder()
        let statusHead = try TransportResponseHead(
            statusCode: 206,
            headers: ["Content-Type": "multipart/x-mixed-replace; boundary=b"],
            url: nil
        )
        XCTAssertThrowsError(try invalidStatus.consume(.response(statusHead))) { error in
            XCTAssertEqual(error as? MultipartJPEGProgressError, .invalidResponseStatus)
        }

        var duplicateResponse = MultipartJPEGProgressDecoder()
        _ = try duplicateResponse.consume(progressResponse(boundary: "b"))
        XCTAssertThrowsError(
            try duplicateResponse.consume(progressResponse(boundary: "b"))
        ) { error in
            XCTAssertEqual(error as? MultipartJPEGProgressError, .duplicateResponse)
        }

        var gap = MultipartJPEGProgressDecoder()
        _ = try gap.consume(progressResponse(boundary: "b"))
        XCTAssertThrowsError(
            try gap.consume(.data(body, cumulativeByteCount: body.count + 1))
        ) { error in
            XCTAssertEqual(error as? MultipartJPEGProgressError, .cumulativeByteCountMismatch)
        }
    }

    func testProgressDecoderValidatesCompletionAndFiniteTermination_W5_PT_054() throws {
        let frame = progressJPEG(payload: Data([9, 8, 7]))
        let body = progressMultipart(boundary: "end", frames: [frame])

        var badDigest = MultipartJPEGProgressDecoder()
        _ = try badDigest.consume(progressResponse(boundary: "end"))
        _ = try badDigest.consume(.data(body, cumulativeByteCount: body.count))
        XCTAssertThrowsError(
            try badDigest.consume(.complete(digestHex: "ABC", byteCount: body.count))
        ) { error in
            XCTAssertEqual(error as? MultipartJPEGProgressError, .invalidCompletionDigest)
        }

        var badCount = MultipartJPEGProgressDecoder()
        _ = try badCount.consume(progressResponse(boundary: "end"))
        _ = try badCount.consume(.data(body, cumulativeByteCount: body.count))
        XCTAssertThrowsError(
            try badCount.consume(
                .complete(
                    digestHex: String(repeating: "b", count: 64),
                    byteCount: body.count - 1
                )
            )
        ) { error in
            XCTAssertEqual(error as? MultipartJPEGProgressError, .completionByteCountMismatch)
        }

        var truncated = MultipartJPEGProgressDecoder()
        _ = try truncated.consume(progressResponse(boundary: "end"))
        let prefix = body.dropLast(5)
        _ = try truncated.consume(
            .data(Data(prefix), cumulativeByteCount: prefix.count)
        )
        XCTAssertThrowsError(
            try truncated.consume(
                .complete(
                    digestHex: String(repeating: "c", count: 64),
                    byteCount: prefix.count
                )
            )
        ) { error in
            XCTAssertEqual(error as? MultipartJPEGStreamError, .unexpectedEnd)
        }
    }

    func testProgressDecoderCancellationDiscardsLiveParser_W5_PT_055() throws {
        var decoder = MultipartJPEGProgressDecoder()
        _ = try decoder.consume(progressResponse(boundary: "live"))
        let prefix = Data("--live\r\nContent-Type: image/jpeg\r\n".utf8)
        _ = try decoder.consume(.data(prefix, cumulativeByteCount: prefix.count))
        decoder.cancel()

        XCTAssertThrowsError(
            try decoder.consume(.data(Data([1]), cumulativeByteCount: prefix.count + 1))
        ) { error in
            XCTAssertEqual(error as? MultipartJPEGProgressError, .cancelled)
        }
        XCTAssertFalse(decoder.isComplete)
        XCTAssertEqual(decoder.receivedByteCount, 0)
    }

    func testProgressSubscriptionPreservesOrderAndFinishes_W5_PT_056() async throws {
        let first = progressJPEG(payload: Data([1]))
        let second = progressJPEG(payload: Data([2]))
        let body = progressMultipart(boundary: "stream", frames: [first, second])
        let subscription = MultipartJPEGProgressStream.makeSubscription(
            maximumBufferedParts: 4
        )

        subscription.progressObserver(progressResponse(boundary: "stream"))
        subscription.progressObserver(.data(body, cumulativeByteCount: body.count))
        subscription.progressObserver(
            .complete(digestHex: String(repeating: "d", count: 64), byteCount: body.count)
        )

        var parts: [MultipartJPEGPart] = []
        for try await part in subscription.stream { parts.append(part) }
        XCTAssertEqual(parts.map(\.index), [0, 1])
        XCTAssertEqual(parts.map(\.data), [first, second])
    }

    func testProgressSubscriptionFailsClosedOnBackpressure_W5_PT_057() async throws {
        let first = progressJPEG(payload: Data([1]))
        let second = progressJPEG(payload: Data([2]))
        let body = progressMultipart(boundary: "slow", frames: [first, second])
        let subscription = MultipartJPEGProgressStream.makeSubscription(
            maximumBufferedParts: 1
        )

        subscription.progressObserver(progressResponse(boundary: "slow"))
        subscription.progressObserver(.data(body, cumulativeByteCount: body.count))

        var iterator = subscription.stream.makeAsyncIterator()
        let firstPart = try await iterator.next()
        XCTAssertEqual(firstPart?.index, 0)
        do {
            _ = try await iterator.next()
            XCTFail("Backpressured MJPEG stream silently dropped a frame")
        } catch {
            XCTAssertEqual(error as? MultipartJPEGProgressError, .backpressureExceeded)
        }
    }

    func testProgressSubscriptionCancellationTerminatesConsumer_W5_PT_058() async throws {
        let subscription = MultipartJPEGProgressStream.makeSubscription()
        subscription.progressObserver(progressResponse(boundary: "cancel"))
        subscription.cancel()
        subscription.cancel()

        var iterator = subscription.stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Cancelled MJPEG subscription remained open")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

private func progressResponse(boundary: String) -> TransportProgressEvent {
    .response(
        try! TransportResponseHead(
            statusCode: 200,
            headers: [
                "Content-Type": "multipart/x-mixed-replace; boundary=\(boundary)"
            ],
            url: nil
        )
    )
}

private func progressJPEG(payload: Data) -> Data {
    Data([0xff, 0xd8]) + payload + Data([0xff, 0xd9])
}

private func progressMultipart(boundary: String, frames: [Data]) -> Data {
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

private func progressChunks(_ data: Data, sizes: [Int]) -> [Data] {
    var result: [Data] = []
    var offset = 0
    var sizeIndex = 0
    while offset < data.count {
        let requested = sizes[sizeIndex % sizes.count]
        let end = min(data.count, offset + requested)
        result.append(Data(data[offset..<end]))
        offset = end
        sizeIndex += 1
    }
    return result
}
