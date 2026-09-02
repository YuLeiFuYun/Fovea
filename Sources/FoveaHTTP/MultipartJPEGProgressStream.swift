import Foundation

package enum MultipartJPEGProgressError: Error, Equatable, Sendable {
    case responseRequired
    case duplicateResponse
    case invalidResponseStatus
    case cumulativeByteCountMismatch
    case invalidCompletionDigest
    case completionByteCountMismatch
    case eventAfterCompletion
    case cancelled
    case backpressureExceeded
}

/// 把 transport progress 事件严格转换为 multipart JPEG parts。
///
/// 该状态机不拥有网络任务，也不赋予 part ContentID 或缓存权限。它只接受一个 200 响应头、
/// 从零开始严格连续的累计字节以及一次匹配的完成事件。有限响应在 complete 时必须通过
/// parser.finish；实时响应由上层取消并丢弃状态，不把取消伪装成完整终止。
package struct MultipartJPEGProgressDecoder: Sendable {
    private enum State: Sendable {
        case awaitingResponse
        case streaming(parser: MultipartJPEGStreamParser, receivedByteCount: Int)
        case completed(partCount: Int, byteCount: Int, digestHex: String)
        case cancelled
    }

    private let limits: MultipartJPEGStreamLimits
    private var state: State = .awaitingResponse

    package init(limits: MultipartJPEGStreamLimits = MultipartJPEGStreamLimits()) {
        self.limits = limits
    }

    package mutating func consume(
        _ event: TransportProgressEvent
    ) throws -> [MultipartJPEGPart] {
        switch state {
        case .awaitingResponse:
            return try consumeAwaitingResponse(event)
        case .streaming(let parser, let receivedByteCount):
            return try consumeStreaming(
                event,
                parser: parser,
                receivedByteCount: receivedByteCount
            )
        case .completed:
            throw MultipartJPEGProgressError.eventAfterCompletion
        case .cancelled:
            throw MultipartJPEGProgressError.cancelled
        }
    }

    private mutating func consumeAwaitingResponse(
        _ event: TransportProgressEvent
    ) throws -> [MultipartJPEGPart] {
        switch event {
        case .response(let head):
            guard head.statusCode == 200 else {
                throw MultipartJPEGProgressError.invalidResponseStatus
            }
            guard let contentType = head.value(forHeader: "content-type") else {
                throw MultipartJPEGStreamError.invalidContentType
            }
            let parser = try MultipartJPEGStreamParser(
                contentType: contentType,
                limits: limits
            )
            state = .streaming(parser: parser, receivedByteCount: 0)
            return []
        case .data, .complete:
            throw MultipartJPEGProgressError.responseRequired
        }
    }

    private mutating func consumeStreaming(
        _ event: TransportProgressEvent,
        parser: MultipartJPEGStreamParser,
        receivedByteCount: Int
    ) throws -> [MultipartJPEGPart] {
        switch event {
        case .response:
            throw MultipartJPEGProgressError.duplicateResponse
        case .data(let data, let cumulativeByteCount):
            return try consumeData(
                data,
                cumulativeByteCount: cumulativeByteCount,
                parser: parser,
                receivedByteCount: receivedByteCount
            )
        case .complete(let digestHex, let byteCount):
            return try consumeCompletion(
                digestHex: digestHex,
                byteCount: byteCount,
                parser: parser,
                receivedByteCount: receivedByteCount
            )
        }
    }

    private mutating func consumeData(
        _ data: Data,
        cumulativeByteCount: Int,
        parser: MultipartJPEGStreamParser,
        receivedByteCount: Int
    ) throws -> [MultipartJPEGPart] {
        let next = receivedByteCount.addingReportingOverflow(data.count)
        guard !next.overflow, next.partialValue == cumulativeByteCount else {
            throw MultipartJPEGProgressError.cumulativeByteCountMismatch
        }
        var parser = parser
        let parts = try parser.append(data)
        state = .streaming(
            parser: parser,
            receivedByteCount: cumulativeByteCount
        )
        return parts
    }

    private mutating func consumeCompletion(
        digestHex: String,
        byteCount: Int,
        parser: MultipartJPEGStreamParser,
        receivedByteCount: Int
    ) throws -> [MultipartJPEGPart] {
        guard Self.isCanonicalSHA256(digestHex) else {
            throw MultipartJPEGProgressError.invalidCompletionDigest
        }
        guard byteCount == receivedByteCount else {
            throw MultipartJPEGProgressError.completionByteCountMismatch
        }
        var parser = parser
        let parts = try parser.finish()
        state = .completed(
            partCount: parser.partCount,
            byteCount: byteCount,
            digestHex: digestHex
        )
        return parts
    }

    package mutating func cancel() {
        state = .cancelled
    }

    package var isComplete: Bool {
        if case .completed = state { return true }
        return false
    }

    package var partCount: Int {
        switch state {
        case .awaitingResponse, .cancelled:
            return 0
        case .streaming(let parser, _):
            return parser.partCount
        case .completed(let partCount, _, _):
            return partCount
        }
    }

    package var receivedByteCount: Int {
        switch state {
        case .awaitingResponse, .cancelled:
            return 0
        case .streaming(_, let receivedByteCount):
            return receivedByteCount
        case .completed(_, let byteCount, _):
            return byteCount
        }
    }

    package var completionDigestHex: String? {
        guard case .completed(_, _, let digestHex) = state else { return nil }
        return digestHex
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
    }
}

