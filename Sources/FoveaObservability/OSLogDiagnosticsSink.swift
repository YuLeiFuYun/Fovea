import Foundation
@_spi(DetailedDiagnostics) import FoveaCore

/// 生产诊断事件的采样策略。
///
/// 采样只决定事件是否进入 OSLog，不参与请求身份、缓存键、调度或重试决策。
public struct OSLogDiagnosticsSampling: Hashable, Sendable {
    package enum Mode: Hashable, Sendable {
        case all
        case failuresOnly
        case oneIn(UInt32)
    }

    package let mode: Mode

    private init(mode: Mode) {
        self.mode = mode
    }

    /// 记录全部诊断事件。
    public static let all = OSLogDiagnosticsSampling(mode: .all)

    /// 只记录失败、取消、安全异常、缓存降级和诊断丢弃事件。
    public static let failuresOnly = OSLogDiagnosticsSampling(mode: .failuresOnly)

    /// 按短期 correlation digest 一致采样约 `1 / denominator` 的普通事件。
    ///
    /// 同一 correlation 的开始、过程和成功终止事件会做出相同采样决定；关键失败事件始终记录。
    public static func oneIn(_ denominator: UInt32) -> OSLogDiagnosticsSampling {
        OSLogDiagnosticsSampling(mode: .oneIn(max(1, denominator)))
    }
}

/// OSLog 诊断配置的验证失败。

public enum OSLogDiagnosticsConfigurationError: Error, Equatable, Sendable {
    /// 子系统为空、超限或包含不支持的字符。
    case invalidSubsystem
    /// 类别为空、超限或包含不支持的字符。
    case invalidCategory
}

/// 约束 OSLog 采样、signpost、子系统名称与活动区间。

public struct OSLogDiagnosticsConfiguration: Hashable, Sendable {
    /// 已验证的统一日志子系统。
    public let subsystem: String
    /// 已验证的统一日志类别。
    public let category: String
    /// 非关键事件使用的确定性采样规则。
    public let sampling: OSLogDiagnosticsSampling
    /// 生命周期事件是否同时发出 Instruments signpost。
    public let signpostsEnabled: Bool
    /// 同时打开的获取与解码区间全局上限。
    public let maximumActiveIntervals: Int

    /// 创建有界且已验证的统一日志配置。
    public init(
        subsystem: String,
        category: String = "diagnostics",
        sampling: OSLogDiagnosticsSampling = .all,
        signpostsEnabled: Bool = true,
        maximumActiveIntervals: Int = 4_096
    ) throws {
        guard Self.isValidIdentifier(subsystem, maximumBytes: 128) else {
            throw OSLogDiagnosticsConfigurationError.invalidSubsystem
        }
        guard Self.isValidIdentifier(category, maximumBytes: 64) else {
            throw OSLogDiagnosticsConfigurationError.invalidCategory
        }
        self.subsystem = subsystem
        self.category = category
        self.sampling = sampling
        self.signpostsEnabled = signpostsEnabled
        self.maximumActiveIntervals = min(65_536, max(1, maximumActiveIntervals))
    }

    private static func isValidIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= maximumBytes
            && bytes.allSatisfy { byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                    || byte == 45 || byte == 46 || byte == 95
            }
    }
}

