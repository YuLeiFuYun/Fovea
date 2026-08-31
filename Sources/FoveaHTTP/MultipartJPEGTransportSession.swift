import Foundation

/// 把一个有界 transport task 与 MJPEG part stream 绑定的所有权对象。
package struct MultipartJPEGTransportSession: Sendable {
    package let stream: AsyncThrowingStream<MultipartJPEGPart, any Error>
    private let owner: MultipartJPEGTransportOwner

    fileprivate init(
        stream: AsyncThrowingStream<MultipartJPEGPart, any Error>,
        owner: MultipartJPEGTransportOwner
    ) {
        self.stream = stream
        self.owner = owner
    }

    /// 取消网络任务和本地 parser；重复调用安全。
    package func cancel() {
        owner.cancel()
    }
}

/// 为具备同源 progress 保证的 transport 创建 MJPEG session。
package enum MultipartJPEGTransport {
    package static func start(
        transport: any TransportProgressObservationSupporting,
        request: TransportRequest,
        limits: MultipartJPEGStreamLimits = MultipartJPEGStreamLimits(),
        maximumBufferedParts: Int = 8
    ) throws -> MultipartJPEGTransportSession {
        try start(
            execute: { request in
                let response = try await transport.execute(request)
                return TransportProgressCompletion(
                    head: response.head,
                    digestHex: response.digestHex,
                    byteCount: response.bodyByteCount,
                    metrics: response.metrics
                )
            },
            request: request,
            limits: limits,
            maximumBufferedParts: maximumBufferedParts
        )
    }

    package static func start(
        execute:
            @escaping @Sendable (TransportRequest) async throws
            -> TransportProgressCompletion,
        request: TransportRequest,
        limits: MultipartJPEGStreamLimits = MultipartJPEGStreamLimits(),
        maximumBufferedParts: Int = 8
    ) throws -> MultipartJPEGTransportSession {
        let owner = MultipartJPEGTransportOwner()
        let subscription = MultipartJPEGProgressStream.makeSubscription(
            limits: limits,
            maximumBufferedParts: maximumBufferedParts,
            onTermination: { owner.cancelTransportOnly() }
        )
        let priorityController = TransportPriorityController(priority: request.priority)
        let streamingRequest = try TransportRequest(
            request: request.request,
            maximumBytes: request.maximumBytes,
            memoryThreshold: request.memoryThreshold,
            credentialHeaderNames: request.credentialHeaderNames,
            priority: request.priority,
            bodyDelivery: .deferredFileIfStaged,
            priorityController: priorityController,
            progressObserver: subscription.progressObserver
        )
        let task = Task {
            defer { owner.transportFinished() }
            do {
                _ = try await execute(streamingRequest)
                subscription.finishIfOpenAfterTransportReturn()
            } catch is CancellationError {
                subscription.cancel()
            } catch {
                subscription.fail(error)
            }
        }
        owner.install(task: task, subscription: subscription)
        return MultipartJPEGTransportSession(stream: subscription.stream, owner: owner)
    }
}

/// stream termination、显式 cancel 与 transport completion 之间的同步任务所有权栅栏。
private final class MultipartJPEGTransportOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var subscription: MultipartJPEGProgressSubscription?
    private var isCancelled = false

    func install(
        task: Task<Void, Never>,
        subscription: MultipartJPEGProgressSubscription
    ) {
        let shouldCancel: Bool
        lock.lock()
        if isCancelled {
            shouldCancel = true
        } else {
            self.task = task
            self.subscription = subscription
            shouldCancel = false
        }
        lock.unlock()
        if shouldCancel {
            task.cancel()
            subscription.cancel()
        }
    }

    func cancel() {
        let task: Task<Void, Never>?
        let subscription: MultipartJPEGProgressSubscription?
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        task = self.task
        subscription = self.subscription
        self.task = nil
        self.subscription = nil
        lock.unlock()
        task?.cancel()
        subscription?.cancel()
    }

    func transportFinished() {
        lock.lock()
        task = nil
        lock.unlock()
    }

    func cancelTransportOnly() {
        let task: Task<Void, Never>?
        lock.lock()
        task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}