/// 一次 MJPEG progress 订阅。取消只关闭本地 parser/stream；网络任务所有权仍由调用方持有。
package struct MultipartJPEGProgressSubscription: Sendable {
    package let stream: AsyncThrowingStream<MultipartJPEGPart, any Error>
    package let progressObserver: TransportProgressObserver
    private let relay: MultipartJPEGProgressRelay

    fileprivate init(
        stream: AsyncThrowingStream<MultipartJPEGPart, any Error>,
        progressObserver: @escaping TransportProgressObserver,
        relay: MultipartJPEGProgressRelay
    ) {
        self.stream = stream
        self.progressObserver = progressObserver
        self.relay = relay
    }

    package func cancel() {
        relay.cancel()
    }

    package func fail(_ error: any Error) {
        relay.fail(error)
    }

    package func finishIfOpenAfterTransportReturn() {
        relay.finishIfOpenAfterTransportReturn()
    }
}

/// 创建一个严格有界、保持 part 顺序的 MJPEG progress 订阅。
package enum MultipartJPEGProgressStream {
    package static func makeSubscription(
        limits: MultipartJPEGStreamLimits = MultipartJPEGStreamLimits(),
        maximumBufferedParts: Int = 8,
        onTermination: @escaping @Sendable () -> Void = {}
    ) -> MultipartJPEGProgressSubscription {
        let capacity = min(1_024, max(1, maximumBufferedParts))
        let pair = AsyncThrowingStream<MultipartJPEGPart, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(capacity)
        )
        let relay = MultipartJPEGProgressRelay(
            decoder: MultipartJPEGProgressDecoder(limits: limits),
            continuation: pair.continuation
        )
        pair.continuation.onTermination = { [weak relay] _ in
            relay?.cancel()
            onTermination()
        }
        return MultipartJPEGProgressSubscription(
            stream: pair.stream,
            progressObserver: { event in relay.observe(event) },
            relay: relay
        )
    }
}

/// transport callback 的同步线性化边界。所有 decoder 状态都在一把锁内变化；yield 在解锁后执行。
private final class MultipartJPEGProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder: MultipartJPEGProgressDecoder
    private var continuation: AsyncThrowingStream<MultipartJPEGPart, any Error>.Continuation?
    private var isTerminal = false

    init(
        decoder: MultipartJPEGProgressDecoder,
        continuation: AsyncThrowingStream<MultipartJPEGPart, any Error>.Continuation
    ) {
        self.decoder = decoder
        self.continuation = continuation
    }

    func observe(_ event: TransportProgressEvent) {
        let (action, continuation) = prepareAction(for: event)
        guard let continuation else { return }
        perform(action, using: continuation)
    }

    private func prepareAction(
        for event: TransportProgressEvent
    ) -> (Action, AsyncThrowingStream<MultipartJPEGPart, any Error>.Continuation?) {
        lock.lock()
        let action = lockedAction(for: event)
        let continuation = self.continuation
        if isTerminal { self.continuation = nil }
        lock.unlock()
        return (action, continuation)
    }

    private func lockedAction(for event: TransportProgressEvent) -> Action {
        guard !isTerminal else { return .none }
        do {
            let parts = try decoder.consume(event)
            let completes = decoder.isComplete
            if completes { isTerminal = true }
            return .parts(parts, completes: completes)
        } catch {
            isTerminal = true
            return .failure(error)
        }
    }

    private func perform(
        _ action: Action,
        using continuation: AsyncThrowingStream<MultipartJPEGPart, any Error>.Continuation
    ) {
        switch action {
        case .none:
            return
        case .failure(let error):
            continuation.finish(throwing: error)
        case .parts(let parts, let completes):
            deliver(parts, completes: completes, using: continuation)
        }
    }

    private func deliver(
        _ parts: [MultipartJPEGPart],
        completes: Bool,
        using continuation: AsyncThrowingStream<MultipartJPEGPart, any Error>.Continuation
    ) {
        for part in parts {
            guard yield(part, using: continuation) else { return }
        }
        if completes { continuation.finish() }
    }

    private func yield(
        _ part: MultipartJPEGPart,
        using continuation: AsyncThrowingStream<MultipartJPEGPart, any Error>.Continuation
    ) -> Bool {
        switch continuation.yield(part) {
        case .enqueued:
            return true
        case .dropped:
            terminateForBackpressure(continuation)
            return false
        case .terminated:
            cancel()
            return false
        @unknown default:
            terminateForBackpressure(continuation)
            return false
        }
    }

    func fail(_ error: any Error) {
        let continuation: AsyncThrowingStream<MultipartJPEGPart, any Error>.Continuation?
        lock.lock()
        guard !isTerminal else {
            lock.unlock()
            return
        }
        isTerminal = true
        decoder.cancel()
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish(throwing: error)
    }

    func finishIfOpenAfterTransportReturn() {
        fail(MultipartJPEGStreamError.unexpectedEnd)
    }

    func cancel() {
        let continuation: AsyncThrowingStream<MultipartJPEGPart, any Error>.Continuation?
        lock.lock()
        guard !isTerminal else {
            lock.unlock()
            return
        }
        isTerminal = true
        decoder.cancel()
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish(throwing: CancellationError())
    }

    private func terminateForBackpressure(
        _ continuation: AsyncThrowingStream<MultipartJPEGPart, any Error>.Continuation
    ) {
        lock.lock()
        if !isTerminal {
            isTerminal = true
            decoder.cancel()
            self.continuation = nil
        }
        lock.unlock()
        continuation.finish(throwing: MultipartJPEGProgressError.backpressureExceeded)
    }

    private enum Action {
        case none
        case parts([MultipartJPEGPart], completes: Bool)
        case failure(any Error)
    }
}
