import CryptoKit
import Foundation
import FoveaCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 将配置、运行结果和脱敏诊断绑定为可分享证据包。
/// 证据刻意排除原始 URL、凭证、设备唯一标识和内部缓存键。
struct WorkbenchEvidenceBundle: Codable {
    static let schemaVersion = 3

    let schemaVersion: Int
    let generatedAt: Date
    let source: Source
    let runtime: Runtime
    let configuration: WorkbenchConfiguration
    let configurationFingerprint: String
    /// 每次导出重新加盐的短期令牌；不能跨证据包关联同一持久化 generation。
    let storageGenerationToken: String?
    let runs: [Run]
    let diagnostics: [RecordedDiagnosticEvent]
    let originRequestCounts: [String: Int]
    let performanceSnapshots: [Performance]

    struct Source: Codable {
        let revision: String
        let tree: String
        let includesWorkingTreeChanges: Bool?
        let appVersion: String
        let buildNumber: String
    }

    struct Runtime: Codable {
        let deviceFamily: String
        let systemName: String
        let systemMajorVersion: Int
        let executionEnvironment: String
        let maximumFramesPerSecond: Int
    }

    struct Run: Codable {
        let sequence: Int
        let scenarioID: String
        let scenarioTitle: String
        let requestCount: Int
        let completedCount: Int
        let state: String
        let durationMilliseconds: Int?
        let evidence: Evidence
    }

    struct Performance: Codable {
        let sequence: Int
        let workloadID: String
        let host: String
        let layout: String
        let itemCount: Int
        let uniqueAssetCount: Int
        let durationMilliseconds: Int
        let frameSampleCount: Int
        let hitchCount: Int
        let maximumFrameIntervalMilliseconds: Double
        let initialPhysicalFootprintBytes: UInt64?
        let peakPhysicalFootprintBytes: UInt64?
        let finalPhysicalFootprintBytes: UInt64?
        let peakFootprintDeltaBytes: UInt64?
    }

    struct Evidence: Codable {
        let originRequests: Int
        let eventCounts: [String: Int]
        let statusCounts: [String: Int]
        let finalReasonCode: String?
        let targetWidth: Int?
        let targetHeight: Int?
        let cacheDegraded: Bool
    }

    @MainActor
    static func make(
        configuration: WorkbenchConfiguration,
        storageGenerationIdentifier: String?,
        runs: [WorkbenchRunRecord],
        diagnostics: [RecordedDiagnosticEvent],
        originRequestCounts: [String: Int],
        performanceSnapshots: [WorkbenchPerformanceSnapshot],
        bundle: Bundle = .main,
        device: UIDevice = .current,
        evidenceNonce: UUID = UUID(),
        generatedAt: Date = Date()
    ) -> WorkbenchEvidenceBundle {
        let generatedAt = roundedToHour(generatedAt)
        let encodedConfiguration = (try? canonicalEncoder.encode(configuration)) ?? Data()
        let fingerprint = SHA256.hash(data: encodedConfiguration)
            .map { String(format: "%02x", $0) }
            .joined()

        return WorkbenchEvidenceBundle(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            source: Source(
                revision: WorkbenchBuildMetadata.revision,
                tree: WorkbenchBuildMetadata.sourceTree,
                includesWorkingTreeChanges: WorkbenchBuildMetadata.includesWorkingTreeChanges,
                appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String
                    ?? "unversioned",
                buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                    ?? "unversioned"
            ),
            runtime: Runtime(
                deviceFamily: deviceFamily(device.userInterfaceIdiom),
                systemName: device.systemName,
                systemMajorVersion: Int(device.systemVersion.split(separator: ".").first ?? "0")
                    ?? 0,
                executionEnvironment: executionEnvironment,
                maximumFramesPerSecond: UIScreen.main.maximumFramesPerSecond
            ),
            configuration: configuration,
            configurationFingerprint: fingerprint,
            storageGenerationToken: generationToken(
                identifier: storageGenerationIdentifier,
                nonce: evidenceNonce
            ),
            runs: runs.enumerated().map { offset, record in
                Run(
                    sequence: offset + 1,
                    scenarioID: record.scenarioID,
                    scenarioTitle: record.scenarioTitle,
                    requestCount: record.requestCount,
                    completedCount: record.completedCount,
                    state: record.state.evidenceValue,
                    durationMilliseconds: record.durationMilliseconds,
                    evidence: Evidence(
                        originRequests: record.evidence.originRequests,
                        eventCounts: Dictionary(
                            uniqueKeysWithValues: record.evidence.eventCounts.map {
                                ($0.key.rawValue, $0.value)
                            }
                        ),
                        statusCounts: Dictionary(
                            uniqueKeysWithValues: record.evidence.statusCounts.map {
                                (String($0.key), $0.value)
                            }
                        ),
                        finalReasonCode: record.evidence.finalReasonCode,
                        targetWidth: record.evidence.targetWidth,
                        targetHeight: record.evidence.targetHeight,
                        cacheDegraded: record.evidence.cacheDegraded
                    )
                )
            },
            diagnostics: shareableDiagnostics(diagnostics),
            originRequestCounts: originRequestCounts,
            performanceSnapshots: performanceSnapshots.enumerated().map { offset, snapshot in
                Performance(
                    sequence: offset + 1,
                    workloadID: snapshot.workloadID,
                    host: snapshot.host,
                    layout: snapshot.layout,
                    itemCount: snapshot.itemCount,
                    uniqueAssetCount: snapshot.uniqueAssetCount,
                    durationMilliseconds: snapshot.durationMilliseconds,
                    frameSampleCount: snapshot.frameSampleCount,
                    hitchCount: snapshot.hitchCount,
                    maximumFrameIntervalMilliseconds: snapshot.maximumFrameIntervalMilliseconds,
                    initialPhysicalFootprintBytes: snapshot.initialPhysicalFootprintBytes,
                    peakPhysicalFootprintBytes: snapshot.peakPhysicalFootprintBytes,
                    finalPhysicalFootprintBytes: snapshot.finalPhysicalFootprintBytes,
                    peakFootprintDeltaBytes: snapshot.peakFootprintDeltaBytes
                )
            }
        )
    }

