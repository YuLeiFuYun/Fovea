import ComparativeLabCore
import Foundation
import Testing

@Test
func comparatorIdentityRequiresExactCommit_COMP_PT_001() throws {
    #expect(throws: ComparativeLabError.invalidCommit) {
        _ = try ComparatorIdentity(name: "Nuke", version: "13.0.6", exactCommit: "63a8fcb")
    }
    let value = try ComparatorIdentity(
        name: "Nuke",
        version: "13.0.6",
        exactCommit: "63a8fcbd6621340a2410bc3e9575ac97058615f4"
    )
    #expect(value.version == "13.0.6")
}

@Test
func platformComparatorIdentityBindsBuildAndDevice_COMP_PT_021() throws {
    let platform = try ComparatorPlatformBuildIdentity(
        xcodeBuild: "18A123",
        osBuild: "24A123",
        deviceProfileID: "ios26-4-simulator-calibration-v1"
    )
    let identity = try ComparatorIdentity(
        name: "AppleNative",
        version: "iOS-26.4.1",
        platformBuild: platform
    )
    #expect(identity.sourceKind == .platformBuild)
    #expect(identity.exactCommit == nil)
    #expect(identity.platformBuild == platform)
    #expect(!identity.includesWorkingTreeChanges)
}

@Test
func platformComparatorIdentityRejectsMissingBuild_COMP_PT_022() throws {
    #expect(throws: ComparativeLabError.invalidIdentifier) {
        _ = try ComparatorPlatformBuildIdentity(
            xcodeBuild: "",
            osBuild: "24A123",
            deviceProfileID: "device"
        )
    }
}

@Test
func betaDeviceArtifactsRemainProvisionalAndRedacted_COMP_PT_003() throws {
    let identity = try ComparatorIdentity(
        name: "Fovea",
        version: "workspace",
        exactCommit: "0123456789abcdef0123456789abcdef01234567"
    )
    let environment = try ComparatorRunEnvironment(
        deviceProfileID: "iphone-16e-ios27-beta-primary-v1",
        deviceRole: .primaryCurrentMid,
        osFamily: "iOS",
        osVersion: "27.0",
        osBuild: "24A5355p",
        osChannel: .beta
    )
    let target = try ComparatorPixelTarget(width: 780, height: 520)
    let result = try ComparatorLoadResult(
        outcome: .completed,
        cacheSource: .network,
        latencyNanoseconds: 1_000_000,
        pixelWidth: 780,
        pixelHeight: 520,
        receivedBytes: 1_024
    )
    let observation = try ComparatorObservation(
        sequence: 0,
        resourceID: "hero-0",
        target: target,
        result: result
    )
    let artifact = try ComparatorRunArtifact(
        workloadID: .w2DetailHero,
        comparator: identity,
        environment: environment,
        runIndex: 0,
        datasetDigest: String(repeating: "a", count: 64),
        observations: [observation]
    )
    #expect(artifact.provisional)
    let json = String(decoding: try JSONEncoder().encode(artifact), as: UTF8.self)
    #expect(!json.contains("https://"))
    #expect(!json.lowercased().contains("udid"))
    #expect(!json.contains("deviceName"))
}

@Test
func observationsMustUseDenseDeterministicSequence_COMP_PT_004() throws {
    let identity = try ComparatorIdentity(
        name: "Kingfisher",
        version: "8.11.0",
        exactCommit: "410984bf301f4fa224fe56277b3f8672cc465c79"
    )
    let environment = try ComparatorRunEnvironment(
        deviceProfileID: "stable-device",
        deviceRole: .secondaryLowerPerformance,
        osFamily: "iOS",
        osVersion: "26.6",
        osBuild: "23G80",
        osChannel: .stable
    )
    let target = try ComparatorPixelTarget(width: 96, height: 96)
    let result = try ComparatorLoadResult(
        outcome: .cancelled,
        cacheSource: .unknown,
        latencyNanoseconds: 10
    )
    let observation = try ComparatorObservation(
        sequence: 1,
        resourceID: "feed-1",
        target: target,
        result: result
    )
    #expect(throws: ComparativeLabError.invalidMeasurement) {
        _ = try ComparatorRunArtifact(
            workloadID: .w1FeedScroll,
            comparator: identity,
            environment: environment,
            runIndex: 0,
            datasetDigest: String(repeating: "b", count: 64),
            observations: [observation]
        )
    }
}

