import Foundation
import FoveaCore

/// 将 App 状态转换为可分享证据；该类型不持有运行时或用户界面状态。
@MainActor
enum WorkbenchEvidenceExport {
    static func diagnosticsJSON(_ events: [RecordedDiagnosticEvent]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let shareable = WorkbenchEvidenceBundle.shareableDiagnostics(events)
        guard let data = try? encoder.encode(shareable) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func bundle(
        configuration: WorkbenchConfiguration,
        storageGenerationIdentifier: String,
        runs: [WorkbenchRunRecord],
        diagnostics: [RecordedDiagnosticEvent],
        originRequestCounts: [String: Int],
        performanceSnapshots: [WorkbenchPerformanceSnapshot]
    ) -> WorkbenchEvidenceBundle {
        WorkbenchEvidenceBundle.make(
            configuration: configuration,
            storageGenerationIdentifier: storageGenerationIdentifier == "—"
                ? nil : storageGenerationIdentifier,
            runs: runs,
            diagnostics: diagnostics,
            originRequestCounts: originRequestCounts,
            performanceSnapshots: performanceSnapshots
        )
    }
}
