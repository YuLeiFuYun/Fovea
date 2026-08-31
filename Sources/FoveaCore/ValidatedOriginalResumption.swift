import Foundation
import FoveaHTTP

/// 续传键把请求 execution、namespace 与 generation 绑定；任一身份变化都禁止复用旧的已验证前缀。
package struct ValidatedOriginalResumeKey: Hashable, Sendable {
    package let executionDigest: String
    package let namespace: SecurityNamespaceID
    package let generation: NamespaceGeneration

    package init(
        executionDigest: String,
        namespace: SecurityNamespaceID,
        generation: NamespaceGeneration
    ) {
        self.executionDigest = executionDigest
        self.namespace = namespace
        self.generation = generation
    }
}

package struct ValidatedOriginalResumeCandidate: Sendable {
    package let prefix: Data
    package let validator: String
    package let expectedTotalBytes: Int

    package init(prefix: Data, validator: String, expectedTotalBytes: Int) {
        self.prefix = prefix
        self.validator = validator
        self.expectedTotalBytes = expectedTotalBytes
    }

    package var requestDescriptor: FetchByteRangeResume {
        FetchByteRangeResume(
            startOffset: prefix.count,
            validator: validator,
            expectedTotalBytes: expectedTotalBytes
        )
    }
}

package struct FetchByteRangeResume: Sendable {
    package let startOffset: Int
    package let validator: String
    package let expectedTotalBytes: Int

    package var executionFingerprint: String {
        Data(
            "range:\(startOffset)\u{0}if-range:\(validator)\u{0}total:\(expectedTotalBytes)".utf8
        ).sha256Hex
    }
}

/// 续传 validator 优先使用可安全用于 If-Range 的 strong ETag；弱 ETag 不提供字节身份保证，因此拒绝。
/// 缺少 strong ETag 时才退回 Last-Modified，由后续 Content-Range 与总长度检查继续失败关闭。
package enum ValidatedOriginalResumeValidator {
    package static func value(in head: TransportResponseHead) -> String? {
        if let etag = head.value(forHeader: "ETag")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            isStrongETag(etag)
        {
            return etag
        }
        return head.value(forHeader: "Last-Modified")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isStrongETag(_ value: String) -> Bool {
        value.count >= 2
            && value.first == "\""
            && value.last == "\""
            && !value.lowercased().hasPrefix("w/")
    }
}

package struct ValidatedOriginalContentRange: Equatable, Sendable {
    package let start: Int
    package let end: Int
    package let total: Int

    package init(start: Int, end: Int, total: Int) {
        self.start = start
        self.end = end
        self.total = total
    }

    package static func parse(_ rawValue: String) -> Self? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("bytes ") else { return nil }
        let payload = value.dropFirst(6)
        let pieces = payload.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, let total = parseNonnegative(pieces[1]), total > 0 else {
            return nil
        }
        let bounds = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
            let start = parseNonnegative(bounds[0]),
            let end = parseNonnegative(bounds[1]),
            start <= end,
            end < total
        else { return nil }
        return Self(start: start, end: end, total: total)
    }

    package func exactlyCompletes(_ candidate: ValidatedOriginalResumeCandidate) -> Bool {
        start == candidate.prefix.count
            && total == candidate.expectedTotalBytes
            && end == total - 1
    }

    private static func parseNonnegative(_ value: Substring) -> Int? {
        guard !value.isEmpty, value.allSatisfy({ $0.isNumber }), let number = Int(value) else {
            return nil
        }
        return number
    }
}