@Test
func dirtyComparatorIdentityRequiresTreeDigest_COMP_PT_002() throws {
    #expect(throws: ComparativeLabError.invalidCommit) {
        _ = try ComparatorIdentity(
            name: "Fovea",
            version: "workspace",
            exactCommit: "0123456789abcdef0123456789abcdef01234567",
            includesWorkingTreeChanges: true
        )
    }
    let value = try ComparatorIdentity(
        name: "Fovea",
        version: "workspace",
        exactCommit: "0123456789abcdef0123456789abcdef01234567",
        sourceTreeDigest: String(repeating: "c", count: 64),
        includesWorkingTreeChanges: true
    )
    #expect(value.includesWorkingTreeChanges)
}

@Test
func requestScopeAndHeadersAreExplicit_COMP_PT_008() throws {
    let request = try ComparatorRequest(
        resourceID: "asset-1",
        url: #require(URL(string: "https://benchmark.invalid/asset-1")),
        target: try ComparatorPixelTarget(width: 320, height: 240),
        contentMode: .aspectFill,
        priority: .visible,
        securityNamespace: "account-a",
        headers: ["Authorization": "Bearer redacted", "X-Benchmark-Request-ID": "17"]
    )
    #expect(request.scopedCacheKey == "account-a|asset-1")
    #expect(request.headers["authorization"] == "Bearer redacted")
    #expect(request.headers["x-benchmark-request-id"] == "17")
}

@Test
func runtimeConfigurationAttestationIsBoundedAndCodable_COMP_PT_025() throws {
    let configuration = try ComparatorRuntimeConfiguration(
        parameters: [
            "session.httpMaximumConnectionsPerHost": "6",
            "session.urlCache": "nil",
        ]
    )
    let encoded = try JSONEncoder().encode(configuration)
    let decoded = try JSONDecoder().decode(ComparatorRuntimeConfiguration.self, from: encoded)
    #expect(decoded == configuration)
    #expect(decoded.schemaVersion == 1)
    #expect(decoded.parameters["session.httpMaximumConnectionsPerHost"] == "6")

    #expect(throws: ComparativeLabError.invalidIdentifier) {
        _ = try ComparatorRuntimeConfiguration(parameters: [:])
    }
    #expect(throws: ComparativeLabError.invalidIdentifier) {
        _ = try ComparatorRuntimeConfiguration(parameters: ["session.urlCache": "nil\nforged"])
    }
}

@Test
func displayReadyMeasurementRoundTripsWithoutReplacingAdapterLatency_COMP_PT_023() throws {
    let result = try ComparatorLoadResult(
        outcome: .completed,
        cacheSource: .disk,
        latencyNanoseconds: 4_000,
        pixelWidth: 780,
        pixelHeight: 520,
        receivedBytes: 0,
        pixelMaterializationNanoseconds: 1_500,
        displayReadyLatencyNanoseconds: 5_800
    )
    let encoded = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(ComparatorLoadResult.self, from: encoded)
    #expect(decoded.latencyNanoseconds == 4_000)
    #expect(decoded.pixelMaterializationNanoseconds == 1_500)
    #expect(decoded.displayReadyLatencyNanoseconds == 5_800)
}

@Test
func displayReadyMeasurementRejectsImpossibleTimelines_COMP_PT_024() throws {
    #expect(throws: ComparativeLabError.invalidMeasurement) {
        _ = try ComparatorLoadResult(
            outcome: .completed,
            cacheSource: .memory,
            latencyNanoseconds: 4_000,
            pixelWidth: 10,
            pixelHeight: 10,
            pixelMaterializationNanoseconds: 1_000,
            displayReadyLatencyNanoseconds: 3_999
        )
    }
    #expect(throws: ComparativeLabError.invalidMeasurement) {
        _ = try ComparatorLoadResult(
            outcome: .cancelled,
            cacheSource: .unknown,
            latencyNanoseconds: 4_000,
            pixelMaterializationNanoseconds: 1_000,
            displayReadyLatencyNanoseconds: 5_000
        )
    }
    #expect(throws: ComparativeLabError.invalidMeasurement) {
        _ = try ComparatorLoadResult(
            outcome: .completed,
            cacheSource: .disk,
            latencyNanoseconds: 4_000,
            pixelWidth: 10,
            pixelHeight: 10,
            pixelMaterializationNanoseconds: 1_000
        )
    }
}

