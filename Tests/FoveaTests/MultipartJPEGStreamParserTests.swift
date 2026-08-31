import Foundation
import FoveaHTTP
import XCTest

final class MultipartJPEGStreamParserTests: XCTestCase {
    func testOneByteChunksPreserveFrameOrderAndQuotedBoundary_W5_PT_001() throws {
        let first = jpeg(payload: Data([1, 2, 3, 4]))
        let second = jpeg(payload: Data("--safe-boundary-inside-body".utf8))
        let body = multipart(boundary: "safe-boundary", frames: [first, second])
        var parser = try MultipartJPEGStreamParser(
            contentType: "multipart/x-mixed-replace; boundary=\"safe-boundary\""
        )
        var parts: [MultipartJPEGPart] = []
        for byte in body {
            parts += try parser.append(Data([byte]))
        }
        parts += try parser.finish()

        XCTAssertEqual(parts.map(\.index), [0, 1])
        XCTAssertEqual(parts.map(\.data), [first, second])
        XCTAssertEqual(parts[0].headers["content-type"], "image/jpeg")
        XCTAssertTrue(parser.isComplete)
        XCTAssertEqual(parser.partCount, 2)
    }

    func testFiniteBodyWithoutTrailingCRLFCompletesAtFinish_W5_PT_002() throws {
        let frame = jpeg(payload: Data([7, 8, 9]))
        var body = multipart(boundary: "frame", frames: [frame])
        body.removeLast(2)
        var parser = try MultipartJPEGStreamParser(
            contentType: "multipart/x-mixed-replace; boundary=frame"
        )
        let emitted = try parser.append(body)
        XCTAssertEqual(emitted.map(\.data), [frame])
        XCTAssertFalse(parser.isComplete)
        XCTAssertTrue(try parser.finish().isEmpty)
        XCTAssertTrue(parser.isComplete)
    }

    func testRejectsUnsafeContentTypesAndBoundaries_W5_PT_003() {
        for value in [
            "image/jpeg",
            "multipart/x-mixed-replace",
            "multipart/x-mixed-replace; boundary=",
            "multipart/x-mixed-replace; boundary=--already-prefixed",
            "multipart/x-mixed-replace; boundary=a; boundary=b",
            "multipart/x-mixed-replace; boundary=\"unterminated",
            "multipart/x-mixed-replace; boundary=bad\r\ninjected",
        ] {
            XCTAssertThrowsError(try MultipartJPEGStreamParser(contentType: value))
        }
    }

    func testRejectsMissingDuplicateAndInvalidLengthHeaders_W5_PT_004() throws {
        let frame = jpeg(payload: Data([1]))
        let cases: [(Data, MultipartJPEGStreamError)] = [
            (
                rawMultipart(
                    boundary: "b",
                    headers: ["Content-Type: image/jpeg"],
                    body: frame
                ),
                .missingContentLength
            ),
            (
                rawMultipart(
                    boundary: "b",
                    headers: [
                        "Content-Type: image/jpeg",
                        "Content-Length: \(frame.count)",
                        "content-length: \(frame.count)",
                    ],
                    body: frame
                ),
                .malformedHeaders
            ),
            (
                rawMultipart(
                    boundary: "b",
                    headers: ["Content-Type: image/jpeg", "Content-Length: +4"],
                    body: frame
                ),
                .invalidContentLength
            ),
        ]
        for (body, expected) in cases {
            var parser = try MultipartJPEGStreamParser(
                contentType: "multipart/x-mixed-replace; boundary=b"
            )
            XCTAssertThrowsError(try parser.append(body)) { error in
                XCTAssertEqual(error as? MultipartJPEGStreamError, expected)
            }
        }
    }

    func testRejectsWrongPartTypeIncompleteJPEGAndTrailingData_W5_PT_005() throws {
        let valid = jpeg(payload: Data([1, 2]))
        var wrongType = try MultipartJPEGStreamParser(
            contentType: "multipart/x-mixed-replace; boundary=b"
        )
        XCTAssertThrowsError(
            try wrongType.append(
                rawMultipart(
                    boundary: "b",
                    headers: ["Content-Type: image/png", "Content-Length: \(valid.count)"],
                    body: valid
                )
            )
        ) { error in
            XCTAssertEqual(error as? MultipartJPEGStreamError, .unsupportedPartContentType)
        }

        let invalid = Data([0xff, 0xd8, 1, 2, 3, 4])
        var incomplete = try MultipartJPEGStreamParser(
            contentType: "multipart/x-mixed-replace; boundary=b"
        )
        XCTAssertThrowsError(
            try incomplete.append(
                rawMultipart(
                    boundary: "b",
                    headers: ["Content-Type: image/jpeg", "Content-Length: \(invalid.count)"],
                    body: invalid
                )
            )
        ) { error in
            XCTAssertEqual(error as? MultipartJPEGStreamError, .invalidJPEGFrame)
        }

        var complete = try MultipartJPEGStreamParser(
            contentType: "multipart/x-mixed-replace; boundary=b"
        )
        _ = try complete.append(multipart(boundary: "b", frames: [valid]))
        XCTAssertTrue(complete.isComplete)
        XCTAssertThrowsError(try complete.append(Data([1]))) { error in
            XCTAssertEqual(error as? MultipartJPEGStreamError, .trailingData)
        }
    }

