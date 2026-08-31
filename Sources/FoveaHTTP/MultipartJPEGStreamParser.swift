import Foundation

package enum MultipartJPEGStreamError: Error, Equatable, Sendable {
    case invalidContentType
    case invalidBoundary
    case limitExceeded
    case malformedBoundary
    case malformedHeaders
    case missingContentLength
    case invalidContentLength
    case unsupportedPartContentType
    case invalidJPEGFrame
    case unexpectedEnd
    case trailingData
}

/// `multipart/x-mixed-replace` JPEG 流的宿主侧资源限制。
package struct MultipartJPEGStreamLimits: Equatable, Sendable {
    package let maximumTotalBytes: Int
    package let maximumPartBytes: Int
    package let maximumPartCount: Int
    package let maximumHeaderBytes: Int
    package let maximumHeaderCount: Int

    package init(
        maximumTotalBytes: Int = 256 * 1024 * 1024,
        maximumPartBytes: Int = 32 * 1024 * 1024,
        maximumPartCount: Int = 4_096,
        maximumHeaderBytes: Int = HTTPMetadataLimits.maximumHeaderBytes,
        maximumHeaderCount: Int = HTTPMetadataLimits.maximumHeaderCount
    ) {
        self.maximumTotalBytes = min(1_024 * 1_024 * 1_024, max(1, maximumTotalBytes))
        self.maximumPartBytes = min(
            self.maximumTotalBytes,
            min(1_024 * 1_024 * 1_024, max(1, maximumPartBytes))
        )
        self.maximumPartCount = min(1_000_000, max(1, maximumPartCount))
        self.maximumHeaderBytes = min(
            HTTPMetadataLimits.maximumHeaderBytes,
            max(1, maximumHeaderBytes)
        )
        self.maximumHeaderCount = min(
            HTTPMetadataLimits.maximumHeaderCount,
            max(1, maximumHeaderCount)
        )
    }
}

/// 一个已经由 multipart 边界、长度和完整 JPEG 标记验证的帧 part。
package struct MultipartJPEGPart: Equatable, Sendable {
    package let index: Int
    package let headers: [String: String]
    package let data: Data

    package init(
        index: Int,
        headers: [String: String] = [:],
        data: Data
    ) {
        self.index = index
        self.headers = headers
        self.data = data
    }
}