package enum ValidatedOriginalResumption {
    static func reassemble(
        _ response: TimedTransportResponse,
        candidate: ValidatedOriginalResumeCandidate,
        maximumTransportBytes: Int
    ) throws -> TimedTransportResponse {
        guard response.head.statusCode == 206,
            identityEncoding(in: response.head),
            let rawRange = response.head.value(forHeader: "Content-Range"),
            let range = ValidatedOriginalContentRange.parse(rawRange),
            range.exactlyCompletes(candidate),
            validatorMatchesIfPresent(response.head, expected: candidate.validator)
        else { throw TransportError.invalidResponseHeader }
        let suffix = try response.transport.materializedBody()
        let expectedSuffix = candidate.expectedTotalBytes - candidate.prefix.count
        guard suffix.count == expectedSuffix,
            exactLength(response.head) == expectedSuffix,
            candidate.expectedTotalBytes <= maximumTransportBytes
        else { throw TransportError.incompleteBody }
        var fullBody = candidate.prefix
        fullBody.append(suffix)
        let head = try normalizedCompleteHead(response.head, totalBytes: fullBody.count)
        let transport = TransportResponse(
            head: head,
            reassembledBody: fullBody,
            receivedBytes: response.transport.metrics.receivedBytes,
            metrics: response.transport.metrics
        )
        return TimedTransportResponse(
            requestTime: response.requestTime,
            responseTime: response.responseTime,
            transport: transport
        )
    }

    private static func normalizedCompleteHead(
        _ head: TransportResponseHead,
        totalBytes: Int
    ) throws -> TransportResponseHead {
        var headers = head.headers
        headers.removeValue(forKey: "content-range")
        headers["content-length"] = String(totalBytes)
        return try TransportResponseHead(statusCode: 200, headers: headers, url: head.url)
    }

    private static func exactLength(_ head: TransportResponseHead) -> Int? {
        guard
            let raw = head.value(forHeader: "Content-Length")?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), let value = Int(raw), value > 0
        else { return nil }
        return value
    }

    private static func identityEncoding(in head: TransportResponseHead) -> Bool {
        let value =
            head.value(forHeader: "Content-Encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "identity"
        return value == "identity"
    }

    private static func validatorMatchesIfPresent(
        _ head: TransportResponseHead,
        expected: String
    ) -> Bool {
        guard let actual = ValidatedOriginalResumeValidator.value(in: head) else { return true }
        return actual == expected
    }
}