@Test
func animatedPresentationOracleScoresExactTimeline_COMP_PT_025() throws {
    let timeline = try AnimatedPresentationTimeline(
        frameDurationsNanoseconds: [10, 10, 10, 10]
    )
    let observations = try [0, 1, 2, 3, 0].enumerated().map { sequence, frameIndex in
        try AnimatedPresentationObservation(
            sequence: sequence,
            elapsedNanoseconds: UInt64(sequence * 10),
            frameIndex: frameIndex,
            mainThreadCallbackNanoseconds: UInt64(sequence + 1)
        )
    }
    let score = try AnimatedPresentationOracle.score(
        timeline: timeline,
        observations: observations,
        deadlineToleranceNanoseconds: 0
    )
    #expect(score.observationCount == 5)
    #expect(score.transitionCount == 4)
    #expect(score.frameStateMismatchObservationCount == 0)
    #expect(score.observedSkippedSourceFrameCount == 0)
    #expect(score.missedDeadlineCount == 0)
    #expect(score.earlyDeadlineCount == 0)
    #expect(score.p95AbsoluteTimingErrorNanoseconds == 0)
    #expect(score.p95MainThreadCallbackNanoseconds == 5)
}

@Test
func animatedPresentationOracleSeparatesLateEarlyAndSkippedFrames_COMP_PT_026() throws {
    let timeline = try AnimatedPresentationTimeline(
        frameDurationsNanoseconds: [10, 10, 10, 10]
    )
    let observations = [
        try AnimatedPresentationObservation(sequence: 0, elapsedNanoseconds: 0, frameIndex: 0),
        try AnimatedPresentationObservation(sequence: 1, elapsedNanoseconds: 8, frameIndex: 1),
        try AnimatedPresentationObservation(sequence: 2, elapsedNanoseconds: 35, frameIndex: 3),
        try AnimatedPresentationObservation(sequence: 3, elapsedNanoseconds: 45, frameIndex: 0),
    ]
    let score = try AnimatedPresentationOracle.score(
        timeline: timeline,
        observations: observations,
        deadlineToleranceNanoseconds: 1
    )
    #expect(score.transitionCount == 3)
    #expect(score.observedSkippedSourceFrameCount == 1)
    #expect(score.earlyDeadlineCount == 1)
    #expect(score.missedDeadlineCount == 2)
    #expect(score.p50AbsoluteTimingErrorNanoseconds == 5)
    #expect(score.p95AbsoluteTimingErrorNanoseconds == 5)
    #expect(score.maximumAbsoluteTimingErrorNanoseconds == 5)
}

@Test
func animatedPresentationOracleMeasuresStallWithoutInventingInternalDrops_COMP_PT_027() throws {
    let timeline = try AnimatedPresentationTimeline(
        frameDurationsNanoseconds: [10, 10, 10, 10]
    )
    let observations = [
        try AnimatedPresentationObservation(sequence: 0, elapsedNanoseconds: 0, frameIndex: 0),
        try AnimatedPresentationObservation(sequence: 1, elapsedNanoseconds: 10, frameIndex: 0),
        try AnimatedPresentationObservation(sequence: 2, elapsedNanoseconds: 20, frameIndex: 0),
        try AnimatedPresentationObservation(sequence: 3, elapsedNanoseconds: 30, frameIndex: 1),
    ]
    let score = try AnimatedPresentationOracle.score(
        timeline: timeline,
        observations: observations,
        deadlineToleranceNanoseconds: 5
    )
    #expect(score.staleObservationCount == 3)
    #expect(score.aheadObservationCount == 0)
    #expect(score.maximumBehindFrameCount == 2)
    #expect(score.observedSkippedSourceFrameCount == 0)
    #expect(score.missedDeadlineCount == 1)
    #expect(score.maximumAbsoluteTimingErrorNanoseconds == 20)
}