/// 将脱敏 `DiagnosticEvent` 输出到 Unified Logging 与 Instruments signpost。
///
/// 动态 payload 始终使用 Unified Logging 的 private 标记。即使事件已经过 schema 清洗，
/// correlation digest、尺寸、网络路径和时序组合仍可能形成行为指纹，因此不公开输出。
/// Fovea 管线会自动把外部 sink 放到有界单消费者 relay 后执行，因此系统日志写入不会
/// 阻塞网络、解码、持久化或最终图片交付。该 sink 不上传、持久化管理或关联业务身份。
public actor OSLogDiagnosticsSink: DiagnosticsSink {
    private struct ActiveInterval: Sendable {
        let identifier: UInt64
        var sequence: UInt64
    }

    private let configuration: OSLogDiagnosticsConfiguration
    private let emitter: any OSLogDiagnosticsEmitting
    private var activeFetchIntervals: [String: ActiveInterval] = [:]
    private var activeDecodeIntervals: [String: ActiveInterval] = [:]
    private var nextIntervalSequence: UInt64 = 0

    /// 创建由系统统一日志发射器支持的诊断接收器。
    public init(configuration: OSLogDiagnosticsConfiguration) {
        self.configuration = configuration
        self.emitter = SystemOSLogDiagnosticsEmitter(configuration: configuration)
    }

    package init(
        configuration: OSLogDiagnosticsConfiguration,
        emitter: any OSLogDiagnosticsEmitting,
        initialIntervalSequence: UInt64 = 0
    ) {
        self.configuration = configuration
        self.emitter = emitter
        self.nextIntervalSequence = initialIntervalSequence
    }

    /// 按照采样与 signpost 策略记录脱敏事件。
    public func record(_ event: DiagnosticEvent) async {
        guard shouldRecord(event) else { return }
        let message = OSLogDiagnosticMessage(event: event).description
        await emitter.emitLog(level: Self.level(for: event.kind), message: message)
        guard configuration.signpostsEnabled else { return }
        if event.kind == .diagnosticsDropped {
            await closeAllIntervals(message: message)
        }
        await emitSignpost(for: event, message: message)
    }

    private func shouldRecord(_ event: DiagnosticEvent) -> Bool {
        if Self.isCritical(event.kind) { return true }
        switch configuration.sampling.mode {
        case .all:
            return true
        case .failuresOnly:
            return false
        case .oneIn(let denominator):
            guard let digest = event.keyDigest else { return true }
            guard let prefix = UInt64(digest.prefix(16), radix: 16) else { return true }
            return prefix % UInt64(denominator) == 0
        }
    }

    private func emitSignpost(for event: DiagnosticEvent, message: String) async {
        switch event.kind {
        case .fetchStarted:
            await beginInterval(.fetch, key: event.keyDigest, message: message)
        case .fetchCompleted, .fetchCancelled, .fetchFailed:
            await endInterval(.fetch, key: event.keyDigest, message: message)
        case .decodeStarted:
            await beginInterval(.decode, key: event.keyDigest, message: message)
        case .decodeCompleted, .decodeCancelled, .decodeFailed:
            await endInterval(.decode, key: event.keyDigest, message: message)
        default:
            await emitter.emitSignpost(
                operation: .event,
                interval: Self.signpostInterval(for: event.kind),
                id: await emitter.makeSignpostID(),
                message: message
            )
        }
    }

    private func beginInterval(
        _ interval: OSLogDiagnosticsInterval,
        key: String?,
        message: String
    ) async {
        guard let key else {
            await emitter.emitSignpost(
                operation: .event,
                interval: interval,
                id: await emitter.makeSignpostID(),
                message: message
            )
            return
        }

        var active = activeIntervals(for: interval)
        if let existing = active[key] {
            await emitter.emitSignpost(
                operation: .event,
                interval: interval,
                id: existing.identifier,
                message: message
            )
            return
        }

        if activeIntervalCount() >= configuration.maximumActiveIntervals {
            await evictOldestActiveInterval()
            active = activeIntervals(for: interval)
        }

        let identifier = await emitter.makeSignpostID()
        active[key] = ActiveInterval(
            identifier: identifier,
            sequence: nextIntervalSequenceValue()
        )
        setActiveIntervals(active, for: interval)
        await emitter.emitSignpost(
            operation: .begin,
            interval: interval,
            id: identifier,
            message: message
        )
    }

    private func nextIntervalSequenceValue() -> UInt64 {
        if nextIntervalSequence == UInt64.max {
            rebaseActiveIntervalSequences()
        }
        nextIntervalSequence += 1
        return nextIntervalSequence
    }

    private func rebaseActiveIntervalSequences() {
        enum Stage: Int {
            case fetch
            case decode
        }
        let ordered =
            (activeFetchIntervals.map { (Stage.fetch, $0.key, $0.value) }
            + activeDecodeIntervals.map { (Stage.decode, $0.key, $0.value) }).sorted { lhs, rhs in
                if lhs.2.sequence != rhs.2.sequence { return lhs.2.sequence < rhs.2.sequence }
                if lhs.0.rawValue != rhs.0.rawValue { return lhs.0.rawValue < rhs.0.rawValue }
                return lhs.1 < rhs.1
            }

        for (offset, element) in ordered.enumerated() {
            var interval = element.2
            interval.sequence = UInt64(offset + 1)
            switch element.0 {
            case .fetch:
                activeFetchIntervals[element.1] = interval
            case .decode:
                activeDecodeIntervals[element.1] = interval
            }
        }
        nextIntervalSequence = UInt64(ordered.count)
    }

    private func endInterval(
        _ interval: OSLogDiagnosticsInterval,
        key: String?,
        message: String
    ) async {
        guard let key else {
            await emitter.emitSignpost(
                operation: .event,
                interval: interval,
                id: await emitter.makeSignpostID(),
                message: message
            )
            return
        }

        var active = activeIntervals(for: interval)
        guard let activeInterval = active.removeValue(forKey: key) else {
            await emitter.emitSignpost(
                operation: .event,
                interval: interval,
                id: await emitter.makeSignpostID(),
                message: message
            )
            return
        }
        setActiveIntervals(active, for: interval)
        await emitter.emitSignpost(
            operation: .end,
            interval: interval,
            id: activeInterval.identifier,
            message: message
        )
    }

    package func activeIntervalCount() -> Int {
        activeFetchIntervals.count + activeDecodeIntervals.count
    }

    private func evictOldestActiveInterval() async {
        let fetch = activeFetchIntervals.min { $0.value.sequence < $1.value.sequence }
        let decode = activeDecodeIntervals.min { $0.value.sequence < $1.value.sequence }
        let message = "schema=6 kind=diagnosticsDropped reason=active-signpost-capacity"
        switch (fetch, decode) {
        case (.some(let fetch), .some(let decode))
        where fetch.value.sequence <= decode.value.sequence:
            activeFetchIntervals.removeValue(forKey: fetch.key)
            await emitter.emitSignpost(
                operation: .end,
                interval: .fetch,
                id: fetch.value.identifier,
                message: message
            )
        case (.some(_), .some(let decode)):
            activeDecodeIntervals.removeValue(forKey: decode.key)
            await emitter.emitSignpost(
                operation: .end,
                interval: .decode,
                id: decode.value.identifier,
                message: message
            )
        case (.some(let fetch), .none):
            activeFetchIntervals.removeValue(forKey: fetch.key)
            await emitter.emitSignpost(
                operation: .end,
                interval: .fetch,
                id: fetch.value.identifier,
                message: message
            )
        case (.none, .some(let decode)):
            activeDecodeIntervals.removeValue(forKey: decode.key)
            await emitter.emitSignpost(
                operation: .end,
                interval: .decode,
                id: decode.value.identifier,
                message: message
            )
        case (.none, .none):
            break
        }
    }

    private func closeAllIntervals(message: String) async {
        for active in activeFetchIntervals.values {
            await emitter.emitSignpost(
                operation: .end,
                interval: .fetch,
                id: active.identifier,
                message: message
            )
        }
        for active in activeDecodeIntervals.values {
            await emitter.emitSignpost(
                operation: .end,
                interval: .decode,
                id: active.identifier,
                message: message
            )
        }
        activeFetchIntervals.removeAll(keepingCapacity: false)
        activeDecodeIntervals.removeAll(keepingCapacity: false)
    }

    private func activeIntervals(
        for interval: OSLogDiagnosticsInterval
    ) -> [String: ActiveInterval] {
        switch interval {
        case .fetch: activeFetchIntervals
        case .decode: activeDecodeIntervals
        case .cache, .pipeline, .general: [:]
        }
    }

    private func setActiveIntervals(
        _ intervals: [String: ActiveInterval],
        for interval: OSLogDiagnosticsInterval
    ) {
        switch interval {
        case .fetch: activeFetchIntervals = intervals
        case .decode: activeDecodeIntervals = intervals
        case .cache, .pipeline, .general: break
        }
    }

    private static func level(for kind: DiagnosticEventKind) -> OSLogDiagnosticsLevel {
        switch kind {
        case .pipelineFailed, .fetchFailed, .decodeFailed, .decodeAdmissionRejected,
            .cacheReadFailed, .cacheWriteFailed, .responseAnomaly:
            .error
        case .fetchCancelled, .decodeCancelled, .namespaceRevoked, .diagnosticsDropped,
            .staleFallbackUsed:
            .notice
        case .fetchCompleted, .containerInspectionCompleted, .imageSourceCreationCompleted,
            .imageSourceTypeCompleted, .imageFrameCountCompleted,
            .imagePropertiesReadCompleted,
            .probeValidationCompleted, .probeCompleted, .rasterSourceCreationCompleted,
            .rasterSourceTypeCompleted, .rasterFrameCountCompleted,
            .rasterImageCreationCompleted, .rasterPostProcessingCompleted,
            .rasterDecodeCompleted, .decodeCompleted,
            .originalCommitPrepared,
            .originalCommitPublished, .renderedPublished, .pipelineSucceeded:
            .info
        default:
            .debug
        }
    }

    private static func isCritical(_ kind: DiagnosticEventKind) -> Bool {
        switch kind {
        case .pipelineFailed, .fetchFailed, .decodeFailed, .decodeAdmissionRejected,
            .fetchCancelled, .decodeCancelled, .cacheReadFailed, .cacheWriteFailed,
            .responseAnomaly, .namespaceRevoked, .diagnosticsDropped:
            true
        default:
            false
        }
    }

    private static func signpostInterval(for kind: DiagnosticEventKind) -> OSLogDiagnosticsInterval
    {
        switch kind {
        case .fetchQueued, .fetchStarted, .fetchJoined, .fetchCompleted,
            .fetchSubscriberReceived, .fetchSubscriberReleased, .fetchRetryScheduled,
            .fetchCancelled, .fetchFailed:
            .fetch
        case .decodeQueued, .decodeJoined, .decodeStarted, .containerInspectionCompleted,
            .imageSourceCreationCompleted, .imageSourceTypeCompleted,
            .imageFrameCountCompleted, .imagePropertiesReadCompleted,
            .probeValidationCompleted, .probeCompleted, .decodeResourceEstimateCompleted,
            .decodeWorkingSetReserved, .decodeAdmissionRejected,
            .rasterSourceCreationCompleted, .rasterSourceTypeCompleted,
            .rasterFrameCountCompleted, .rasterImageCreationCompleted,
            .rasterPostProcessingCompleted, .rasterDecodeCompleted, .decodeCompleted,
            .decodeCancelled, .decodeFailed:
            .decode
        case .originalEncodedHit, .originalCommitPrepared, .originalCommitPublished,
            .renderedPublished, .encodedHandoffStarted, .encodedHandoffStored,
            .encodedHandoffHit, .encodedHandoffRejected, .staleFallbackUsed,
            .renderedMemoryHit, .renderedMemoryPurged, .cacheReadFailed, .cacheWriteFailed:
            .cache
        case .responseValidated, .responseBodyMaterialized, .progressiveFinalizationReady,
            .namespaceRevoked, .pipelineSucceeded, .pipelineFailed:
            .pipeline
        case .responseAnomaly, .diagnosticsDropped:
            .general
        }
    }
}

package enum OSLogDiagnosticsLevel: Equatable, Sendable {
    case debug
    case info
    case notice
    case error
}

package enum OSLogDiagnosticsOperation: Equatable, Sendable {
    case begin
    case end
    case event
}

package enum OSLogDiagnosticsInterval: Equatable, Sendable {
    case fetch
    case decode
    case cache
    case pipeline
    case general
}

package protocol OSLogDiagnosticsEmitting: Sendable {
    func makeSignpostID() async -> UInt64
    func emitLog(level: OSLogDiagnosticsLevel, message: String) async
    func emitSignpost(
        operation: OSLogDiagnosticsOperation,
        interval: OSLogDiagnosticsInterval,
        id: UInt64,
        message: String
    ) async
}