    static func shareableDiagnostics(
        _ diagnostics: [RecordedDiagnosticEvent]
    ) -> [RecordedDiagnosticEvent] {
        diagnostics.map(Self.shareableDiagnostic)
    }

    private static func shareableDiagnostic(
        _ recorded: RecordedDiagnosticEvent
    ) -> RecordedDiagnosticEvent {
        let event = recorded.event
        return RecordedDiagnosticEvent(
            sequence: recorded.sequence,
            elapsedNanoseconds: recorded.elapsedNanoseconds,
            event: DiagnosticEvent(
                kind: event.kind,
                statusCode: event.statusCode,
                byteCount: event.byteCount,
                itemCount: event.itemCount,
                sourcePixelCount: event.sourcePixelCount,
                outputPixelCount: event.outputPixelCount,
                targetWidth: event.targetWidth,
                targetHeight: event.targetHeight,
                reason: event.reason,
                attempt: event.attempt,
                retryDelayNanoseconds: event.retryDelayNanoseconds,
                durationNanoseconds: event.durationNanoseconds,
                transactionCount: event.transactionCount,
                networkProtocolNames: event.networkProtocolNames,
                reusedConnectionCount: event.reusedConnectionCount,
                proxyConnectionCount: event.proxyConnectionCount,
                cellularTransactionCount: event.cellularTransactionCount,
                expensiveTransactionCount: event.expensiveTransactionCount,
                constrainedTransactionCount: event.constrainedTransactionCount,
                redirectCount: event.redirectCount,
                domainLookupDurationNanoseconds: event.domainLookupDurationNanoseconds,
                connectionDurationNanoseconds: event.connectionDurationNanoseconds,
                secureConnectionDurationNanoseconds: event.secureConnectionDurationNanoseconds,
                requestDurationNanoseconds: event.requestDurationNanoseconds,
                timeToFirstByteNanoseconds: event.timeToFirstByteNanoseconds,
                responseDurationNanoseconds: event.responseDurationNanoseconds,
                requestedPriority: event.requestedPriority,
                effectivePriority: event.effectivePriority,
                failureCategory: event.failureCategory,
                failureStage: event.failureStage,
                failureDisposition: event.failureDisposition
            )
        )
    }

    private static func roundedToHour(_ date: Date) -> Date {
        let secondsPerHour = 3_600.0
        return Date(
            timeIntervalSince1970: floor(date.timeIntervalSince1970 / secondsPerHour)
                * secondsPerHour
        )
    }

    private static func generationToken(identifier: String?, nonce: UUID) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        var material = Data("workbench-evidence-generation-v1\0".utf8)
        material.append(contentsOf: nonce.uuidString.lowercased().utf8)
        material.append(0)
        material.append(contentsOf: identifier.utf8)
        return SHA256.hash(data: material).prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func deviceFamily(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .phone: "phone"
        case .pad: "tablet"
        case .tv: "television"
        case .carPlay: "car-play"
        case .mac: "mac"
        case .vision: "vision"
        case .unspecified: "unspecified"
        @unknown default: "other"
        }
    }

    private static var executionEnvironment: String {
        #if targetEnvironment(simulator)
            "simulator"
        #else
            "device"
        #endif
    }

    static func encoded(_ bundle: WorkbenchEvidenceBundle) throws -> Data {
        try canonicalEncoder.encode(bundle)
    }

    private static var canonicalEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

}

struct WorkbenchEvidenceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(bundle: WorkbenchEvidenceBundle) throws {
        data = try WorkbenchEvidenceBundle.encoded(bundle)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension WorkbenchRunRecord.State {
    fileprivate var evidenceValue: String {
        switch self {
        case .running: "running"
        case .success: "success"
        case .environmentSuccess: "environment-success"
        case .expectedFailure(let reason): "expected-failure:\(reason)"
        case .environmentFailure(let reason): "environment-failure:\(reason)"
        case .unexpectedFailure(let reason): "unexpected-failure:\(reason)"
        case .unexpectedSuccess(let expectation): "unexpected-success:\(expectation)"
        case .cancelled: "cancelled"
        }
    }
}