@Test
func animatedPresentationOracleFlagsImplausibleBackwardTransitionAsOrderViolation_COMP_PT_028()
    throws
{
    let timeline = try AnimatedPresentationTimeline(
        frameDurationsNanoseconds: [10, 10, 10, 10]
    )
    let observations = [
        try AnimatedPresentationObservation(sequence: 0, elapsedNanoseconds: 0, frameIndex: 0),
        try AnimatedPresentationObservation(sequence: 1, elapsedNanoseconds: 10, frameIndex: 1),
        try AnimatedPresentationObservation(sequence: 2, elapsedNanoseconds: 20, frameIndex: 2),
        try AnimatedPresentationObservation(sequence: 3, elapsedNanoseconds: 21, frameIndex: 1),
    ]
    let score = try AnimatedPresentationOracle.score(
        timeline: timeline,
        observations: observations,
        deadlineToleranceNanoseconds: 1
    )
    #expect(score.frameOrderViolationCount == 1)
    #expect(score.maximumAheadFrameCount == 3)
    #expect(score.observedSkippedSourceFrameCount == 2)
}

@Test
func animatedPresentationOracleRejectsUnanchoredOrNondenseTrace_COMP_PT_029() throws {
    let timeline = try AnimatedPresentationTimeline(frameDurationsNanoseconds: [10, 10])
    #expect(throws: ComparativeLabError.invalidMeasurement) {
        _ = try AnimatedPresentationOracle.score(
            timeline: timeline,
            observations: [
                try AnimatedPresentationObservation(
                    sequence: 0,
                    elapsedNanoseconds: 1,
                    frameIndex: 0
                )
            ],
            deadlineToleranceNanoseconds: 0
        )
    }
    #expect(throws: ComparativeLabError.invalidMeasurement) {
        _ = try AnimatedPresentationOracle.score(
            timeline: timeline,
            observations: [
                try AnimatedPresentationObservation(
                    sequence: 0,
                    elapsedNanoseconds: 0,
                    frameIndex: 0
                ),
                try AnimatedPresentationObservation(
                    sequence: 2,
                    elapsedNanoseconds: 10,
                    frameIndex: 1
                ),
            ],
            deadlineToleranceNanoseconds: 0
        )
    }
}

@Test
func animatedPresentationTimelineRejectsInvalidDurationsAndRoundTrips_COMP_PT_030() throws {
    #expect(throws: ComparativeLabError.invalidMeasurement) {
        _ = try AnimatedPresentationTimeline(frameDurationsNanoseconds: [10])
    }
    #expect(throws: ComparativeLabError.invalidMeasurement) {
        _ = try AnimatedPresentationTimeline(frameDurationsNanoseconds: [10, 0])
    }
    let timeline = try AnimatedPresentationTimeline(frameDurationsNanoseconds: [7, 11, 13])
    let encoded = try JSONEncoder().encode(timeline)
    let decoded = try JSONDecoder().decode(AnimatedPresentationTimeline.self, from: encoded)
    #expect(decoded == timeline)
    #expect(decoded.totalDurationNanoseconds == 31)
}

@Test
func animatedMediaWorkloadIdentityMatchesRegistry_COMP_PT_031() {
    #expect(ComparativeWorkloadID.w5AnimatedMedia.rawValue == "W5-ANIMATED-MEDIA-V1")
}

@Test
func animatedPresentationArtifactBindsRawTraceAndDerivedScore_COMP_PT_032() throws {
    let comparator = try ComparatorIdentity(
        name: "FLAnimatedImage",
        version: "1.0.17",
        exactCommit: "0123456789abcdef0123456789abcdef01234567"
    )
    let environment = try ComparatorRunEnvironment(
        deviceProfileID: "stable-animation-device",
        deviceRole: .primaryCurrentMid,
        osFamily: "iOS",
        osVersion: "26.6",
        osBuild: "23G80",
        osChannel: .stable
    )
    let timeline = try AnimatedPresentationTimeline(frameDurationsNanoseconds: [10, 10])
    let observations = [
        try AnimatedPresentationObservation(sequence: 0, elapsedNanoseconds: 0, frameIndex: 0),
        try AnimatedPresentationObservation(sequence: 1, elapsedNanoseconds: 15, frameIndex: 1),
        try AnimatedPresentationObservation(sequence: 2, elapsedNanoseconds: 25, frameIndex: 0),
    ]
    let artifact = try ComparatorAnimatedPresentationArtifact(
        comparator: comparator,
        environment: environment,
        runIndex: 2,
        datasetDigest: String(repeating: "a", count: 64),
        startupLatencyNanoseconds: 1_000,
        deadlineToleranceNanoseconds: 4,
        timeline: timeline,
        observations: observations
    )
    #expect(artifact.workloadID == .w5AnimatedMedia)
    #expect(!artifact.provisional)
    #expect(artifact.score.missedDeadlineCount == 2)
    let encoded = try JSONEncoder().encode(artifact)
    let decoded = try JSONDecoder().decode(
        ComparatorAnimatedPresentationArtifact.self,
        from: encoded
    )
    #expect(decoded == artifact)
}

