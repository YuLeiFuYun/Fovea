import CoreGraphics
import Foundation
@testable import FoveaCore
import FoveaHTTP
import ImageCraftCore
import XCTest

final class T100MultipartJPEGLiveDiagnosticsTests: XCTestCase {
    func testPublicationRecordsDroppedDeltaAndDecodeMetrics_MJPEG_LIVE_DIAG_PT_000() async {
        let image = t100LiveDiagnosticsImage(width: 3, height: 2)
        let output = MultipartJPEGLiveFrameOutput(
            image: image,
            sourcePartIndex: 9,
            droppedEncodedFrameCount: 5,
            decodedFrameCount: 7,
            decodeDurationNanoseconds: 77
        )
        let sink = T100LiveDiagnosticsCaptureSink()

        let returnedDroppedCount = await MultipartJPEGLiveDiagnostics.recordPublication(
            output,
            previousDroppedFrameCount: 2,
            sink: sink,
            keyDigest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        let events = await sink.snapshot()

        XCTAssertEqual(returnedDroppedCount, 5)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].kind, .responseAnomaly)
        XCTAssertEqual(events[0].keyDigest, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(events[0].itemCount, 3)
        XCTAssertEqual(events[0].reason, "mjpeg-live-frame-superseded")
        XCTAssertEqual(events[1].kind, .decodeCompleted)
        XCTAssertEqual(events[1].keyDigest, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(events[1].itemCount, 1)
        XCTAssertEqual(events[1].outputPixelCount, 6)
        XCTAssertEqual(events[1].targetWidth, 3)
        XCTAssertEqual(events[1].targetHeight, 2)
        XCTAssertEqual(events[1].reason, "mjpeg-live-frame-published")
        XCTAssertEqual(events[1].durationNanoseconds, 77)
    }

    func testLivePlaybackErrorsMapToBoundedStableReasons_MJPEG_LIVE_DIAG_PT_001() async {
        let cases: [(MultipartJPEGLivePlaybackError, String)] = [
            (.alreadyStarted, "mjpeg-live-already-started"),
            (.cancelled, "mjpeg-live-cancelled"),
            (.deadlineOverflow, "mjpeg-live-deadline-overflow"),
            (.nonMonotonicClock, "mjpeg-live-non-monotonic-clock"),
            (.sourceIndexRegressed, "mjpeg-live-source-index-regressed"),
        ]

        for (failure, expectedReason) in cases {
            let sink = T100LiveDiagnosticsCaptureSink()
            await MultipartJPEGLiveDiagnostics.recordFailure(
                failure,
                sink: sink,
                keyDigest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            )
            let events = await sink.snapshot()
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events.first?.kind, .responseAnomaly)
            XCTAssertEqual(events.first?.keyDigest, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
            XCTAssertEqual(events.first?.reason, expectedReason)
        }
    }

    func testMultipartStreamErrorsMapToLowCardinalityReasons_MJPEG_LIVE_DIAG_PT_002() async {
        let cases: [(MultipartJPEGStreamError, String)] = [
            (.invalidContentType, "mjpeg-invalid-content-type"),
            (.invalidBoundary, "mjpeg-invalid-boundary"),
            (.limitExceeded, "mjpeg-stream-limit-exceeded"),
            (.malformedBoundary, "mjpeg-malformed-boundary"),
            (.malformedHeaders, "mjpeg-malformed-headers"),
            (.missingContentLength, "mjpeg-missing-content-length"),
            (.invalidContentLength, "mjpeg-invalid-content-length"),
            (.unsupportedPartContentType, "mjpeg-unsupported-part-content-type"),
            (.invalidJPEGFrame, "mjpeg-invalid-jpeg-frame"),
            (.unexpectedEnd, "mjpeg-unexpected-end"),
            (.trailingData, "mjpeg-trailing-data"),
        ]

        for (failure, expectedReason) in cases {
            let sink = T100LiveDiagnosticsCaptureSink()
            await MultipartJPEGLiveDiagnostics.recordFailure(failure, sink: sink, keyDigest: nil)
            let events = await sink.snapshot()
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events.first?.kind, .responseAnomaly)
            XCTAssertNil(events.first?.keyDigest)
            XCTAssertEqual(events.first?.reason, expectedReason)
        }
    }

    func testUnknownFailureFallsBackWithoutLeakingDescription_MJPEG_LIVE_DIAG_PT_003() async {
        struct SecretFailure: Error, CustomStringConvertible {
            let description = "secret-url=https://example.invalid/private?token=abc"
        }

        let sink = T100LiveDiagnosticsCaptureSink()
        await MultipartJPEGLiveDiagnostics.recordFailure(
            SecretFailure(),
            sink: sink,
            keyDigest: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        )
        let events = await sink.snapshot()

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .responseAnomaly)
        XCTAssertEqual(events.first?.keyDigest, "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc")
        XCTAssertEqual(events.first?.reason, "mjpeg-live-failed")
        XCTAssertFalse(events.first?.reason?.contains("example.invalid") ?? true)
        XCTAssertFalse(events.first?.reason?.contains("token") ?? true)
    }
}

private actor T100LiveDiagnosticsCaptureSink: DiagnosticsSink {
    private var events: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) async {
        events.append(event)
    }

    func snapshot() -> [DiagnosticEvent] {
        events
    }
}

private func t100LiveDiagnosticsImage(width: Int, height: Int) -> DecodedImage {
    let bytesPerRow = width * 4
    let data = Data(repeating: 0x7f, count: bytesPerRow * height)
    let provider = CGDataProvider(data: data as CFData)!
    let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
    return DecodedImage(cgImage: image)
}
