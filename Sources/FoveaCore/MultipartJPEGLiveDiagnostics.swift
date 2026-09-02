import Foundation
import FoveaHTTP
import ImageCraftCore

/// 将 live MJPEG 的发布与失败压缩为现有低基数诊断词汇；不得记录 URL、boundary、请求头或帧正文。
package enum MultipartJPEGLiveDiagnostics {
    package static func recordPublication(
        _ output: MultipartJPEGLiveFrameOutput,
        previousDroppedFrameCount: UInt64,
        sink: any DiagnosticsSink,
        keyDigest: String?
    ) async -> UInt64 {
        let droppedDelta =
            output.droppedEncodedFrameCount >= previousDroppedFrameCount
            ? output.droppedEncodedFrameCount - previousDroppedFrameCount
            : 0
        if droppedDelta > 0 {
            await sink.record(
                DiagnosticEvent(
                    kind: .responseAnomaly,
                    keyDigest: keyDigest,
                    itemCount: boundedInt(droppedDelta),
                    reason: "mjpeg-live-frame-superseded"
                )
            )
        }
        await sink.record(
            DiagnosticEvent(
                kind: .decodeCompleted,
                keyDigest: keyDigest,
                itemCount: 1,
                outputPixelCount: pixelCount(output.image),
                targetWidth: output.image.pixelWidth,
                targetHeight: output.image.pixelHeight,
                reason: "mjpeg-live-frame-published",
                durationNanoseconds: output.decodeDurationNanoseconds
            )
        )
        return output.droppedEncodedFrameCount
    }

    package static func recordFailure(
        _ error: any Error,
        sink: any DiagnosticsSink,
        keyDigest: String?
    ) async {
        await sink.record(
            DiagnosticEvent(
                kind: .responseAnomaly,
                keyDigest: keyDigest,
                reason: reason(for: error)
            )
        )
    }

    private static func pixelCount(_ image: DecodedImage) -> Int {
        let value = image.pixelWidth.multipliedReportingOverflow(by: image.pixelHeight)
        return value.overflow ? Int.max : value.partialValue
    }

    private static func boundedInt(_ value: UInt64) -> Int {
        value > UInt64(Int.max) ? Int.max : Int(value)
    }

    private static func reason(for error: any Error) -> String {
        if let failure = error as? PipelineFailure { return failure.reasonCode }
        if let live = error as? MultipartJPEGLivePlaybackError { return reason(for: live) }
        if let stream = error as? MultipartJPEGStreamError { return reason(for: stream) }
        return "mjpeg-live-failed"
    }

    private static func reason(for error: MultipartJPEGLivePlaybackError) -> String {
        switch error {
        case .alreadyStarted: "mjpeg-live-already-started"
        case .cancelled: "mjpeg-live-cancelled"
        case .deadlineOverflow: "mjpeg-live-deadline-overflow"
        case .nonMonotonicClock: "mjpeg-live-non-monotonic-clock"
        case .sourceIndexRegressed: "mjpeg-live-source-index-regressed"
        }
    }

    private static func reason(for error: MultipartJPEGStreamError) -> String {
        switch error {
        case .invalidContentType: "mjpeg-invalid-content-type"
        case .invalidBoundary: "mjpeg-invalid-boundary"
        case .limitExceeded: "mjpeg-stream-limit-exceeded"
        case .malformedBoundary: "mjpeg-malformed-boundary"
        case .malformedHeaders: "mjpeg-malformed-headers"
        case .missingContentLength: "mjpeg-missing-content-length"
        case .invalidContentLength: "mjpeg-invalid-content-length"
        case .unsupportedPartContentType: "mjpeg-unsupported-part-content-type"
        case .invalidJPEGFrame: "mjpeg-invalid-jpeg-frame"
        case .unexpectedEnd: "mjpeg-unexpected-end"
        case .trailingData: "mjpeg-trailing-data"
        }
    }
}