@Test
func animatedPresentationArtifactRejectsTamperedScore_COMP_PT_033() throws {
    let comparator = try ComparatorIdentity(
        name: "Fovea",
        version: "workspace",
        exactCommit: "0123456789abcdef0123456789abcdef01234567"
    )
    let environment = try ComparatorRunEnvironment(
        deviceProfileID: "beta-animation-device",
        deviceRole: .primaryCurrentMid,
        osFamily: "iOS",
        osVersion: "27.0",
        osBuild: "24A5390e",
        osChannel: .beta
    )
    let artifact = try ComparatorAnimatedPresentationArtifact(
        comparator: comparator,
        environment: environment,
        runIndex: 0,
        datasetDigest: String(repeating: "b", count: 64),
        startupLatencyNanoseconds: 500,
        deadlineToleranceNanoseconds: 1,
        timeline: try AnimatedPresentationTimeline(frameDurationsNanoseconds: [10, 10]),
        observations: [
            try AnimatedPresentationObservation(sequence: 0, elapsedNanoseconds: 0, frameIndex: 0),
            try AnimatedPresentationObservation(sequence: 1, elapsedNanoseconds: 10, frameIndex: 1),
        ]
    )
    var object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(artifact)) as? [String: Any]
    )
    var score = try #require(object["score"] as? [String: Any])
    score["missedDeadlineCount"] = 99
    object["score"] = score
    let tampered = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ComparativeLabError.invalidMeasurement) {
        _ = try JSONDecoder().decode(ComparatorAnimatedPresentationArtifact.self, from: tampered)
    }
}

@Test
func animatedPlayerRequestEnforcesBoundedEncodedAndFrameMemory_COMP_PT_034() throws {
    let request = try ComparatorAnimatedPlayerRequest(
        resourceID: "gif-variable-delay-60",
        encodedData: Data("GIF89a".utf8),
        format: .gif,
        referenceFrameDurationsNanoseconds: [20_000_000, 30_000_000],
        referenceLoopCount: 0,
        maximumFrameBufferBytes: 4 * 1_024 * 1_024
    )
    #expect(request.maximumFrameBufferBytes == 4 * 1_024 * 1_024)
    #expect(throws: ComparativeLabError.invalidMeasurement) {
        _ = try ComparatorAnimatedPlayerRequest(
            resourceID: "invalid",
            encodedData: Data(),
            format: .gif,
            referenceFrameDurationsNanoseconds: [20_000_000, 30_000_000],
            referenceLoopCount: 0,
            maximumFrameBufferBytes: 1
        )
    }
    #expect(throws: ComparativeLabError.invalidMeasurement) {
        _ = try ComparatorAnimatedPlayerRequest(
            resourceID: "invalid",
            encodedData: Data([1]),
            format: .gif,
            referenceFrameDurationsNanoseconds: [20_000_000, 30_000_000],
            referenceLoopCount: 0,
            maximumFrameBufferBytes: 0
        )
    }
}

@Test
func animatedPlayerRawEventsNormalizeAtFirstVisibleFrame_COMP_PT_035() throws {
    let normalized = try AnimatedPresentationOracle.normalize(
        events: [
            try ComparatorAnimatedPlayerFrameEvent(
                sequence: 0,
                monotonicNanoseconds: 1_000,
                sourceFrameIndex: 0
            ),
            try ComparatorAnimatedPlayerFrameEvent(
                sequence: 1,
                monotonicNanoseconds: 1_015,
                sourceFrameIndex: 1,
                mainThreadCallbackNanoseconds: 4
            ),
            try ComparatorAnimatedPlayerFrameEvent(
                sequence: 2,
                monotonicNanoseconds: 1_030,
                sourceFrameIndex: 2
            ),
        ]
    )
    #expect(normalized.map(\.elapsedNanoseconds) == [0, 15, 30])
    #expect(normalized.map(\.frameIndex) == [0, 1, 2])
    #expect(normalized[1].mainThreadCallbackNanoseconds == 4)
}