package actor ValidatedOriginalResumeStore {
    package static let defaultMaximumTotalBytes = 32 * 1024 * 1024
    package static let defaultMaximumEntryCount = 100

    package struct Snapshot: Sendable {
        package let entryCount: Int
        package let totalBytes: Int
    }

    private let maximumTotalBytes: Int
    private let maximumEntryCount: Int
    private var entries: [ValidatedOriginalResumeKey: ValidatedOriginalResumeCandidate] = [:]
    private var order: [ValidatedOriginalResumeKey] = []
    private var totalBytes = 0

    package init(
        maximumTotalBytes: Int = defaultMaximumTotalBytes,
        maximumEntryCount: Int = defaultMaximumEntryCount
    ) {
        self.maximumTotalBytes = max(1, maximumTotalBytes)
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    package func take(
        _ key: ValidatedOriginalResumeKey
    ) -> ValidatedOriginalResumeCandidate? {
        guard let candidate = entries.removeValue(forKey: key) else { return nil }
        totalBytes -= candidate.prefix.count
        order.removeAll { $0 == key }
        return candidate
    }

    package func store(
        _ candidate: ValidatedOriginalResumeCandidate,
        for key: ValidatedOriginalResumeKey
    ) {
        let cost = candidate.prefix.count
        guard cost > 0, cost < candidate.expectedTotalBytes, cost <= maximumTotalBytes else {
            return
        }
        removeExisting(key)
        evictForInsertion(cost: cost)
        entries[key] = candidate
        order.append(key)
        totalBytes += cost
    }

    package func snapshot() -> Snapshot {
        Snapshot(entryCount: entries.count, totalBytes: totalBytes)
    }

    private func removeExisting(_ key: ValidatedOriginalResumeKey) {
        guard let existing = entries.removeValue(forKey: key) else { return }
        totalBytes -= existing.prefix.count
        order.removeAll { $0 == key }
    }

    private func evictForInsertion(cost: Int) {
        while !order.isEmpty,
            entries.count >= maximumEntryCount || totalBytes + cost > maximumTotalBytes
        {
            let victim = order.removeFirst()
            guard let removed = entries.removeValue(forKey: victim) else { continue }
            totalBytes -= removed.prefix.count
        }
    }
}

package final class ValidatedOriginalResumeCapture: @unchecked Sendable {
    private struct State {
        var prefix: Data
        let validator: String
        let expectedTotalBytes: Int
        let responseBaseOffset: Int
        var responseReceivedBytes: Int
        var completed = false
    }

    private let lock = NSLock()
    private let seed: ValidatedOriginalResumeCandidate?
    private let maximumTransportBytes: Int
    private let maximumCandidateBytes: Int
    private var state: State?

    package init(
        seed: ValidatedOriginalResumeCandidate?,
        maximumTransportBytes: Int,
        maximumCandidateBytes: Int = ValidatedOriginalResumeStore.defaultMaximumTotalBytes
    ) {
        self.seed = seed
        self.maximumTransportBytes = maximumTransportBytes
        self.maximumCandidateBytes = maximumCandidateBytes
    }

    package func observe(_ event: TransportProgressEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .response(let head):
            state = makeState(for: head)
        case .data(let data, let cumulativeByteCount):
            append(data, cumulativeByteCount: cumulativeByteCount)
        case .complete:
            state?.completed = true
        }
    }

    package func candidate() -> ValidatedOriginalResumeCandidate? {
        lock.lock()
        defer { lock.unlock() }
        guard let state, !state.completed,
            !state.prefix.isEmpty,
            state.prefix.count < state.expectedTotalBytes
        else { return nil }
        return ValidatedOriginalResumeCandidate(
            prefix: state.prefix,
            validator: state.validator,
            expectedTotalBytes: state.expectedTotalBytes
        )
    }

    private func makeState(for head: TransportResponseHead) -> State? {
        if head.statusCode == 206, let seed {
            return resumedState(for: head, seed: seed)
        }
        guard head.statusCode == 200 else { return nil }
        return freshState(for: head)
    }

    private func freshState(for head: TransportResponseHead) -> State? {
        guard identityEncoding(in: head), acceptsByteRanges(head),
            let total = exactPositiveLength(head),
            total <= maximumTransportBytes,
            let validator = validator(in: head)
        else { return nil }
        return State(
            prefix: Data(),
            validator: validator,
            expectedTotalBytes: total,
            responseBaseOffset: 0,
            responseReceivedBytes: 0
        )
    }

    private func resumedState(
        for head: TransportResponseHead,
        seed: ValidatedOriginalResumeCandidate
    ) -> State? {
        guard identityEncoding(in: head),
            let rawRange = head.value(forHeader: "Content-Range"),
            let contentRange = ValidatedOriginalContentRange.parse(rawRange),
            contentRange.exactlyCompletes(seed),
            exactPositiveLength(head) == seed.expectedTotalBytes - seed.prefix.count,
            validatorMatchesIfPresent(head, expected: seed.validator)
        else { return nil }
        return State(
            prefix: seed.prefix,
            validator: seed.validator,
            expectedTotalBytes: seed.expectedTotalBytes,
            responseBaseOffset: seed.prefix.count,
            responseReceivedBytes: 0
        )
    }

    private func append(_ data: Data, cumulativeByteCount: Int) {
        guard var current = state, !current.completed else { return }
        let expectedCumulative = current.responseReceivedBytes.addingReportingOverflow(data.count)
        guard !expectedCumulative.overflow,
            expectedCumulative.partialValue == cumulativeByteCount
        else {
            state = nil
            return
        }
        let combined = current.responseBaseOffset.addingReportingOverflow(cumulativeByteCount)
        guard !combined.overflow,
            combined.partialValue <= current.expectedTotalBytes,
            combined.partialValue <= maximumCandidateBytes
        else {
            state = nil
            return
        }
        current.prefix.append(data)
        current.responseReceivedBytes = cumulativeByteCount
        state = current
    }

    private func exactPositiveLength(_ head: TransportResponseHead) -> Int? {
        guard
            let raw = head.value(forHeader: "Content-Length")?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), let value = Int(raw), value > 0
        else { return nil }
        return value
    }

    private func identityEncoding(in head: TransportResponseHead) -> Bool {
        let value =
            head.value(forHeader: "Content-Encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "identity"
        return value == "identity"
    }

    private func acceptsByteRanges(_ head: TransportResponseHead) -> Bool {
        head.value(forHeader: "Accept-Ranges")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "bytes"
    }

    private func validator(in head: TransportResponseHead) -> String? {
        ValidatedOriginalResumeValidator.value(in: head)
    }

    private func validatorMatchesIfPresent(
        _ head: TransportResponseHead,
        expected: String
    ) -> Bool {
        guard let actual = ValidatedOriginalResumeValidator.value(in: head) else { return true }
        return actual == expected
    }
}