    func testLimitsBoundHeadersPartsBodiesAndAggregateBytes_W5_PT_006() throws {
        let frame = jpeg(payload: Data([1, 2, 3, 4]))
        var partLimited = try MultipartJPEGStreamParser(
            contentType: "multipart/x-mixed-replace; boundary=b",
            limits: MultipartJPEGStreamLimits(
                maximumTotalBytes: 1_024,
                maximumPartBytes: frame.count,
                maximumPartCount: 1
            )
        )
        XCTAssertThrowsError(
            try partLimited.append(multipart(boundary: "b", frames: [frame, frame]))
        ) { error in
            XCTAssertEqual(error as? MultipartJPEGStreamError, .limitExceeded)
        }

        var bodyLimited = try MultipartJPEGStreamParser(
            contentType: "multipart/x-mixed-replace; boundary=b",
            limits: MultipartJPEGStreamLimits(
                maximumTotalBytes: 1_024,
                maximumPartBytes: frame.count - 1,
                maximumPartCount: 2
            )
        )
        XCTAssertThrowsError(try bodyLimited.append(multipart(boundary: "b", frames: [frame]))) {
            error in
            XCTAssertEqual(error as? MultipartJPEGStreamError, .limitExceeded)
        }

        var aggregateLimited = try MultipartJPEGStreamParser(
            contentType: "multipart/x-mixed-replace; boundary=b",
            limits: MultipartJPEGStreamLimits(
                maximumTotalBytes: 8,
                maximumPartBytes: 8,
                maximumPartCount: 1
            )
        )
        XCTAssertThrowsError(try aggregateLimited.append(Data(repeating: 1, count: 9))) { error in
            XCTAssertEqual(error as? MultipartJPEGStreamError, .limitExceeded)
        }

        var headerLimited = try MultipartJPEGStreamParser(
            contentType: "multipart/x-mixed-replace; boundary=b",
            limits: MultipartJPEGStreamLimits(
                maximumTotalBytes: 1_024,
                maximumPartBytes: 32,
                maximumPartCount: 1,
                maximumHeaderBytes: 16,
                maximumHeaderCount: 4
            )
        )
        XCTAssertThrowsError(try headerLimited.append(multipart(boundary: "b", frames: [frame]))) {
            error in
            XCTAssertEqual(error as? MultipartJPEGStreamError, .malformedHeaders)
        }
    }

    func testFinishRejectsTruncatedHeadersBodyAndBoundary_W5_PT_007() throws {
        var truncatedBoundary = Data(
            "--b\r\nContent-Type: image/jpeg\r\nContent-Length: 4\r\n\r\n".utf8
        )
        truncatedBoundary.append(Data([0xff, 0xd8, 0xff, 0xd9]))
        truncatedBoundary.append(Data("\r\n--".utf8))
        let prefixes = [
            Data("--b\r\nContent-Type: image/jpeg\r\n".utf8),
            Data("--b\r\nContent-Type: image/jpeg\r\nContent-Length: 8\r\n\r\n".utf8)
                + Data([0xff, 0xd8, 1]),
            truncatedBoundary,
        ]
        for prefix in prefixes {
            var parser = try MultipartJPEGStreamParser(
                contentType: "multipart/x-mixed-replace; boundary=b"
            )
            _ = try? parser.append(prefix)
            XCTAssertThrowsError(try parser.finish()) { error in
                XCTAssertEqual(error as? MultipartJPEGStreamError, .unexpectedEnd)
            }
        }
    }
}

private func jpeg(payload: Data) -> Data {
    Data([0xff, 0xd8]) + payload + Data([0xff, 0xd9])
}

private func multipart(boundary: String, frames: [Data]) -> Data {
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

private func rawMultipart(
    boundary: String,
    headers: [String],
    body: Data
) -> Data {
    var result = Data("--\(boundary)\r\n".utf8)
    result.append(Data(headers.joined(separator: "\r\n").utf8))
    result.append(Data("\r\n\r\n".utf8))
    result.append(body)
    result.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return result
}
