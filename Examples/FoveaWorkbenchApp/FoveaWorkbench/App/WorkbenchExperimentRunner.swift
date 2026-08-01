import Foundation
import FoveaCore
import ImageCraftCore

/// 单次证据运行的完成量、终态和可导出证据；不持有管线或任务生命周期。
struct WorkbenchExperimentResult {
    let completedCount: Int
    let outcome: WorkbenchRunRecord.State
    let evidence: WorkbenchRunEvidence
}

@MainActor
enum WorkbenchExperimentRunner {
    static func execute(
        id: UUID,
        scenario: WorkbenchScenario,
        requestCount: Int,
        configuration: WorkbenchConfiguration,
        identityRevision: String,
        explicitTarget: TargetPixels?,
        cacheRoot: URL,
        progress: (Int) -> Void
    ) async -> WorkbenchExperimentResult {
        let runIdentifier = id.uuidString.lowercased()
        let diagnostics = WorkbenchDiagnosticsSink(capacity: 4_096)
        var completed = 0
        var outcome: WorkbenchRunRecord.State
        var runtime: WorkbenchPipelineRuntime?
        var requestHost: String?

        do {
            try Task.checkCancellation()
            let opened = try await WorkbenchPipelineFactory.openEvidence(
                cacheRoot: cacheRoot,
                configuration: configuration,
                diagnostics: diagnostics
            )
            runtime = opened
            try Task.checkCancellation()
            let target = try explicitTarget ?? evidenceTarget(for: scenario)
            let request = try WorkbenchRequestFactory.makeRequest(
                scenario: scenario,
                target: target,
                configuration: configuration,
                identityRevision: identityRevision,
                runIdentifier: runIdentifier
            )
            requestHost = request.url.host?.lowercased()

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<requestCount {
                    group.addTask { _ = try await opened.pipeline.image(for: request) }
                }
                for try await _ in group {
                    completed += 1
                    progress(completed)
                }
            }
            outcome = successOutcome(for: scenario)
        } catch is CancellationError {
            outcome = .cancelled
        } catch let failure as PipelineFailure {
            outcome = failureOutcome(failure, scenario: scenario)
        } catch {
            outcome = .unexpectedFailure(describe(error))
        }

        let evidence = await captureEvidence(
            diagnostics: diagnostics,
            runIdentifier: runIdentifier,
            requestHost: requestHost
        )
        if let runtime {
            await runtime.invalidateAndCancel()
        }
        return WorkbenchExperimentResult(
            completedCount: completed,
            outcome: outcome,
            evidence: evidence
        )
    }

    private static func captureEvidence(
        diagnostics: WorkbenchDiagnosticsSink,
        runIdentifier: String,
        requestHost: String?
    ) async -> WorkbenchRunEvidence {
        let events = await diagnostics.snapshot()
        var counts: [DiagnosticEventKind: Int] = [:]
        var statusCounts: [Int: Int] = [:]
        for item in events {
            counts[item.event.kind, default: 0] += 1
            if let statusCode = item.event.statusCode { statusCounts[statusCode, default: 0] += 1 }
        }
        let finalEvent = events.reversed().first { item in
            item.event.reason != nil || item.event.kind == .decodeCompleted
        }
        let originRequests =
            requestHost == DemoURLProtocol.host
            ? await DemoOriginMetrics.shared.consumeCount(runIdentifier: runIdentifier)
            : counts[.fetchStarted, default: 0]
        return WorkbenchRunEvidence(
            originRequests: originRequests,
            eventCounts: counts,
            statusCounts: statusCounts,
            finalReasonCode: finalEvent?.event.reason,
            targetWidth: finalEvent?.event.targetWidth,
            targetHeight: finalEvent?.event.targetHeight
        )
    }

    private static func evidenceTarget(for scenario: WorkbenchScenario) throws -> TargetPixels {
        switch scenario.presentation {
        case .standard:
            try TargetPixels(width: 400, height: 300)
        case .feed:
            try TargetPixels(width: 320, height: 240)
        }
    }

    private static func successOutcome(
        for scenario: WorkbenchScenario
    ) -> WorkbenchRunRecord.State {
        switch scenario.expectedOutcome {
        case .success:
            .success
        case .failure(let reason):
            .unexpectedSuccess(reason)
        case .environmentDependent:
            .environmentSuccess
        }
    }

    private static func failureOutcome(
        _ failure: PipelineFailure,
        scenario: WorkbenchScenario
    ) -> WorkbenchRunRecord.State {
        switch scenario.expectedOutcome {
        case .success:
            .unexpectedFailure(failure.reasonCode)
        case .failure(let expected):
            failure.reasonCode == expected
                ? .expectedFailure(failure.reasonCode)
                : .unexpectedFailure("\(failure.reasonCode)，预期 \(expected)")
        case .environmentDependent:
            .environmentFailure(failure.reasonCode)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? PipelineFailure { return failure.reasonCode }
        if let requestError = error as? WorkbenchRequestFactoryError {
            return requestError.errorDescription ?? "invalid-request"
        }
        return "operation-failed"
    }
}
