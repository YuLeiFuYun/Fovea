import Foundation

/// 拒绝无法形成安全、可复用预取结果的请求。
public enum ImagePrefetchError: Error, Equatable, Sendable {
    case invalidMaximumConcurrentRequests
    case reusableOriginalRequiresCrossRequestReuse
    case responseNotReusable
}

/// 预取完成后希望保留的最低成本层级。
public enum ImagePrefetchDestination: Sendable {
    /// 完整走现有图像管线，允许发布可复用的渲染内存结果。
    case renderedImage
    /// 只做传输、HTTP 校验和 bounded image probe/capability 校验，持久化原编码字节；
    /// 不执行像素 decode 或 transform。
    case validatedOriginal
}

/// 一批预取请求的聚合结果。
///
/// 预取只返回计数，不把解码像素或单项错误对象带出批次边界。每个单项失败仍由
/// `FoveaPipeline` 的既有诊断与错误语义记录；调用方可据此决定是否在真实可见请求中重试。
public struct ImagePrefetchResult: Equatable, Sendable {
    public let requestedCount: Int
    public let uniqueRequestCount: Int
    public let succeededCount: Int
    public let failedCount: Int
    public let cancelledCount: Int

    /// 因稳定显示身份相同而在批次入口合并的请求数量。
    public var duplicateCount: Int { requestedCount - uniqueRequestCount }
}

private enum ImagePrefetchItemOutcome: Sendable {
    case succeeded
    case failed
    case cancelled
}

private struct ImagePrefetchBatchState {
    let requests: [ImageRequest]
    private(set) var nextIndex = 0
    private(set) var succeededCount = 0
    private(set) var failedCount = 0
    private(set) var cancelledCount = 0

    mutating func takeNext() -> ImageRequest? {
        guard nextIndex < requests.count else { return nil }
        defer { nextIndex += 1 }
        return requests[nextIndex]
    }

    mutating func record(_ outcome: ImagePrefetchItemOutcome) {
        switch outcome {
        case .succeeded:
            succeededCount += 1
        case .failed:
            failedCount += 1
        case .cancelled:
            cancelledCount += 1
        }
    }

    func result(requestedCount: Int) -> ImagePrefetchResult {
        ImagePrefetchResult(
            requestedCount: requestedCount,
            uniqueRequestCount: requests.count,
            succeededCount: succeededCount,
            failedCount: failedCount,
            cancelledCount: cancelledCount
        )
    }
}

extension FoveaPipeline {
    /// 以低优先级并发预热一批图像请求。
    ///
    /// 该入口不建立第二套下载器、缓存或调度器。完整图像预取复用 `image(for:)`；
    /// 原编码预取复用同一 HTTP/cache/namespace 组件，并在持久化前执行 bounded probe 与
    /// codec capability admission。两种 destination 共用同一个有界 batch scheduler。
    ///
    /// - Parameter requests: 要预热的不可变请求；结果不包含像素。
    /// - Parameter destination: 默认完整图像；`.validatedOriginal` 不执行像素 decode/transform。
    /// - Parameter maximumConcurrentRequests: 批次最多同时提交的请求数；还会受 pipeline
    ///   自身 `maximumConcurrentFetches` 上限约束。必须大于零。
    /// - Returns: 去重后成功、失败与单项取消的聚合计数。
    /// - Throws: 非法并发上限，或父任务取消。
    @concurrent
    public func prefetch(
        _ requests: [ImageRequest],
        destination: ImagePrefetchDestination = .renderedImage,
        maximumConcurrentRequests: Int = 4
    ) async throws -> ImagePrefetchResult {
        try Self.validatePrefetchConcurrency(maximumConcurrentRequests)
        try Task.checkCancellation()
        let uniqueRequests = Self.uniquePrefetchRequests(requests)
        let concurrency = prefetchConcurrency(
            requestCount: uniqueRequests.count,
            requestedMaximum: maximumConcurrentRequests
        )
        let state = await runPrefetchBatch(
            uniqueRequests,
            destination: destination,
            concurrency: concurrency
        )
        try Task.checkCancellation()
        return state.result(requestedCount: requests.count)
    }

    private func runPrefetchBatch(
        _ requests: [ImageRequest],
        destination: ImagePrefetchDestination,
        concurrency: Int
    ) async -> ImagePrefetchBatchState {
        var state = ImagePrefetchBatchState(requests: requests)
        await withTaskGroup(of: ImagePrefetchItemOutcome.self) { group in
            for _ in 0..<concurrency {
                addNextPrefetch(to: &group, state: &state, destination: destination)
            }
            while let outcome = await group.next() {
                state.record(outcome)
                if Task.isCancelled {
                    group.cancelAll()
                } else {
                    addNextPrefetch(to: &group, state: &state, destination: destination)
                }
            }
        }
        return state
    }

    private func addNextPrefetch(
        to group: inout TaskGroup<ImagePrefetchItemOutcome>,
        state: inout ImagePrefetchBatchState,
        destination: ImagePrefetchDestination
    ) {
        guard let request = state.takeNext() else { return }
        group.addTask { [self] in
            await prefetchOutcome(for: request, destination: destination)
        }
    }

    private func prefetchOutcome(
        for request: ImageRequest,
        destination: ImagePrefetchDestination
    ) async -> ImagePrefetchItemOutcome {
        do {
            try await performPrefetch(request, destination: destination)
            return .succeeded
        } catch is CancellationError {
            return .cancelled
        } catch let failure as PipelineFailure where failure.disposition == .cancelled {
            return .cancelled
        } catch {
            return .failed
        }
    }

    private func performPrefetch(
        _ request: ImageRequest,
        destination: ImagePrefetchDestination
    ) async throws {
        let priority = min(request.priority, .low)
        let request = request.reprioritized(priority)
        switch destination {
        case .renderedImage:
            _ = try await image(for: request)
        case .validatedOriginal:
            try await imageCoordinator.prefetchValidatedOriginal(request: request)
        }
    }

    private func prefetchConcurrency(requestCount: Int, requestedMaximum: Int) -> Int {
        min(requestedMaximum, configuration.maximumConcurrentFetches, requestCount)
    }

    private static func validatePrefetchConcurrency(_ value: Int) throws {
        guard value > 0 else { throw ImagePrefetchError.invalidMaximumConcurrentRequests }
    }

    private static func uniquePrefetchRequests(_ requests: [ImageRequest]) -> [ImageRequest] {
        var identities: Set<String> = []
        return requests.filter { identities.insert($0.displayIdentity).inserted }
    }
}
