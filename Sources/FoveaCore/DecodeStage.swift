import Foundation
import ImageCraftCore

/// 将探测、工作集准入与最终解码组织为三个资源边界。
/// 探测与解码共享调度优先级，但等待工作集时不得占用解码并发许可。
package final class DecodeStage: Sendable {
    private struct TimedDecodePlan: Sendable {
        let plan: FoveaDecodePlan
        let durationNanoseconds: UInt64
    }

    private let codec: any ImageCodec
    package let codecDescriptor: ImageCodecDescriptor
    private let limits: DecodeLimits
    private let diagnostics: any DiagnosticsSink
    private let detailedDiagnosticsEnabled: Bool
    private let permitController: FoveaDecodePermitController
    private let executor = DispatchWorkExecutor(label: "dev.fovea.decode")
    private let registry = SharedTaskRegistry<ScopedDecodeKey, DecodedImage>()

    package init(
        codec: any ImageCodec,
        limits: DecodeLimits,
        diagnostics: any DiagnosticsSink,
        maximumConcurrentDecodes: Int,
        maximumDecodeWorkingSetBytes: Int,
        maximumQueuedDecodes: Int,
        decodePermits: AsyncPermitPool? = nil,
        workingSetPermits: AsyncPermitPool? = nil,
        globalDecodePermits: AsyncPermitPool? = nil,
        globalWorkingSetPermits: AsyncPermitPool? = nil
    ) {
        self.codec = codec
        self.codecDescriptor = codec.codecDescriptor
        self.limits = limits
        self.diagnostics = diagnostics
        self.detailedDiagnosticsEnabled = detailedDiagnosticsAreEnabled(diagnostics)
        self.permitController = FoveaDecodePermitController(
            diagnostics: diagnostics,
            maximumConcurrentDecodes: maximumConcurrentDecodes,
            maximumDecodeWorkingSetBytes: maximumDecodeWorkingSetBytes,
            maximumQueuedDecodes: maximumQueuedDecodes,
            decodePermits: decodePermits,
            workingSetPermits: workingSetPermits,
            globalDecodePermits: globalDecodePermits,
            globalWorkingSetPermits: globalWorkingSetPermits
        )
    }

    package var progressiveEncodedByteLimit: Int { limits.maximumEncodedBytes }

    package func makeProgressiveSession(
        for request: ImageRequest,
        format: EncodedImageFormat
    ) throws -> (any ImageProgressiveDecodeSession)? {
        try ProgressiveDecodeStage.makeSession(
            codec: codec,
            descriptor: codecDescriptor,
            limits: limits,
            request: request,
            format: format
        )
    }

    package func appendProgressive(
        _ chunk: Data,
        to session: any ImageProgressiveDecodeSession,
        for request: ImageRequest
    ) async throws -> ImageProgressiveDecodeGeneration? {
        try await permitController.withProgressiveDecodePermits(
            priority: request.priority,
            workEstimate: chunk.count
        ) {
            try await ProgressiveDecodeStage.append(
                chunk,
                to: session,
                request: request,
                limits: limits,
                maximumResidentBytes: permitController.maximumWorkingSetBytes,
                executor: executor
            )
        }
    }

    package func finishProgressive(
        _ session: any ImageProgressiveDecodeSession,
        for request: ImageRequest
    ) async throws {
        try await permitController.withProgressiveDecodePermits(
            priority: request.priority,
            workEstimate: 1
        ) {
            try await ProgressiveDecodeStage.finish(session, executor: executor)
        }
    }

    package func finishProgressiveWithPreparation(
        _ session: any ProgressiveImagePreparingSession,
        for request: ImageRequest
    ) async throws -> ImageProgressiveDecodePreparationFinalization {
        try await permitController.withProgressiveDecodePermits(
            priority: request.priority,
            workEstimate: 1
        ) {
            try await ProgressiveDecodeStage.finishWithPreparation(session, executor: executor)
        }
    }

    package func discardProgressivePreparation(
        _ preparation: ImageDecodePreparation
    ) async {
        await ProgressiveDecodeStage.discardPreparation(
            preparation,
            codec: codec,
            executor: executor
        )
    }

    func cancelAll(namespace: SecurityNamespaceID) async {
        _ = await registry.cancelAll { $0.namespace == namespace }
    }

    @concurrent
    package func image(
        from data: Data,
        contentID: ContentID,
        request: ImageRequest,
        generation: NamespaceGeneration,
        keyDigest: String,
        preparation: ImageDecodePreparation? = nil
    ) async throws -> DecodedImage {
        let decodeKey = DecodeKey(
            contentID: contentID,
            targetWidth: request.target.width,
            targetHeight: request.target.height,
            contentMode: request.contentMode,
            geometryPolicyFingerprint: request.geometryPolicyFingerprint,
            colorPolicy: request.colorPolicy,
            codecContractVersion: codecDescriptor.contractVersion,
            codecFingerprint: codecDescriptor.cacheFingerprint
        )
        let scopedKey = ScopedDecodeKey(
            namespace: request.namespace,
            generation: generation,
            decodeKey: decodeKey
        )
        let subscription = await registry.subscribe(
            key: scopedKey,
            priority: request.priority
        ) { [self] priorityControl in
            try await performDecode(
                data: data,
                request: request,
                keyDigest: keyDigest,
                priorityControl: priorityControl,
                preparation: preparation
            )
        }

        if subscription.wasJoined {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .decodeJoined,
                    keyDigest: keyDigest,
                    requestedPriority: request.priority,
                    effectivePriority: await subscription.priorityControl.currentPriority()
                )
            )
        }

        return try await withTaskCancellationHandler {
            defer { await subscription.cancel() }
            do {
                let image = try await subscription.value()
                try Task.checkCancellation()
                return image
            } catch {
                if error is CancellationError { throw PipelineFailure.cancelled(stage: .decode) }
                throw error
            }
        } onCancel: {
            Task { await subscription.cancel() }
        }
    }

    package func validateEncodedData(
        _ data: Data,
        request: ImageRequest,
        keyDigest: String
    ) async throws {
        let priorityControl = SharedTaskPriorityControl(priority: request.priority)
        let plan = try await prepareDecode(
            data: data,
            request: request,
            keyDigest: keyDigest,
            priorityControl: priorityControl
        )
        defer {
            await discardPreparation(plan.preparation)
            await priorityControl.finish()
        }
        do {
            try codecDescriptor.requireSupport(
                FoveaCodecAdmission.capabilityRequest(for: plan.probe))
        } catch {
            let failure = PipelineFailure.imageCraft(error, stage: .probe)
            await FoveaDecodeDiagnostics.recordTerminalFailure(
                diagnostics: diagnostics,
                failure: failure,
                keyDigest: keyDigest,
                probe: plan.probe
            )
            throw failure
        }
    }

    private func performDecode(
        data: Data,
        request: ImageRequest,
        keyDigest: String,
        priorityControl: SharedTaskPriorityControl,
        preparation: ImageDecodePreparation?
    ) async throws -> DecodedImage {
        try Task.checkCancellation()
        await diagnostics.record(
            DiagnosticEvent(
                kind: .decodeQueued,
                keyDigest: keyDigest,
                requestedPriority: request.priority
            )
        )

        let decodeRequest = FoveaCodecAdmission.decodeRequest(for: request)
        let plan: FoveaDecodePlan
        if let preparation {
            try preparation.probe.validateForFovea(under: limits)
            plan = FoveaDecodePlan(probe: preparation.probe, preparation: preparation)
        } else {
            plan = try await prepareDecode(
                data: data,
                request: request,
                keyDigest: keyDigest,
                priorityControl: priorityControl
            )
        }
        let image = try await admitAndDecode(
            data: data,
            plan: plan,
            request: request,
            decodeRequest: decodeRequest,
            keyDigest: keyDigest,
            priorityControl: priorityControl
        )
        await FoveaDecodeDiagnostics.recordCompleted(
            diagnostics: diagnostics,
            image: image,
            probe: plan.probe,
            request: request,
            keyDigest: keyDigest
        )
        return image
    }

    private func admitAndDecode(
        data: Data,
        plan: FoveaDecodePlan,
        request: ImageRequest,
        decodeRequest: ImageDecodeRequest,
        keyDigest: String,
        priorityControl: SharedTaskPriorityControl
    ) async throws -> DecodedImage {
        do {
            try codecDescriptor.requireSupport(
                FoveaCodecAdmission.capabilityRequest(for: plan.probe))
            try Task.checkCancellation()
            let estimateStarted =
                detailedDiagnosticsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
            let workingSetBytes = try await FoveaCodecAdmission.workingSetBytes(
                codec: codec,
                executor: executor,
                probe: plan.probe,
                request: decodeRequest
            )
            if detailedDiagnosticsEnabled {
                await diagnostics.record(
                    DiagnosticEvent(
                        kind: .decodeResourceEstimateCompleted,
                        keyDigest: keyDigest,
                        byteCount: workingSetBytes,
                        durationNanoseconds:
                            DispatchTime.now().uptimeNanoseconds &- estimateStarted
                    )
                )
            }
            try Task.checkCancellation()
            return try await FoveaRasterDecodeStage.decode(
                data: data,
                plan: plan,
                request: request,
                decodeRequest: decodeRequest,
                workEstimate: workingSetBytes,
                keyDigest: keyDigest,
                priorityControl: priorityControl,
                codec: codec,
                limits: limits,
                executor: executor,
                permits: permitController,
                diagnostics: diagnostics,
                detailedDiagnosticsEnabled: detailedDiagnosticsEnabled
            )
        } catch {
            await discardPreparation(plan.preparation)
            try await rethrowAdmissionFailure(
                error,
                plan: plan,
                decodeRequest: decodeRequest,
                keyDigest: keyDigest
            )
        }
    }

    private func rethrowAdmissionFailure(
        _ error: any Error,
        plan: FoveaDecodePlan,
        decodeRequest: ImageDecodeRequest,
        keyDigest: String
    ) async throws -> Never {
        if let failure = error as? PipelineFailure { throw failure }
        let failure =
            error is CancellationError
            ? PipelineFailure.cancelled(stage: .decode)
            : PipelineFailure.imageCraft(error, stage: .decode)
        await FoveaDecodeDiagnostics.recordTerminalFailure(
            diagnostics: diagnostics,
            failure: failure,
            keyDigest: keyDigest,
            probe: plan.probe,
            decodeRequest: decodeRequest
        )
        throw failure
    }

    private func prepareDecode(
        data: Data,
        request: ImageRequest,
        keyDigest: String,
        priorityControl: SharedTaskPriorityControl
    ) async throws -> FoveaDecodePlan {
        let permit = try await acquireProbePermit(
            dataCount: data.count,
            keyDigest: keyDigest,
            priorityControl: priorityControl
        )
        await recordProbeStarted(
            request: request,
            keyDigest: keyDigest,
            priorityControl: priorityControl
        )
        do {
            let timed = try await executeProbe(data: data, permit: permit)
            try timed.plan.probe.validateForFovea(under: limits)
            try Task.checkCancellation()
            await recordProbeDiagnostics(timed, keyDigest: keyDigest)
            return timed.plan
        } catch {
            try await rethrowProbeFailure(error, keyDigest: keyDigest)
        }
    }

    private func acquireProbePermit(
        dataCount: Int,
        keyDigest: String,
        priorityControl: SharedTaskPriorityControl
    ) async throws -> AsyncPermitPool.Permit {
        do {
            return try await permitController.acquireDecodePermit(
                priorityControl: priorityControl,
                workEstimate: dataCount
            )
        } catch let failure as PipelineFailure {
            await FoveaDecodeDiagnostics.recordTerminalFailure(
                diagnostics: diagnostics,
                failure: failure,
                keyDigest: keyDigest
            )
            throw failure
        }
    }

    private func recordProbeStarted(
        request: ImageRequest,
        keyDigest: String,
        priorityControl: SharedTaskPriorityControl
    ) async {
        await diagnostics.record(
            DiagnosticEvent(
                kind: .decodeStarted,
                keyDigest: keyDigest,
                requestedPriority: request.priority,
                effectivePriority: await priorityControl.currentPriority()
            )
        )
    }

    private func executeProbe(
        data: Data,
        permit: consuming AsyncPermitPool.Permit
    ) async throws -> TimedDecodePlan {
        try await permit.withPermit {
            try await executor.run { [codec, limits] in
                let started = DispatchTime.now().uptimeNanoseconds
                let plan = try Self.makeDecodePlan(
                    codec: codec,
                    data: data,
                    limits: limits
                )
                return TimedDecodePlan(
                    plan: plan,
                    durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- started
                )
            }
        }
    }

    private static func makeDecodePlan(
        codec: any ImageCodec,
        data: Data,
        limits: DecodeLimits
    ) throws -> FoveaDecodePlan {
        if let preparedDecoder = codec as? any PreparedImageDecoding {
            let preparation = try preparedDecoder.prepare(data: data, limits: limits)
            return FoveaDecodePlan(probe: preparation.probe, preparation: preparation)
        }
        return FoveaDecodePlan(
            probe: try codec.probe(data: data, limits: limits),
            preparation: nil
        )
    }

    private func recordProbeDiagnostics(
        _ timed: TimedDecodePlan,
        keyDigest: String
    ) async {
        guard detailedDiagnosticsEnabled else { return }
        await diagnostics.record(
            DiagnosticEvent(
                kind: .probeCompleted,
                keyDigest: keyDigest,
                sourcePixelCount: FoveaCodecAdmission.pixelCount(
                    width: timed.plan.probe.pixelWidth,
                    height: timed.plan.probe.pixelHeight
                ),
                durationNanoseconds: timed.durationNanoseconds
            )
        )
    }

    private func rethrowProbeFailure(
        _ error: any Error,
        keyDigest: String
    ) async throws -> Never {
        let failure =
            error is CancellationError
            ? PipelineFailure.cancelled(stage: .probe)
            : PipelineFailure.imageCraft(error, stage: .probe)
        await FoveaDecodeDiagnostics.recordTerminalFailure(
            diagnostics: diagnostics,
            failure: failure,
            keyDigest: keyDigest
        )
        throw failure
    }

    private func discardPreparation(_ preparation: ImageDecodePreparation?) async {
        guard let preparation,
            let preparedDecoder = codec as? any PreparedImageDecoding
        else { return }
        _ = try? await executor.run {
            preparedDecoder.discard(preparation)
        }
    }

}
