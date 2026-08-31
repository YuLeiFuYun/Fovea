import Dispatch
import Foundation
import ImageCraftCore

package enum FoveaDecodeDiagnostics {
    package static func recordCompleted(
        diagnostics: any DiagnosticsSink,
        image: DecodedImage,
        probe: ImageProbe,
        request: ImageRequest,
        keyDigest: String
    ) async {
        await diagnostics.record(
            DiagnosticEvent(
                kind: .decodeCompleted,
                keyDigest: keyDigest,
                sourcePixelCount: FoveaCodecAdmission.pixelCount(
                    width: probe.pixelWidth,
                    height: probe.pixelHeight
                ),
                outputPixelCount: FoveaCodecAdmission.pixelCount(
                    width: image.pixelWidth,
                    height: image.pixelHeight
                ),
                targetWidth: request.target.width,
                targetHeight: request.target.height
            )
        )
    }

    package static func recordTerminalFailure(
        diagnostics: any DiagnosticsSink,
        failure: PipelineFailure,
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
                    FoveaCodecAdmission.pixelCount(width: $0.pixelWidth, height: $0.pixelHeight)
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
}

package struct FoveaDecodePlan: Sendable {
    package let probe: ImageProbe
    package let preparation: ImageDecodePreparation?

    package init(probe: ImageProbe, preparation: ImageDecodePreparation?) {
        self.probe = probe
        self.preparation = preparation
    }
}

/// 完整帧 codec 执行阶段。所有 permit 在实际像素后验验证完成后才释放。
package enum FoveaRasterDecodeStage {
    private struct TimedRasterDecode: Sendable {
        let image: DecodedImage
        let durationNanoseconds: UInt64
    }

    package static func decode(
        data: Data,
        plan: FoveaDecodePlan,
        request: ImageRequest,
        decodeRequest: ImageDecodeRequest,
        workEstimate: Int,
        preparedResourceLedger: ImageDecodeResourceLedgerSnapshot?,
        keyDigest: String,
        priorityControl: SharedTaskPriorityControl,
        codec: any ImageCodec,
        limits: DecodeLimits,
        executor: DispatchWorkExecutor,
        permits: FoveaDecodePermitController,
        diagnostics: any DiagnosticsSink,
        detailedDiagnosticsEnabled: Bool
    ) async throws -> DecodedImage {
        do {
            let timed = try await permits.withRasterPermits(
                bytes: workEstimate,
                request: request,
                keyDigest: keyDigest,
                priorityControl: priorityControl
            ) {
                let timed = try await execute(
                    data: data,
                    plan: plan,
                    request: decodeRequest,
                    codec: codec,
                    limits: limits,
                    executor: executor
                )
                try FoveaCodecOutputContract.validate(
                    timed.image,
                    probe: plan.probe,
                    request: decodeRequest,
                    limits: limits,
                    admittedWorkingSetBytes: workEstimate,
                    preparedResourceLedger: preparedResourceLedger
                )
                return timed
            }
            if detailedDiagnosticsEnabled {
                await diagnostics.record(
                    DiagnosticEvent(
                        kind: .rasterDecodeCompleted,
                        keyDigest: keyDigest,
                        outputPixelCount: FoveaCodecAdmission.pixelCount(
                            width: timed.image.pixelWidth,
                            height: timed.image.pixelHeight
                        ),
                        targetWidth: decodeRequest.target.width,
                        targetHeight: decodeRequest.target.height,
                        durationNanoseconds: timed.durationNanoseconds
                    )
                )
            }
            return timed.image
        } catch {
            let failure: PipelineFailure
            if error is CancellationError {
                failure = .cancelled(stage: .decode)
            } else if let pipelineFailure = error as? PipelineFailure {
                failure = pipelineFailure
            } else {
                failure = .imageCraft(error, stage: .decode)
            }
            await FoveaDecodeDiagnostics.recordTerminalFailure(
                diagnostics: diagnostics,
                failure: failure,
                keyDigest: keyDigest,
                probe: plan.probe,
                decodeRequest: decodeRequest
            )
            throw failure
        }
    }

    private static func execute(
        data: Data,
        plan: FoveaDecodePlan,
        request: ImageDecodeRequest,
        codec: any ImageCodec,
        limits: DecodeLimits,
        executor: DispatchWorkExecutor
    ) async throws -> TimedRasterDecode {
        try Task.checkCancellation()
        let result = try await executor.run {
            try rasterDecode(
                codec: codec,
                data: data,
                plan: plan,
                request: request,
                limits: limits
            )
        }
        try Task.checkCancellation()
        return result
    }

    private static func rasterDecode(
        codec: any ImageCodec,
        data: Data,
        plan: FoveaDecodePlan,
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
}
