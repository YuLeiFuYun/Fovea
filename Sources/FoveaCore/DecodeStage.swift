import Foundation
import ImageCraftCore

/// 将探测、工作集准入与最终解码组织为三个资源边界。
/// 探测与解码共享调度优先级，但等待工作集时不得占用解码并发许可。
package final class DecodeStage: Sendable {
    private struct DecodePlan: Sendable {
        let probe: ImageProbe
        let preparation: ImageDecodePreparation?
    }

    private struct TimedDecodePlan: Sendable {
        let plan: DecodePlan
        let durationNanoseconds: UInt64
    }

    private struct TimedRasterDecode: Sendable {
        let image: DecodedImage
        let durationNanoseconds: UInt64
    }

    private let codec: any ImageCodec
    package let codecDescriptor: ImageCodecDescriptor
    private let limits: DecodeLimits
    private let diagnostics: any DiagnosticsSink
    private let detailedDiagnosticsEnabled: Bool
    private let permits: AsyncPermitPool
    private let workingSetPermits: AsyncPermitPool
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
        workingSetPermits: AsyncPermitPool? = nil
    ) {
        self.codec = codec
        self.codecDescriptor = codec.codecDescriptor
        self.limits = limits
        self.diagnostics = diagnostics
        self.detailedDiagnosticsEnabled = detailedDiagnosticsAreEnabled(diagnostics)
        self.permits =
            decodePermits
            ?? AsyncPermitPool(
                limit: maximumConcurrentDecodes,
                queueLimit: maximumQueuedDecodes
            )
        self.workingSetPermits =
            workingSetPermits
            ?? AsyncPermitPool(
                limit: maximumDecodeWorkingSetBytes,
                queueLimit: maximumQueuedDecodes
            )
    }

    package var progressiveEncodedByteLimit: Int { limits.maximumEncodedBytes }

    package func makeProgressiveSession(
        for request: ImageRequest,
        format: EncodedImageFormat
    ) throws -> (any ImageProgressiveDecodeSession)? {
        guard codecDescriptor.capabilities.progressiveFormats.contains(format),
            let progressive = codec as? any ProgressiveImageDecoding
        else { return nil }
        return try progressive.makeProgressiveSession(
            format: format,
            request: Self.decodeRequest(for: request),
            limits: limits
        )
    }

    package func appendProgressive(
        _ chunk: Data,
        to session: any ImageProgressiveDecodeSession
    ) async throws -> ImageProgressiveDecodeGeneration? {
        try Task.checkCancellation()
        let generation = try await executor.run {
            try session.append(chunk)
        }
        try Task.checkCancellation()
        return generation
    }

    package func finishProgressive(
        _ session: any ImageProgressiveDecodeSession
    ) async throws {
        try Task.checkCancellation()
        try await executor.run {
            try session.finish()
        }
    }

    package func finishProgressiveWithPreparation(
        _ session: any ProgressiveImagePreparingSession
    ) async throws -> ImageProgressiveDecodePreparationFinalization {
        try Task.checkCancellation()
        let finalization = try await executor.run {
            try session.finishWithPreparation()
        }
        try Task.checkCancellation()
        return finalization
    }

    package func discardProgressivePreparation(
        _ preparation: ImageDecodePreparation
    ) async {
        guard let preparedDecoder = codec as? any PreparedImageDecoding else { return }
        _ = try? await executor.run {
            preparedDecoder.discard(preparation)
        }
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
            try codecDescriptor.requireSupport(Self.capabilityRequest(for: plan.probe))
        } catch {
            let failure = PipelineFailure.imageCraft(error, stage: .probe)
            await recordTerminalFailure(failure, keyDigest: keyDigest, probe: plan.probe)
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

        let decodeRequest = Self.decodeRequest(for: request)
        let plan: DecodePlan
        if let preparation {
            try preparation.probe.validateForFovea(under: limits)
            plan = DecodePlan(probe: preparation.probe, preparation: preparation)
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
        await recordDecodeCompleted(
            image: image,
            probe: plan.probe,
            request: request,
            keyDigest: keyDigest
        )
        return image
    }

    private func admitAndDecode(
        data: Data,
        plan: DecodePlan,
        request: ImageRequest,
        decodeRequest: ImageDecodeRequest,
        keyDigest: String,
        priorityControl: SharedTaskPriorityControl
    ) async throws -> DecodedImage {
        do {
            try codecDescriptor.requireSupport(Self.capabilityRequest(for: plan.probe))
            try Task.checkCancellation()
            let workingSetBytes = try await conservativeWorkingSetBytes(
                probe: plan.probe,
                request: decodeRequest
            )
            try Task.checkCancellation()
            let permit = try await reserveWorkingSet(
                bytes: workingSetBytes,
                request: request,
                keyDigest: keyDigest,
                priorityControl: priorityControl
            )
            return try await decode(
                data: data,
                plan: plan,
                decodeRequest: decodeRequest,
                workingSetPermit: permit,
                workEstimate: workingSetBytes,
                keyDigest: keyDigest,
                priorityControl: priorityControl
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
        plan: DecodePlan,
        decodeRequest: ImageDecodeRequest,
        keyDigest: String
    ) async throws -> Never {
        if let failure = error as? PipelineFailure { throw failure }
        let failure =
            error is CancellationError
            ? PipelineFailure.cancelled(stage: .decode)
            : PipelineFailure.imageCraft(error, stage: .decode)
        await recordTerminalFailure(
            failure,
            keyDigest: keyDigest,
            probe: plan.probe,
            decodeRequest: decodeRequest
        )
        throw failure
    }

    private func recordDecodeCompleted(
        image: DecodedImage,
        probe: ImageProbe,
        request: ImageRequest,
        keyDigest: String
    ) async {
        await diagnostics.record(
            DiagnosticEvent(
                kind: .decodeCompleted,
                keyDigest: keyDigest,
                sourcePixelCount: Self.pixelCount(
                    width: probe.pixelWidth, height: probe.pixelHeight),
                outputPixelCount: Self.pixelCount(
                    width: image.pixelWidth, height: image.pixelHeight),
                targetWidth: request.target.width,
                targetHeight: request.target.height
            )
        )
    }

    private func prepareDecode(
        data: Data,
        request: ImageRequest,
        keyDigest: String,
        priorityControl: SharedTaskPriorityControl
    ) async throws -> DecodePlan {
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
            return try await acquireDecodePermit(
                priorityControl: priorityControl,
                workEstimate: dataCount
            )
        } catch let failure as PipelineFailure {
            await recordTerminalFailure(failure, keyDigest: keyDigest)
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
    ) throws -> DecodePlan {
        if let preparedDecoder = codec as? any PreparedImageDecoding {
            let preparation = try preparedDecoder.prepare(data: data, limits: limits)
            return DecodePlan(probe: preparation.probe, preparation: preparation)
        }
        return DecodePlan(
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
                sourcePixelCount: Self.pixelCount(
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
        await recordTerminalFailure(failure, keyDigest: keyDigest)
        throw failure
    }

    private func reserveWorkingSet(
        bytes: Int,
        request: ImageRequest,
        keyDigest: String,
        priorityControl: SharedTaskPriorityControl
    ) async throws -> AsyncPermitPool.Permit {
        do {
            let permit = try await workingSetPermits.acquire(
                units: bytes,
                priority: await priorityControl.currentPriority(),
                workEstimate: bytes,
                priorityUpdates: await priorityControl.updates()
            )
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .decodeWorkingSetReserved,
                    keyDigest: keyDigest,
                    byteCount: bytes,
                    requestedPriority: request.priority,
                    effectivePriority: await priorityControl.currentPriority()
                )
            )
            return permit
        } catch is CancellationError {
            let failure = PipelineFailure.cancelled(stage: .decode)
            await recordTerminalFailure(failure, keyDigest: keyDigest)
            throw failure
        } catch PermitPoolError.requestExceedsLimit {
            await diagnostics.record(
                DiagnosticEvent(
                    kind: .decodeAdmissionRejected,
                    keyDigest: keyDigest,
                    byteCount: bytes,
                    reason: "decode-working-set-limit-exceeded"
                )
            )
            let failure = PipelineFailure.resourceLimit(
                stage: .decode,
                reasonCode: "decode-working-set-limit-exceeded"
            )
            await recordTerminalFailure(failure, keyDigest: keyDigest)
            throw failure
        } catch PermitPoolError.queueLimitExceeded {
            let failure = PipelineFailure.resourceLimit(
                stage: .decode,
                reasonCode: "decode-working-set-queue-limit-exceeded"
            )
            await recordTerminalFailure(failure, keyDigest: keyDigest)
            throw failure
        } catch {
            let failure = PipelineFailure.internalFailure(stage: .decode)
            await recordTerminalFailure(failure, keyDigest: keyDigest)
            throw failure
        }
    }

    private func decode(
        data: Data,
        plan: DecodePlan,
        decodeRequest: ImageDecodeRequest,
        workingSetPermit: consuming AsyncPermitPool.Permit,
        workEstimate: Int,
        keyDigest: String,
        priorityControl: SharedTaskPriorityControl
    ) async throws -> DecodedImage {
        do {
            let timed = try await executeRasterDecode(
                data: data,
                plan: plan,
                decodeRequest: decodeRequest,
                workingSetPermit: workingSetPermit,
                workEstimate: workEstimate,
                priorityControl: priorityControl
            )
            await recordRasterDiagnostics(
                timed,
                decodeRequest: decodeRequest,
                keyDigest: keyDigest
            )
            return timed.image
        } catch {
            try await rethrowRasterFailure(
                error,
                plan: plan,
                decodeRequest: decodeRequest,
                keyDigest: keyDigest
            )
        }
    }

    private func executeRasterDecode(
        data: Data,
        plan: DecodePlan,
        decodeRequest: ImageDecodeRequest,
        workingSetPermit: consuming AsyncPermitPool.Permit,
        workEstimate: Int,
        priorityControl: SharedTaskPriorityControl
    ) async throws -> TimedRasterDecode {
        try await workingSetPermit.withPermit {
            let decodePermit = try await acquireDecodePermit(
                priorityControl: priorityControl,
                workEstimate: workEstimate
            )
            return try await decodePermit.withPermit {
                try Task.checkCancellation()
                let result = try await executor.run { [codec, limits] in
                    try Self.rasterDecode(
                        codec: codec,
                        data: data,
                        plan: plan,
                        request: decodeRequest,
                        limits: limits
                    )
                }
                try Task.checkCancellation()
                return result
            }
        }
    }

    private static func rasterDecode(
        codec: any ImageCodec,
        data: Data,
        plan: DecodePlan,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> TimedRasterDecode {
        let started = DispatchTime.now().uptimeNanoseconds
        let image: DecodedImage
        if let preparation = plan.preparation,
            let preparedDecoder = codec as? any PreparedImageDecoding
        {
            image = try preparedDecoder.decode(
                preparation: preparation,
                request: request,
                limits: limits
            )
        } else {
            image = try codec.decode(
                data: data,
                probe: plan.probe,
                request: request,
                limits: limits
            )
        }
        return TimedRasterDecode(
            image: image,
            durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- started
        )
    }

    private func recordRasterDiagnostics(
        _ timed: TimedRasterDecode,
        decodeRequest: ImageDecodeRequest,
        keyDigest: String
    ) async {
        guard detailedDiagnosticsEnabled else { return }
        await diagnostics.record(
            DiagnosticEvent(
                kind: .rasterDecodeCompleted,
                keyDigest: keyDigest,
                outputPixelCount: Self.pixelCount(
                    width: timed.image.pixelWidth,
                    height: timed.image.pixelHeight
                ),
                targetWidth: decodeRequest.target.width,
                targetHeight: decodeRequest.target.height,
                durationNanoseconds: timed.durationNanoseconds
            )
        )
    }

    private func rethrowRasterFailure(
        _ error: any Error,
        plan: DecodePlan,
        decodeRequest: ImageDecodeRequest,
        keyDigest: String
    ) async throws -> Never {
        let failure: PipelineFailure
        if error is CancellationError {
            failure = .cancelled(stage: .decode)
        } else if let pipelineFailure = error as? PipelineFailure {
            failure = pipelineFailure
        } else {
            failure = .imageCraft(error, stage: .decode)
        }
        await recordTerminalFailure(
            failure,
            keyDigest: keyDigest,
            probe: plan.probe,
            decodeRequest: decodeRequest
        )
        throw failure
    }

    private func conservativeWorkingSetBytes(
        probe: ImageProbe,
        request: ImageDecodeRequest
    ) async throws -> Int {
        let genericBytes = FoveaDecodeWorkingSetEstimator.estimatedBytes(
            probe: probe,
            request: request
        )
        let backendEstimate = try await executor.run { [codec] in
            try codec.resourceEstimate(probe: probe, request: request)
        }
        return try ImageDecodeResourceEstimate.conservativeMaximum(
            genericBytes: genericBytes,
            backendBytes: backendEstimate.workingSetBytes
        ).workingSetBytes
    }

    private func discardPreparation(_ preparation: ImageDecodePreparation?) async {
        guard let preparation,
            let preparedDecoder = codec as? any PreparedImageDecoding
        else { return }
        _ = try? await executor.run {
            preparedDecoder.discard(preparation)
        }
    }

    private static func capabilityRequest(
        for probe: ImageProbe
    ) -> ImageDecodeCapabilityRequest {
        ImageDecodeCapabilityRequest(
            format: probe.format,
            deliveryMode: .completeFrame,
            trackMode: .primaryFrame,
            requiredMetadata: [.orientation, .sourceColorProfile],
            dynamicRange: .standard,
            outputRepresentation: .coreGraphicsImage,
            cancellationMode: .operationBoundary
        )
    }

    private static func decodeRequest(for request: ImageRequest) -> ImageDecodeRequest {
        ImageDecodeRequest(
            target: request.target,
            contentMode: request.contentMode,
            colorPolicy: request.colorPolicy
        )
    }

    private func recordTerminalFailure(
        _ failure: PipelineFailure,
        keyDigest: String,
        probe: ImageProbe? = nil,
        decodeRequest: ImageDecodeRequest? = nil
    ) async {
        await diagnostics.record(
            DiagnosticEvent(
                kind: failure.disposition == .cancelled ? .decodeCancelled : .decodeFailed,
                keyDigest: keyDigest,
                statusCode: failure.statusCode,
                sourcePixelCount: probe.map {
                    Self.pixelCount(width: $0.pixelWidth, height: $0.pixelHeight)
                },
                targetWidth: decodeRequest?.target.width,
                targetHeight: decodeRequest?.target.height,
                reason: failure.reasonCode,
                failureCategory: failure.category,
                failureStage: failure.stage,
                failureDisposition: failure.disposition
            )
        )
    }

    private func acquireDecodePermit(
        priorityControl: SharedTaskPriorityControl,
        workEstimate: Int
    ) async throws -> AsyncPermitPool.Permit {
        do {
            return try await permits.acquire(
                priority: await priorityControl.currentPriority(),
                workEstimate: workEstimate,
                priorityUpdates: await priorityControl.updates()
            )
        } catch is CancellationError {
            throw PipelineFailure.cancelled(stage: .decode)
        } catch PermitPoolError.queueLimitExceeded {
            throw PipelineFailure.resourceLimit(
                stage: .decode,
                reasonCode: "decode-queue-limit-exceeded"
            )
        } catch {
            throw PipelineFailure.internalFailure(stage: .decode)
        }
    }

    private static func pixelCount(width: Int, height: Int) -> Int {
        let (result, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? Int.max : result
    }
}