/// 严格、有界且可增量消费的 `multipart/x-mixed-replace` JPEG 分帧器。
///
/// 该 profile 要求每个 part 显式声明唯一 `Content-Length`。因此 JPEG 正文中即使
/// 出现 boundary 字节，也不会触发歧义扫描；上层仍须交给 ImageCraft 做完整 JPEG
/// 容器、元数据、尺寸、颜色和像素验证。
package struct MultipartJPEGStreamParser: Sendable {
    private enum State: Sendable {
        case boundary(isInitial: Bool)
        case headers
        case body(headers: [String: String], length: Int)
        case completed
    }

    private enum ProcessStep {
        case advanced(MultipartJPEGPart?)
        case blocked
        case completed
    }

    private static let headerTerminator = Data([13, 10, 13, 10])
    private static let lineEnding = Data([13, 10])
    private static let finalSuffix = Data([45, 45])

    private let delimiter: Data
    private let limits: MultipartJPEGStreamLimits
    private var state: State = .boundary(isInitial: true)
    private var buffer = Data()
    private var cursor = 0
    private var receivedByteCount = 0
    private var emittedPartCount = 0

    package init(
        contentType: String,
        limits: MultipartJPEGStreamLimits = MultipartJPEGStreamLimits()
    ) throws {
        let boundary = try Self.boundary(from: contentType)
        self.delimiter = Data("--\(boundary)".utf8)
        self.limits = limits
    }

    /// 追加已按传输顺序接收的字节，并返回本次新完成的全部 JPEG part。
    package mutating func append(_ data: Data) throws -> [MultipartJPEGPart] {
        guard !data.isEmpty else { return [] }
        if case .completed = state { throw MultipartJPEGStreamError.trailingData }
        let next = receivedByteCount.addingReportingOverflow(data.count)
        guard !next.overflow, next.partialValue <= limits.maximumTotalBytes else {
            throw MultipartJPEGStreamError.limitExceeded
        }
        receivedByteCount = next.partialValue
        buffer.append(data)
        return try process(allowTerminalBoundaryWithoutCRLF: false)
    }

    /// 结束有限响应。实时流可以由调用方取消并丢弃 parser；只有有限正文需要调用此方法。
    package mutating func finish() throws -> [MultipartJPEGPart] {
        let parts = try process(allowTerminalBoundaryWithoutCRLF: true)
        guard case .completed = state, availableByteCount == 0 else {
            throw MultipartJPEGStreamError.unexpectedEnd
        }
        return parts
    }

    package var isComplete: Bool {
        if case .completed = state { return true }
        return false
    }

    package var partCount: Int { emittedPartCount }

    private mutating func process(
        allowTerminalBoundaryWithoutCRLF: Bool
    ) throws -> [MultipartJPEGPart] {
        var emitted: [MultipartJPEGPart] = []
        while true {
            switch try processNext(
                allowTerminalBoundaryWithoutCRLF: allowTerminalBoundaryWithoutCRLF
            ) {
            case .advanced(let part):
                if let part { emitted.append(part) }
            case .blocked:
                compactIfNeeded()
                return emitted
            case .completed:
                compactIfNeeded(force: true)
                return emitted
            }
        }
    }

    private mutating func processNext(
        allowTerminalBoundaryWithoutCRLF: Bool
    ) throws -> ProcessStep {
        switch state {
        case .boundary(let isInitial):
            let consumed = try consumeBoundary(
                isInitial: isInitial,
                allowTerminalBoundaryWithoutCRLF: allowTerminalBoundaryWithoutCRLF
            )
            return consumed ? .advanced(nil) : .blocked
        case .headers:
            guard let parsed = try consumeHeaders() else { return .blocked }
            state = .body(headers: parsed.headers, length: parsed.length)
            return .advanced(nil)
        case .body(let headers, let length):
            guard let part = try consumeBody(headers: headers, length: length) else {
                return .blocked
            }
            return .advanced(part)
        case .completed:
            guard availableByteCount == 0 else {
                throw MultipartJPEGStreamError.trailingData
            }
            return .completed
        }
    }

    private mutating func consumeBody(
        headers: [String: String],
        length: Int
    ) throws -> MultipartJPEGPart? {
        guard availableByteCount >= length + Self.lineEnding.count else { return nil }
        let bodyRange = cursor..<(cursor + length)
        let endingRange = bodyRange.upperBound..<(bodyRange.upperBound + 2)
        guard buffer[endingRange] == Self.lineEnding else {
            throw MultipartJPEGStreamError.malformedBoundary
        }
        let body = Data(buffer[bodyRange])
        guard Self.isCompleteJPEG(body) else {
            throw MultipartJPEGStreamError.invalidJPEGFrame
        }
        guard emittedPartCount < limits.maximumPartCount else {
            throw MultipartJPEGStreamError.limitExceeded
        }
        let index = emittedPartCount
        emittedPartCount += 1
        consume(length + Self.lineEnding.count)
        state = .boundary(isInitial: false)
        return MultipartJPEGPart(index: index, headers: headers, data: body)
    }

    private mutating func consumeBoundary(
        isInitial: Bool,
        allowTerminalBoundaryWithoutCRLF: Bool
    ) throws -> Bool {
        let minimum = delimiter.count + 2
        guard availableByteCount >= minimum else { return false }
        let delimiterRange = cursor..<(cursor + delimiter.count)
        guard buffer[delimiterRange] == delimiter else {
            throw MultipartJPEGStreamError.malformedBoundary
        }
        let suffixStart = delimiterRange.upperBound
        let suffix = Data(buffer[suffixStart..<(suffixStart + 2)])
        if suffix == Self.lineEnding {
            consume(minimum)
            state = .headers
            return true
        }
        guard suffix == Self.finalSuffix, !isInitial else {
            throw MultipartJPEGStreamError.malformedBoundary
        }
        let withCRLF = delimiter.count + 4
        if availableByteCount >= withCRLF {
            let ending = Data(buffer[(suffixStart + 2)..<(suffixStart + 4)])
            guard ending == Self.lineEnding else {
                throw MultipartJPEGStreamError.trailingData
            }
            consume(withCRLF)
            state = .completed
            return true
        }
        guard allowTerminalBoundaryWithoutCRLF, availableByteCount == minimum else {
            return false
        }
        consume(minimum)
        state = .completed
        return true
    }

    private mutating func consumeHeaders()
        throws -> (headers: [String: String], length: Int)?
    {
        let searchRange = cursor..<buffer.count
        guard let range = buffer.range(of: Self.headerTerminator, in: searchRange) else {
            guard availableByteCount <= limits.maximumHeaderBytes + Self.headerTerminator.count
            else {
                throw MultipartJPEGStreamError.limitExceeded
            }
            return nil
        }
        let headerByteCount = range.lowerBound - cursor
        guard headerByteCount > 0, headerByteCount <= limits.maximumHeaderBytes else {
            throw MultipartJPEGStreamError.malformedHeaders
        }
        let block = Data(buffer[cursor..<range.lowerBound])
        let headers = try Self.parseHeaders(
            block,
            maximumHeaderCount: limits.maximumHeaderCount
        )
        guard let rawLength = headers["content-length"] else {
            throw MultipartJPEGStreamError.missingContentLength
        }
        let length = try Self.contentLength(rawLength)
        guard length > 0, length <= limits.maximumPartBytes else {
            throw MultipartJPEGStreamError.limitExceeded
        }
        guard let contentType = headers["content-type"],
            Self.mediaType(contentType) == "image/jpeg"
        else { throw MultipartJPEGStreamError.unsupportedPartContentType }
        consume(headerByteCount + Self.headerTerminator.count)
        return (headers, length)
    }

    private mutating func consume(_ count: Int) {
        cursor += count
    }

    private mutating func compactIfNeeded(force: Bool = false) {
        guard cursor > 0,
            force || cursor >= 64 * 1024 || cursor * 2 >= buffer.count
        else { return }
        buffer.removeSubrange(0..<cursor)
        cursor = 0
    }

    private var availableByteCount: Int { buffer.count - cursor }

    private static func boundary(from contentType: String) throws -> String {
        let components = try parameterComponents(contentType)
        guard let media = components.first,
            media.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == "multipart/x-mixed-replace"
        else { throw MultipartJPEGStreamError.invalidContentType }
        let boundary = try boundaryParameter(from: components.dropFirst())
        try validateBoundary(boundary)
        return boundary
    }

    private static func boundaryParameter(
        from components: ArraySlice<String>
    ) throws -> String {
        var boundary: String?
        for component in components {
            guard let equal = component.firstIndex(of: "=") else {
                throw MultipartJPEGStreamError.invalidContentType
            }
            let name = component[..<equal]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let rawValue = component[component.index(after: equal)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw MultipartJPEGStreamError.invalidContentType }
            guard name == "boundary" else { continue }
            guard boundary == nil else { throw MultipartJPEGStreamError.invalidBoundary }
            boundary = try unquotedParameter(rawValue)
        }
        guard let boundary else { throw MultipartJPEGStreamError.invalidBoundary }
        return boundary
    }

    private static func validateBoundary(_ boundary: String) throws {
        let bytes = Array(boundary.utf8)
        guard (1...70).contains(bytes.count),
            !boundary.hasPrefix("--"),
            bytes.allSatisfy({ byte in
                (0x21...0x7e).contains(byte) && byte != 0x22 && byte != 0x5c
            })
        else { throw MultipartJPEGStreamError.invalidBoundary }
    }

    private static func parameterComponents(_ value: String) throws -> [String] {
        var components: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for scalar in value.unicodeScalars {
            let code = scalar.value
            guard code >= 0x20, code != 0x7f else {
                throw MultipartJPEGStreamError.invalidContentType
            }
            if escaped {
                current.unicodeScalars.append(scalar)
                escaped = false
            } else if quoted, scalar == "\\" {
                current.unicodeScalars.append(scalar)
                escaped = true
            } else if scalar == "\"" {
                quoted.toggle()
                current.unicodeScalars.append(scalar)
            } else if scalar == ";", !quoted {
                components.append(current)
                current = ""
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        guard !quoted, !escaped else { throw MultipartJPEGStreamError.invalidContentType }
        components.append(current)
        return components
    }

    private static func unquotedParameter(_ value: String) throws -> String {
        guard value.first == "\"" else { return value }
        guard value.count >= 2, value.last == "\"" else {
            throw MultipartJPEGStreamError.invalidBoundary
        }
        var result = ""
        var escaped = false
        for scalar in value.dropFirst().dropLast().unicodeScalars {
            if escaped {
                result.unicodeScalars.append(scalar)
                escaped = false
            } else if scalar == "\\" {
                escaped = true
            } else if scalar == "\"" {
                throw MultipartJPEGStreamError.invalidBoundary
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        guard !escaped else { throw MultipartJPEGStreamError.invalidBoundary }
        return result
    }

    private static func parseHeaders(
        _ data: Data,
        maximumHeaderCount: Int
    ) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw MultipartJPEGStreamError.malformedHeaders
        }
        let lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty, lines.count <= maximumHeaderCount else {
            throw MultipartJPEGStreamError.limitExceeded
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard !line.isEmpty,
                let colon = line.firstIndex(of: ":"),
                colon != line.startIndex
            else { throw MultipartJPEGStreamError.malformedHeaders }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard HTTPMetadataLimits.isValidFieldName(name),
                HTTPMetadataLimits.isValidFieldValue(value),
                headers[name] == nil
            else { throw MultipartJPEGStreamError.malformedHeaders }
            headers[name] = value
        }
        return headers
    }

    private static func contentLength(_ value: String) throws -> Int {
        guard !value.isEmpty else { throw MultipartJPEGStreamError.invalidContentLength }
        var result = 0
        for byte in value.utf8 {
            guard (48...57).contains(byte) else {
                throw MultipartJPEGStreamError.invalidContentLength
            }
            let product = result.multipliedReportingOverflow(by: 10)
            let addition = product.partialValue.addingReportingOverflow(Int(byte - 48))
            guard !product.overflow, !addition.overflow else {
                throw MultipartJPEGStreamError.invalidContentLength
            }
            result = addition.partialValue
        }
        return result
    }

    private static func mediaType(_ value: String) -> String {
        String(value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func isCompleteJPEG(_ data: Data) -> Bool {
        data.count >= 4
            && data[data.startIndex] == 0xff
            && data[data.index(after: data.startIndex)] == 0xd8
            && data[data.index(data.endIndex, offsetBy: -2)] == 0xff
            && data[data.index(before: data.endIndex)] == 0xd9
    }
}