@Test
func animatedPlayerRawEventNormalizationRejectsRegressingTrace_COMP_PT_036() throws {
    #expect(throws: ComparativeLabError.invalidMeasurement) {
        _ = try AnimatedPresentationOracle.normalize(
            events: [
                try ComparatorAnimatedPlayerFrameEvent(
                    sequence: 0,
                    monotonicNanoseconds: 100,
                    sourceFrameIndex: 0
                ),
                try ComparatorAnimatedPlayerFrameEvent(
                    sequence: 1,
                    monotonicNanoseconds: 100,
                    sourceFrameIndex: 1
                ),
            ]
        )
    }
}

@Test
func animatedPresentationOracleRotatesToFirstRealSourceFrame_COMP_PT_037() throws {
    let timeline = try AnimatedPresentationTimeline(
        frameDurationsNanoseconds: [10, 20, 30, 40]
    )
    let observations = [
        try AnimatedPresentationObservation(sequence: 0, elapsedNanoseconds: 0, frameIndex: 1),
        try AnimatedPresentationObservation(sequence: 1, elapsedNanoseconds: 20, frameIndex: 2),
        try AnimatedPresentationObservation(sequence: 2, elapsedNanoseconds: 50, frameIndex: 3),
        try AnimatedPresentationObservation(sequence: 3, elapsedNanoseconds: 90, frameIndex: 0),
        try AnimatedPresentationObservation(sequence: 4, elapsedNanoseconds: 100, frameIndex: 1),
    ]
    let score = try AnimatedPresentationOracle.score(
        timeline: timeline,
        observations: observations,
        deadlineToleranceNanoseconds: 0
    )
    #expect(score.transitionCount == 4)
    #expect(score.frameStateMismatchObservationCount == 0)
    #expect(score.observedSkippedSourceFrameCount == 0)
    #expect(score.missedDeadlineCount == 0)
    #expect(score.earlyDeadlineCount == 0)
    #expect(score.p95AbsoluteTimingErrorNanoseconds == 0)
}

@Test
func gifCentisecondNormalizationRemovesFloat32NoiseWithoutHidingSemanticClamp_COMP_PT_038() throws {
    let thirtyMillisecondsAsFloat32 = Double(Float(0.03))
    let eightyMillisecondsAsFloat32 = Double(Float(0.08))
    #expect(
        try ComparatorAnimatedDurationNormalization.gifCentisecondNanoseconds(
            seconds: thirtyMillisecondsAsFloat32
        ) == 30_000_000
    )
    #expect(
        try ComparatorAnimatedDurationNormalization.gifCentisecondNanoseconds(
            seconds: eightyMillisecondsAsFloat32
        ) == 80_000_000
    )
    #expect(
        try ComparatorAnimatedDurationNormalization.gifCentisecondNanoseconds(seconds: 0.1)
            == 100_000_000
    )
    #expect(throws: ComparativeLabError.invalidMeasurement) {
        _ = try ComparatorAnimatedDurationNormalization.gifCentisecondNanoseconds(seconds: 0)
    }
}

@Test
func
    apngMicrosecondNormalizationRemovesBinaryMetadataNoiseWithoutHidingMillisecondRewrite_COMP_PT_039()
    throws
{
    #expect(
        try ComparatorAnimatedDurationNormalization.nearestMicrosecondNanoseconds(
            seconds: Double(Float(0.03))
        ) == 30_000_000
    )
    #expect(
        try ComparatorAnimatedDurationNormalization.nearestMicrosecondNanoseconds(
            seconds: 0.029_999_999
        ) == 30_000_000
    )
    #expect(
        try ComparatorAnimatedDurationNormalization.nearestMicrosecondNanoseconds(
            seconds: 0.1
        ) == 100_000_000
    )
    #expect(throws: ComparativeLabError.invalidMeasurement) {
        _ = try ComparatorAnimatedDurationNormalization.nearestMicrosecondNanoseconds(seconds: 0)
    }
}
