import Foundation
import XCTest

func waitUntil(
    _ description: String,
    timeoutNanoseconds: UInt64 = 3_000_000_000,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let timeoutSeconds = Double(timeoutNanoseconds) / 1_000_000_000
    let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
    repeat {
        try Task.checkCancellation()
        if await condition() { return }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    } while ProcessInfo.processInfo.systemUptime < deadline

    XCTFail("等待条件超时：\(description)", file: file, line: line)
}

@MainActor
func waitUntilOnMainActor(
    _ description: String,
    timeoutNanoseconds: UInt64 = 3_000_000_000,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let timeoutSeconds = Double(timeoutNanoseconds) / 1_000_000_000
    let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
    repeat {
        try Task.checkCancellation()
        if await condition() { return }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    } while ProcessInfo.processInfo.systemUptime < deadline

    XCTFail("等待条件超时：\(description)", file: file, line: line)
}
