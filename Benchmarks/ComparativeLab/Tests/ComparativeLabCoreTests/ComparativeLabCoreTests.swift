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
