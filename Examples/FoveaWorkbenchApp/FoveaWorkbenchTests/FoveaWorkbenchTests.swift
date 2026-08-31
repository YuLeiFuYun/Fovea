import Foundation
import FoveaCore
import ImageCraftCore
import XCTest

@testable import FoveaWorkbench

final class FoveaWorkbenchTests: XCTestCase {
    func testDeterministicFixturesAreEmbeddedTraceableRealMedia() throws {
        XCTAssertNil(Bundle.main.url(forResource: "workbench-image-blue", withExtension: "png"))
        XCTAssertNil(Bundle.main.url(forResource: "workbench-image-orange", withExtension: "png"))

        var identities = Set<String>()
        var payloadDigests = Set<Int>()
        for fixture in WorkbenchDeterministicFixture.allCases {
            let url = try XCTUnwrap(fixture.bundledURL, fixture.resourceName)
            let data = try Data(contentsOf: url)
            let asset = try XCTUnwrap(
                WorkbenchRemoteAssetCatalog.asset(id: fixture.catalogAssetID),
                fixture.catalogAssetID
            )

            XCTAssertEqual(asset.sourceKind, .bundled)
            XCTAssertEqual(asset.bundledURL, url)
            XCTAssertGreaterThan(data.count, 100_000)
            XCTAssertGreaterThan(Set(data.prefix(4_096)).count, 64)
            XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
            XCTAssertGreaterThanOrEqual(data.count, 16)
            XCTAssertEqual(String(decoding: data[12..<16], as: UTF8.self), "IHDR")
            identities.insert(fixture.cacheIdentity)
            payloadDigests.insert(data.hashValue)
        }
        XCTAssertEqual(identities.count, WorkbenchDeterministicFixture.allCases.count)
        XCTAssertEqual(payloadDigests.count, WorkbenchDeterministicFixture.allCases.count)
    }

    func testDistributionQuantilePrefetchPlannerAdaptsAndRemainsBounded_MATH_PT_006() {
        var planner = WorkbenchPrefetchPlanner()
        XCTAssertEqual(
            planner.recommendedItemCount(
                estimatedConsumptionRate: 10,
                minimum: 8,
                maximum: 64,
                fallbackLatencySeconds: 0.5
            ),
            8
        )

        planner.record(durationNanoseconds: 60_000_000_000)
        XCTAssertEqual(
            planner.recommendedItemCount(
                estimatedConsumptionRate: 1,
                minimum: 0,
                maximum: 100,
                fallbackLatencySeconds: 0
            ),
            12
        )
        planner.reset()

        planner.record(durationNanoseconds: 1_000_000_000)
        planner.record(durationNanoseconds: 2_000_000_000)
        planner.record(durationNanoseconds: 3_000_000_000)
        XCTAssertEqual(planner.sampleCount, 3)
        XCTAssertEqual(planner.meanLatencySeconds, 2, accuracy: 0.000_001)
        XCTAssertEqual(planner.sampleVarianceSecondsSquared, 1, accuracy: 0.000_001)
        XCTAssertGreaterThan(planner.distributionConfidenceMargin(), 0)

        planner.reset()
        for index in 1...128 {
            planner.record(durationNanoseconds: UInt64(index) * 10_000_000)
        }
        let relaxed = planner.recommendedItemCount(
            estimatedConsumptionRate: 100,
            targetMissProbability: 0.20,
            confidenceLevel: 0.90,
            minimum: 1,
            maximum: 256,
            fallbackLatencySeconds: 0
        )
        let lowerMissRisk = planner.recommendedItemCount(
            estimatedConsumptionRate: 100,
            targetMissProbability: 0.05,
            confidenceLevel: 0.90,
            minimum: 1,
            maximum: 256,
            fallbackLatencySeconds: 0
        )
        let higherConfidence = planner.recommendedItemCount(
            estimatedConsumptionRate: 100,
            targetMissProbability: 0.20,
            confidenceLevel: 0.99,
            minimum: 1,
            maximum: 256,
            fallbackLatencySeconds: 0
        )
        XCTAssertGreaterThan(lowerMissRisk, relaxed)
        XCTAssertGreaterThanOrEqual(higherConfidence, relaxed)
        XCTAssertEqual(
            planner.recommendedItemCount(
                estimatedConsumptionRate: 1_000,
                minimum: 4,
                maximum: 32
            ),
            32
        )

        for index in 129...200 {
            planner.record(durationNanoseconds: UInt64(index) * 10_000_000)
        }
        XCTAssertEqual(planner.sampleCount, 128)
        XCTAssertEqual(planner.maximumObservedLatencySeconds, 2, accuracy: 0.000_001)

        planner.reset()
        XCTAssertEqual(planner.sampleCount, 0)
        XCTAssertEqual(planner.meanLatencySeconds, 0)
    }

    @MainActor
    func testPrefetchCompletionCannotRemoveReplacementTaskAfterReset_DEMO_PT_029() async {
        let coordinator = WorkbenchPrefetchCoordinator()
        let loader = ControlledPrefetchLoader()
        let asset = WorkbenchRemoteAssetCatalog.remoteAssets[0]
        let stateDidChange: @MainActor (Int, Int) -> Void = { _, _ in }

        coordinator.prefetch(
            assets: [asset],
            configuration: .defaults,
            targetWidth: 640,
            targetHeight: 480,
            estimatedConsumptionRate: 1,
            minimumCount: 1,
            maximumCount: 1,
            stateDidChange: stateDidChange
        ) { _, _, _ in
            await loader.load()
        }
        await loader.waitForInvocationCount(1)
        XCTAssertEqual(coordinator.pendingCount, 1)

        coordinator.reset(stateDidChange: stateDidChange)
        coordinator.prefetch(
            assets: [asset],
            configuration: .defaults,
            targetWidth: 640,
            targetHeight: 480,
            estimatedConsumptionRate: 1,
            minimumCount: 1,
            maximumCount: 1,
            stateDidChange: stateDidChange
        ) { _, _, _ in
            await loader.load()
        }
        await loader.waitForInvocationCount(2)
        XCTAssertEqual(coordinator.pendingCount, 1)

        await loader.resolve(invocation: 0, result: true)
        await settleMainActorTasks()
        XCTAssertEqual(
            coordinator.pendingCount,
            1,
            "An obsolete completion must not delete the replacement task entry"
        )

        coordinator.cancelPending()
        XCTAssertEqual(coordinator.pendingCount, 0)
        await loader.resolve(invocation: 1, result: true)
        await settleMainActorTasks()
        XCTAssertEqual(coordinator.completedCount, 0)
    }

    @MainActor
    func testPrefetchIdentityIncludesBothTargetDimensions_DEMO_PT_030() async {
        let coordinator = WorkbenchPrefetchCoordinator()
        let counter = PrefetchLoadCounter()
        let asset = WorkbenchRemoteAssetCatalog.remoteAssets[0]
        let stateDidChange: @MainActor (Int, Int) -> Void = { _, _ in }

        for height in [480, 320] {
            coordinator.prefetch(
                assets: [asset],
                configuration: .defaults,
                targetWidth: 640,
                targetHeight: height,
                estimatedConsumptionRate: 1,
                minimumCount: 1,
                maximumCount: 1,
                stateDidChange: stateDidChange
            ) { _, _, _ in
                await counter.recordSuccess()
            }
            while coordinator.pendingCount > 0 { await Task.yield() }
        }

        let loadCount = await counter.count
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(coordinator.completedCount, 2)
    }

    func testDiagnosticsRingBufferDropsOldestWithoutReordering() async {
        let sink = WorkbenchDiagnosticsSink(capacity: 2)
        await sink.record(DiagnosticEvent(kind: .fetchStarted))
        await sink.record(DiagnosticEvent(kind: .fetchCompleted))
        await sink.record(DiagnosticEvent(kind: .pipelineFailed))

        let snapshot = await sink.snapshot()
        XCTAssertEqual(snapshot.map(\.event.kind), [.fetchCompleted, .pipelineFailed])
        let dropped = await sink.droppedEventCount()
        XCTAssertEqual(dropped, 1)
    }

    func testScenarioCatalogHasStableUniqueIdentifiers_DEMO_PT_005() {
        let identifiers = WorkbenchScenarioCatalog.all.map(\.id)
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
        XCTAssertFalse(identifiers.isEmpty)
        XCTAssertTrue(
            WorkbenchScenarioCategory.allCases.allSatisfy {
                !WorkbenchScenarioCatalog.scenarios(in: $0).isEmpty
            })
    }

    func testEcologicalAtlasHasCurrentSchemaCompleteTopologyAndRealMedia_DEMO_PT_021()
        throws
    {
        let document = EcologicalAtlasDocument.current
        XCTAssertEqual(document.schemaVersion, EcologicalAtlasDocument.currentSchemaVersion)
        XCTAssertEqual(document.volumes.count, 8)
        XCTAssertEqual(document.stories.count, 32)
        XCTAssertGreaterThanOrEqual(document.sources.count, 25)
        XCTAssertEqual(
            Set(document.sources.map(\.sourceClass)), Set(EcologicalSourceClass.allCases))
        XCTAssertEqual(Set(document.sources.map(\.id)).count, document.sources.count)
        XCTAssertEqual(Set(document.volumes.map(\.id)).count, document.volumes.count)
        XCTAssertEqual(Set(document.stories.map(\.id)).count, document.stories.count)
        XCTAssertEqual(Set(document.stories.map(\.layout)), Set(EcologicalStoryLayout.allCases))
        XCTAssertEqual(
            Set(document.stories.map(\.epistemicStatus)),
            Set(EcologicalEpistemicStatus.allCases)
        )

        let sourceIDs = Set(document.sources.map(\.id))
        let storyIDs = Set(document.stories.map(\.id))
        let volumeIDs = Set(document.volumes.map(\.id))
        let indexedStoryIDs = document.volumes.flatMap(\.storyIDs)
        XCTAssertEqual(indexedStoryIDs.count, Set(indexedStoryIDs).count)
        XCTAssertEqual(Set(indexedStoryIDs), storyIDs)

        var referencedAssets: [WorkbenchRemoteAsset] = []
        for volume in document.volumes {
            XCTAssertEqual(volume.storyIDs.count, 4, volume.id)
            for story in document.stories(in: volume) {
                XCTAssertEqual(story.volumeID, volume.id, story.id)
            }
        }
        for story in document.stories {
            XCTAssertTrue(volumeIDs.contains(story.volumeID), story.id)
            XCTAssertEqual(story.claims.count, 3, story.id)
            XCTAssertGreaterThanOrEqual(story.questions.count, 3, story.id)
            XCTAssertEqual(story.galleryAssetIDs.count, 4, story.id)
            XCTAssertFalse(story.imageScenario.targetVariants.isEmpty, story.id)
            XCTAssertFalse(story.imageScenario.interactions.isEmpty, story.id)
            XCTAssertFalse(story.imageScenario.expectedBehaviors.isEmpty, story.id)
            XCTAssertFalse(story.mechanism.isEmpty, story.id)
            XCTAssertFalse(story.distribution.isEmpty, story.id)
            XCTAssertFalse(story.debate.synthesis.isEmpty, story.id)

            for claim in story.claims {
                XCTAssertTrue(Set(claim.sourceIDs).isSubset(of: sourceIDs), claim.id)
            }
            for metric in story.metrics {
                XCTAssertFalse(metric.sourceIDs.isEmpty, metric.id)
                XCTAssertTrue(Set(metric.sourceIDs).isSubset(of: sourceIDs), metric.id)
            }
            for event in story.timeline {
                XCTAssertTrue(Set(event.sourceIDs).isSubset(of: sourceIDs), event.id)
            }

            for assetID in [story.heroAssetID] + story.galleryAssetIDs {
                referencedAssets.append(
                    try XCTUnwrap(WorkbenchRemoteAssetCatalog.asset(id: assetID), assetID)
                )
            }
        }

        XCTAssertEqual(referencedAssets.count, 160)
        XCTAssertEqual(Set(referencedAssets.map(\.id)).count, 160)
        XCTAssertGreaterThanOrEqual(Set(referencedAssets.map(\.author)).count, 50)
        XCTAssertEqual(
            Set(referencedAssets.map(\.sourceKind)),
            Set<WorkbenchMediaSourceKind>([.remote, .bundled])
        )
        XCTAssertTrue(document.featuredStoryIDs.allSatisfy(storyIDs.contains))
        XCTAssertTrue(document.caseStudyStoryIDs.allSatisfy(storyIDs.contains))
        XCTAssertTrue(
            document.glossary.flatMap(\.relatedStoryIDs).allSatisfy(storyIDs.contains)
        )
        XCTAssertTrue(document.sources.allSatisfy { $0.url.scheme == "https" })
        XCTAssertGreaterThanOrEqual(document.mediaPolicy.contextualTopics.count, 5)
        XCTAssertGreaterThanOrEqual(document.mediaPolicy.requiredChecks.count, 8)
        XCTAssertTrue(document.mediaPolicy.contextualTopics.contains("未成年人"))
        XCTAssertTrue(document.mediaPolicy.contextualTopics.contains("肉食与动物利用"))
        XCTAssertFalse(document.mediaPolicy.prohibitedUses.isEmpty)
        XCTAssertNotNil(
            ISO8601DateFormatter().date(from: document.reviewedAt + "T00:00:00Z")
        )
    }

    func testEcologicalAtlasSeparatesEvidenceTheoryDebateAndNormativeClaims_DEMO_PT_022() {
        let document = EcologicalAtlasDocument.current
        let sourceIDs = Set(document.sources.map(\.id))

        let normative = document.stories.filter { $0.epistemicStatus == .normativePosition }
        XCTAssertGreaterThanOrEqual(normative.count, 3)
        XCTAssertTrue(
            normative.allSatisfy { story in
                story.claims.contains { $0.sourceIDs.isEmpty }
                    && story.claims.contains { !$0.sourceIDs.isEmpty }
            }
        )

        let empirical = document.stories.filter { $0.epistemicStatus != .normativePosition }
        XCTAssertTrue(
            empirical.allSatisfy { story in
                story.claims.filter { !$0.sourceIDs.isEmpty }.count >= 2
            }
        )
        XCTAssertTrue(
            document.stories.flatMap(\.claims).allSatisfy {
                Set($0.sourceIDs).isSubset(of: sourceIDs)
            }
        )
        XCTAssertTrue(
            document.stories.allSatisfy {
                $0.debate.proposition != $0.debate.challenge
                    && $0.debate.synthesis != $0.debate.proposition
            }
        )
    }

    func testRealMediaCatalogIsLargeLicensedEthicallyReviewedAndReadable() throws {
        let assets = WorkbenchRemoteAssetCatalog.all
        let remote = WorkbenchRemoteAssetCatalog.remoteAssets
        let bundled = WorkbenchRemoteAssetCatalog.bundledAssets

        XCTAssertGreaterThanOrEqual(assets.count, 400)
        XCTAssertGreaterThanOrEqual(remote.count, 400)
        XCTAssertGreaterThanOrEqual(bundled.count, 16)
        XCTAssertEqual(Set(assets.map(\.id)).count, assets.count)
        XCTAssertTrue(
            WorkbenchRemoteAssetCategory.allCases.allSatisfy { category in
                assets.contains { $0.category == category }
            })

        let forbiddenPatterns = try [
            #"\b(beef|pork|chicken|duck|goose|lamb|veal|bacon|ham|sausage|burger|steak)\b"#,
            #"\b(crab|alimasag|shrimp|prawn|lobster|oyster|mussel|seafood|shellfish)\b"#,
            #"\b(hunting|fishing|slaughter|carcass|taxidermy|leather|wool|aquaculture)\b"#,
            #"\b(zoo|circus|captivity|vivisection|bullfight|rodeo)\b"#,
        ].map { try NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

        for asset in assets {
            XCTAssertFalse(asset.author.isEmpty, asset.id)
            XCTAssertFalse(asset.license.isEmpty, asset.id)
            XCTAssertFalse(asset.ethicalReview.isEmpty, asset.id)
            XCTAssertGreaterThan(asset.originalPixelWidth, 0, asset.id)
            XCTAssertGreaterThan(asset.originalPixelHeight, 0, asset.id)
            XCTAssertEqual(asset.sourcePageURL.scheme, "https", asset.id)
            XCTAssertEqual(asset.sourcePageURL.host, "commons.wikimedia.org", asset.id)
            XCTAssertEqual(asset.licenseURL.scheme, "https", asset.id)

            let reviewText = [
                asset.title, asset.subtitle, asset.searchTerms.joined(separator: " "),
            ]
            .joined(separator: " ")
            let range = NSRange(reviewText.startIndex..., in: reviewText)
            for expression in forbiddenPatterns {
                XCTAssertNil(expression.firstMatch(in: reviewText, range: range), asset.id)
            }

            switch asset.sourceKind {
            case .remote:
                let url = try XCTUnwrap(asset.remoteImageURL(width: 640), asset.id)
                XCTAssertEqual(url.scheme, "https", asset.id)
                XCTAssertEqual(url.host, "commons.wikimedia.org", asset.id)
            case .bundled:
                let url = try XCTUnwrap(asset.bundledURL, asset.id)
                XCTAssertTrue(url.isFileURL, asset.id)
                XCTAssertGreaterThan(try Data(contentsOf: url).count, 0, asset.id)
            }
        }

        XCTAssertEqual(
            Set(WorkbenchRemoteAssetCatalog.allowedOriginURLs.compactMap(\.host)),
            ["commons.wikimedia.org", "upload.wikimedia.org"]
        )
    }

    func testRemoteAssetIdentityUsesStableAssetAndWidthBucket() throws {
        let asset = WorkbenchRemoteAssetCatalog.featured
        let compactTarget = try TargetPixels(width: 640, height: 360)
        let largerTarget = try TargetPixels(width: 900, height: 600)

        let first = try WorkbenchRequestFactory.makeRemoteAssetRequest(
            asset: asset,
            target: compactTarget,
            configuration: .defaults
        )
        let repeated = try WorkbenchRequestFactory.makeRemoteAssetRequest(
            asset: asset,
            target: compactTarget,
            configuration: .defaults
        )
        let larger = try WorkbenchRequestFactory.makeRemoteAssetRequest(
            asset: asset,
            target: largerTarget,
            configuration: .defaults
        )
        let deterministic = try WorkbenchRequestFactory.makeRemoteAssetRequest(
            asset: asset,
            target: compactTarget,
            configuration: .deterministicDefaults
        )

        XCTAssertEqual(first.fetchBaseKey, repeated.fetchBaseKey)
        XCTAssertEqual(first.url, repeated.url)
        XCTAssertNotEqual(first.fetchBaseKey, larger.fetchBaseKey)
        XCTAssertEqual(first.url.host, "commons.wikimedia.org")
        XCTAssertEqual(deterministic.url.host, DemoURLProtocol.host)
        XCTAssertNotEqual(first.fetchBaseKey, deterministic.fetchBaseKey)
    }

    func testBundledAssetNeverEntersNetworkRequestFactory() throws {
        let asset = try XCTUnwrap(WorkbenchRemoteAssetCatalog.bundledAssets.first)
        XCTAssertThrowsError(
            try WorkbenchRequestFactory.makeRemoteAssetRequest(
                asset: asset,
                target: TargetPixels(width: 320, height: 240),
                configuration: .defaults
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkbenchRequestFactoryError,
                .bundledAssetDoesNotUseNetworkPipeline
            )
        }
    }

    func testFeedUsesHundredsOfRealAssetsInteractivelyAndStableSyntheticOriginOffline() throws {
        let items = WorkbenchFeedItem.makeItems(
            count: 600,
            uniqueAssetCount: 300,
            delayed: true
        )
        let item = try XCTUnwrap(items.first)
        let target = try TargetPixels(width: 320, height: 240)

        XCTAssertEqual(items.count, 600)
        XCTAssertEqual(Set(items.map(\.assetID)).count, 300)

        let interactive = try WorkbenchRequestFactory.makeFeedRequest(
            item: item,
            target: target,
            configuration: .defaults,
            identityRevision: "feed-session"
        )
        let deterministic = try WorkbenchRequestFactory.makeFeedRequest(
            item: item,
            target: target,
            configuration: .deterministicDefaults,
            identityRevision: "feed-session"
        )

        XCTAssertEqual(interactive.url.host, "commons.wikimedia.org")
        XCTAssertEqual(deterministic.url.host, DemoURLProtocol.host)
        XCTAssertEqual(
            item.expectedVariantTitle,
            WorkbenchRemoteAssetCatalog.remoteAsset(forStableIndex: 0).title
        )
    }

    func testConfigurationRoundTripPreservesExperimentControls() throws {
        var configuration = WorkbenchConfiguration.defaults
        configuration.externalNetworkingEnabled = true
        configuration.burstCount = 17
        configuration.networkMode = .wifiOnly
        configuration.cacheMode = .onlyIfCached
        configuration.varyLanguage = .chinese
        let data = try JSONEncoder().encode(configuration)
        XCTAssertEqual(
            try JSONDecoder().decode(WorkbenchConfiguration.self, from: data), configuration)
    }

    func testCustomURLIsSessionOnlyAndNeverPersisted() throws {
        var configuration = WorkbenchConfiguration.defaults
        configuration.customURL =
            "https://private.example.test/image.png?temporary-signature=secret"

        let data = try JSONEncoder().encode(configuration)
        let serialized = try XCTUnwrap(String(data: data, encoding: .utf8))
        let decoded = try JSONDecoder().decode(WorkbenchConfiguration.self, from: data)

        XCTAssertFalse(serialized.contains("private.example.test"))
        XCTAssertFalse(serialized.contains("temporary-signature"))
        XCTAssertFalse(serialized.contains("secret"))
        XCTAssertEqual(decoded.customURL, WorkbenchConfiguration.defaults.customURL)
        XCTAssertEqual(decoded.burstCount, configuration.burstCount)
    }

    func testDeterministicScenarioBuildsWithoutPublicNetworking() throws {
        let scenario = try XCTUnwrap(
            WorkbenchScenarioCatalog.all.first(where: { $0.id == "cacheable-image" })
        )
        let request = try WorkbenchRequestFactory.makeRequest(
            scenario: scenario,
            target: TargetPixels(width: 320, height: 240),
            configuration: .defaults
        )
        XCTAssertEqual(request.url.host, DemoURLProtocol.host)
        XCTAssertEqual(request.namespace, workbenchPublicNamespace)
    }

    func testInteractiveDefaultsUseRealNetworkWhileDeterministicModeStaysOffline_DEMO_PT_005()
        throws
    {
        XCTAssertTrue(WorkbenchConfiguration.defaults.externalNetworkingEnabled)
        XCTAssertFalse(WorkbenchConfiguration.deterministicDefaults.externalNetworkingEnabled)

        let scenario = try XCTUnwrap(
            WorkbenchScenarioCatalog.all.first(where: { $0.id == "live-httpbin-png" })
        )
        let request = try WorkbenchRequestFactory.makeRequest(
            scenario: scenario,
            target: TargetPixels(width: 320, height: 240),
            configuration: .defaults
        )
        XCTAssertEqual(request.url.host, "httpbin.org")

        XCTAssertThrowsError(
            try WorkbenchRequestFactory.makeRequest(
                scenario: scenario,
                target: TargetPixels(width: 320, height: 240),
                configuration: .deterministicDefaults
            )
        ) { error in
            XCTAssertEqual(error as? WorkbenchRequestFactoryError, .externalNetworkingDisabled)
        }
    }

    func testLiveScenarioCanBeDisabledForOfflineDebugging() throws {
        let scenario = try XCTUnwrap(
            WorkbenchScenarioCatalog.all.first(where: { $0.id == "live-httpbin-png" })
        )
        var configuration = WorkbenchConfiguration.defaults
        configuration.externalNetworkingEnabled = false
        XCTAssertThrowsError(
            try WorkbenchRequestFactory.makeRequest(
                scenario: scenario,
                target: TargetPixels(width: 320, height: 240),
                configuration: configuration
            )
        ) { error in
            XCTAssertEqual(error as? WorkbenchRequestFactoryError, .externalNetworkingDisabled)
        }
    }

    func testCustomURLUsesConservativeURLIdentity() throws {
        let scenario = try XCTUnwrap(
            WorkbenchScenarioCatalog.all.first(where: { $0.id == "live-custom" })
        )
        var firstConfiguration = WorkbenchConfiguration.defaults
        firstConfiguration.externalNetworkingEnabled = true
        firstConfiguration.customURL = "https://example.test/first.png?version=1"
        var secondConfiguration = firstConfiguration
        secondConfiguration.customURL = "https://example.test/second.png?version=2"

        let first = try WorkbenchRequestFactory.makeRequest(
            scenario: scenario,
            target: TargetPixels(width: 320, height: 240),
            configuration: firstConfiguration
        )
        let second = try WorkbenchRequestFactory.makeRequest(
            scenario: scenario,
            target: TargetPixels(width: 320, height: 240),
            configuration: secondConfiguration
        )

        XCTAssertNotEqual(first.fetchBaseKey, second.fetchBaseKey)
    }

    func testAuthenticatedScenarioCarriesExplicitSecurityContext() throws {
        let scenario = try XCTUnwrap(
            WorkbenchScenarioCatalog.all.first(where: { $0.id == "authenticated-private" })
        )
        let request = try WorkbenchRequestFactory.makeRequest(
            scenario: scenario,
            target: TargetPixels(width: 320, height: 240),
            configuration: .defaults
        )
        XCTAssertEqual(request.namespace, workbenchPrivateNamespace)
        XCTAssertEqual(request.authorizationContext, workbenchPrivateAuthorizationContext)
        XCTAssertEqual(request.headers["authorization"], "Bearer workbench-token-a")
        XCTAssertEqual(request.credentialGeneration, CredentialGeneration(1))
    }

    func testDefaultsFavorAspectSafePresentationAndStableCustomURL() throws {
        XCTAssertEqual(WorkbenchConfiguration.defaults.contentMode, .fit)
        let custom = try XCTUnwrap(URL(string: WorkbenchConfiguration.defaults.customURL))
        XCTAssertEqual(custom.scheme, "https")
        XCTAssertNotEqual(custom.host, "httpbin.org")
    }

    func testConfigurationClassifiesRequestAndPipelineSettingsIndependently() {
        let baseline = WorkbenchConfiguration.defaults

        var requestOnly = baseline
        requestOnly.transitionDuration = 0.75
        requestOnly.varyLanguage = .chinese
        requestOnly.credentialGeneration += 1
        XCTAssertEqual(requestOnly.pipelineSettings, baseline.pipelineSettings)
        XCTAssertNotEqual(requestOnly.requestSettings, baseline.requestSettings)

        var pipelineChange = baseline
        pipelineChange.maximumConcurrentFetches += 1
        XCTAssertNotEqual(pipelineChange.pipelineSettings, baseline.pipelineSettings)

        var deterministicBaseline = WorkbenchConfiguration.deterministicDefaults
        var dormantCustomURL = deterministicBaseline
        dormantCustomURL.customURL = "https://example.test/private.png?token=secret"
        XCTAssertEqual(dormantCustomURL.pipelineSettings, deterministicBaseline.pipelineSettings)
        deterministicBaseline.externalNetworkingEnabled = true
        dormantCustomURL.externalNetworkingEnabled = true
        XCTAssertNotEqual(dormantCustomURL.pipelineSettings, baseline.pipelineSettings)
    }

    func testConfigurationNormalizationMaintainsCrossFieldInvariants() {
        var configuration = WorkbenchConfiguration.defaults
        configuration.requestTimeoutSeconds = 90
        configuration.resourceTimeoutSeconds = 10
        configuration.encodedSoftLimitMegabytes = 16
        configuration.encodedBlobLimitMegabytes = 128
        configuration.burstCount = 100
        configuration.transitionDuration = .infinity

        let normalized = configuration.normalized()

        XCTAssertEqual(normalized.resourceTimeoutSeconds, 90)
        XCTAssertEqual(normalized.encodedBlobLimitMegabytes, 16)
        XCTAssertEqual(normalized.burstCount, 32)
        XCTAssertEqual(
            normalized.transitionDuration,
            WorkbenchConfiguration.defaults.transitionDuration
        )
    }

    func testExternalScenariosAreNotMisrepresentedAsDeterministicSuccess() {
        let external = WorkbenchScenarioCatalog.scenarios(in: .live)
        XCTAssertFalse(external.isEmpty)
        XCTAssertTrue(
            external.allSatisfy { $0.expectedOutcome == .environmentDependent }
        )
    }

    func testLabCatalogHasStableUniqueIdentifiersAndCompleteScenarioReferences() {
        let identifiers = WorkbenchLabCatalog.all.map(\.id)
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
        XCTAssertTrue(
            WorkbenchLabCategory.allCases.allSatisfy {
                !WorkbenchLabCatalog.labs(in: $0).isEmpty
            })
        XCTAssertTrue(WorkbenchLabCatalog.all.allSatisfy { !$0.scenarios.isEmpty })

        let knownScenarioIDs = Set(WorkbenchScenarioCatalog.all.map(\.id))
        let referencedScenarioIDs = Set(WorkbenchLabCatalog.all.flatMap(\.scenarioIDs))
        XCTAssertEqual(referencedScenarioIDs, knownScenarioIDs)
    }

    func testAuthenticationLabUsesDistinctSecurityIdentitiesForAccountsAAndB() throws {
        let accountA = try XCTUnwrap(WorkbenchScenarioCatalog.scenario(id: "authenticated-private"))
        let accountB = try XCTUnwrap(
            WorkbenchScenarioCatalog.scenario(id: "authenticated-account-b"))
        let invalid = try XCTUnwrap(WorkbenchScenarioCatalog.scenario(id: "authenticated-invalid"))
        let target = try TargetPixels(width: 320, height: 240)

        let requestA = try WorkbenchRequestFactory.makeRequest(
            scenario: accountA, target: target, configuration: .defaults
        )
        let requestB = try WorkbenchRequestFactory.makeRequest(
            scenario: accountB, target: target, configuration: .defaults
        )
        let invalidRequest = try WorkbenchRequestFactory.makeRequest(
            scenario: invalid, target: target, configuration: .defaults
        )

        XCTAssertEqual(requestA.url, requestB.url)
        XCTAssertNotEqual(requestA.namespace, requestB.namespace)
        XCTAssertNotEqual(requestA.authorizationContext, requestB.authorizationContext)
        XCTAssertNotEqual(requestA.headers["authorization"], requestB.headers["authorization"])
        XCTAssertEqual(invalidRequest.namespace, requestA.namespace)
        XCTAssertNotEqual(
            invalidRequest.headers["authorization"], requestA.headers["authorization"])
        XCTAssertNotEqual(requestA.fetchBaseKey, requestB.fetchBaseKey)
    }

    func testFeedCatalogProvidesListAndGridStressScenario() throws {
        let scenario = try XCTUnwrap(WorkbenchScenarioCatalog.scenario(id: "scrolling-feed-lab"))
        guard case .feed(let initialLayout) = scenario.presentation else {
            return XCTFail("Feed scenario must use the dedicated stress presentation")
        }
        XCTAssertEqual(initialLayout, .list)
        XCTAssertEqual(Set(WorkbenchFeedLayout.allCases), [.list, .grid])

        let items = WorkbenchFeedItem.makeItems(
            count: 120,
            uniqueAssetCount: 16,
            delayed: true
        )
        XCTAssertEqual(items.count, 120)
        XCTAssertEqual(Set(items.map(\.assetID)).count, 16)
        XCTAssertTrue(items.contains { $0.delayMilliseconds > 0 })
    }

    func testCustomURLRejectsCleartextAndEmbeddedCredentials() throws {
        let scenario = try XCTUnwrap(WorkbenchScenarioCatalog.scenario(id: "live-custom"))
        for invalid in [
            "http://example.test/image.png",
            "https://user:password@example.test/image.png",
        ] {
            var configuration = WorkbenchConfiguration.defaults
            configuration.externalNetworkingEnabled = true
            configuration.customURL = invalid
            XCTAssertThrowsError(
                try WorkbenchRequestFactory.makeRequest(
                    scenario: scenario,
                    target: TargetPixels(width: 320, height: 240),
                    configuration: configuration
                )
            ) { error in
                XCTAssertEqual(error as? WorkbenchRequestFactoryError, .invalidCustomURL)
            }
        }
    }

    func testInvalidPresetURLFailsClosedAfterExplicitNetworkOptIn() throws {
        let scenario = WorkbenchScenario(
            id: "invalid-live-preset",
            title: "Invalid live preset",
            summary: "Test fixture",
            category: .live,
            behavior: .livePreset("not a valid URL"),
            expectedOutcome: .environmentDependent,
            supportsVisualPreview: false,
            tags: []
        )
        var configuration = WorkbenchConfiguration.defaults
        configuration.externalNetworkingEnabled = true

        XCTAssertThrowsError(
            try WorkbenchRequestFactory.makeRequest(
                scenario: scenario,
                target: TargetPixels(width: 320, height: 240),
                configuration: configuration
            )
        ) { error in
            XCTAssertEqual(error as? WorkbenchRequestFactoryError, .invalidScenarioURL)
        }
    }

    @MainActor
    func testEvidenceBundleMinimizesCorrelationAndDeviceFingerprint_DEMO_PT_031() throws {
        let runID = try XCTUnwrap(
            UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        )
        let performanceID = try XCTUnwrap(
            UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        )
        let record = WorkbenchRunRecord(
            id: runID,
            scenarioID: "cacheable-image",
            scenarioTitle: "目标像素加载",
            startedAt: Date(timeIntervalSince1970: 1_000),
            finishedAt: Date(timeIntervalSince1970: 1_001),
            requestCount: 1,
            completedCount: 1,
            state: .success,
            evidence: WorkbenchRunEvidence(
                originRequests: 1,
                eventCounts: [.fetchStarted: 1, .decodeCompleted: 1],
                statusCounts: [200: 1],
                finalReasonCode: nil,
                targetWidth: 800,
                targetHeight: 600
            )
        )
        let performance = WorkbenchPerformanceSnapshot(
            id: performanceID,
            workloadID: "W1-fast-reverse-burst",
            host: "swiftUI",
            layout: "list",
            itemCount: 120,
            uniqueAssetCount: 16,
            startedAt: Date(timeIntervalSince1970: 2_000),
            finishedAt: Date(timeIntervalSince1970: 2_001),
            frameSampleCount: 60,
            hitchCount: 2,
            maximumFrameIntervalMilliseconds: 41.5,
            initialPhysicalFootprintBytes: 100_000_000,
            peakPhysicalFootprintBytes: 112_000_000,
            finalPhysicalFootprintBytes: 108_000_000
        )
        let bundle = WorkbenchEvidenceBundle.make(
            configuration: .defaults,
            storageGenerationIdentifier: "generation-test",
            runs: [record],
            diagnostics: [
                RecordedDiagnosticEvent(
                    sequence: 1,
                    elapsedNanoseconds: 10,
                    event: DiagnosticEvent(
                        kind: .fetchStarted,
                        keyDigest: "sensitive-correlation",
                        targetWidth: 400,
                        targetHeight: 300
                    )
                )
            ],
            originRequestCounts: ["/image/cacheable": 1],
            performanceSnapshots: [performance],
            evidenceNonce: try XCTUnwrap(
                UUID(uuidString: "11111111-1111-1111-1111-111111111111")
            ),
            generatedAt: Date(timeIntervalSince1970: 7_323)
        )
        let secondBundle = WorkbenchEvidenceBundle.make(
            configuration: .defaults,
            storageGenerationIdentifier: "generation-test",
            runs: [],
            diagnostics: [],
            originRequestCounts: [:],
            performanceSnapshots: [],
            evidenceNonce: try XCTUnwrap(
                UUID(uuidString: "22222222-2222-2222-2222-222222222222")
            ),
            generatedAt: Date(timeIntervalSince1970: 7_323)
        )
        let data = try WorkbenchEvidenceBundle.encoded(bundle)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(bundle.schemaVersion, WorkbenchEvidenceBundle.schemaVersion)
        XCTAssertEqual(bundle.generatedAt, Date(timeIntervalSince1970: 7_200))
        XCTAssertEqual(bundle.runs.first?.sequence, 1)
        XCTAssertEqual(bundle.performanceSnapshots.first?.sequence, 1)
        XCTAssertEqual(bundle.configurationFingerprint.count, 64)
        XCTAssertEqual(bundle.storageGenerationToken?.count, 16)
        XCTAssertNotEqual(bundle.storageGenerationToken, secondBundle.storageGenerationToken)
        XCTAssertFalse(json.contains("generation-test"))
        XCTAssertFalse(json.contains("storageGenerationIdentifier"))
        XCTAssertTrue(json.contains("cacheable-image"))
        XCTAssertTrue(json.contains("W1-fast-reverse-burst"))
        XCTAssertEqual(bundle.performanceSnapshots.first?.peakFootprintDeltaBytes, 12_000_000)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(json.contains("workbench-token"))
        XCTAssertFalse(json.contains("simulatorUDID"))
        XCTAssertFalse(json.contains("SIMULATOR_UDID"))
        XCTAssertFalse(json.contains("SIMULATOR_MODEL_IDENTIFIER"))
        XCTAssertFalse(json.contains("localeIdentifier"))
        XCTAssertFalse(json.contains("timeZoneIdentifier"))
        XCTAssertFalse(json.contains("modelIdentifier"))
        XCTAssertFalse(json.contains("startedAt"))
        XCTAssertFalse(json.contains("finishedAt"))
        XCTAssertFalse(json.contains(runID.uuidString.lowercased()))
        XCTAssertFalse(json.contains(performanceID.uuidString.lowercased()))
        XCTAssertFalse(json.contains(TimeZone.current.identifier))
        XCTAssertFalse(json.contains("sensitive-correlation"))
        XCTAssertFalse(json.contains("keyDigest"))
    }

    func testStorageMaintenancePrunesOldProfilesWithoutFollowingSymlinks_DEMO_PT_032()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoveaWorkbenchPrune-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let interactive = root.appendingPathComponent("interactive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: interactive,
            withIntermediateDirectories: true
        )

        let current = interactive.appendingPathComponent("store-v2-current", isDirectory: true)
        let newest = interactive.appendingPathComponent("store-v2-newest", isDirectory: true)
        let old = interactive.appendingPathComponent("store-v2-old", isDirectory: true)
        let unrelated = interactive.appendingPathComponent("notes", isDirectory: true)
        for directory in [current, newest, old, unrelated] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: current.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 300)],
            ofItemAtPath: newest.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: old.path
        )
        let symlink = interactive.appendingPathComponent("store-v2-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: old)

        let result = await WorkbenchStorageMaintenance.pruneObsoleteStorageProfiles(
            cacheRoot: root,
            preserving: [current.lastPathComponent],
            maximumRetained: 1
        )

        XCTAssertEqual(result.removedProfileCount, 1)
        XCTAssertEqual(result.failedOperationCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path),
            old.path
        )
    }

    func testStorageMaintenanceTreatsMissingRootAsEmpty_DEMO_PT_033() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoveaWorkbenchMissing-\(UUID().uuidString)", isDirectory: true)
        let result = await WorkbenchStorageMaintenance.pruneObsoleteStorageProfiles(
            cacheRoot: root,
            preserving: [],
            maximumRetained: 0
        )
        XCTAssertEqual(
            result,
            WorkbenchStoragePruneResult(
                removedProfileCount: 0,
                failedOperationCount: 0
            )
        )
    }

    @MainActor
    func testRequestOnlyApplyPreservesPipelineWhilePipelineSettingsRebuild() async throws {
        let suiteName = "FoveaWorkbenchApplyTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoveaWorkbenchApply-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = WorkbenchAppModel(cacheRoot: root, configurationStore: store)
        await model.start()
        let initialPipelineID = try XCTUnwrap(model.pipeline?.id)

        model.draftConfiguration.transitionDuration = 0.65
        XCTAssertTrue(model.hasUnappliedConfiguration)
        XCTAssertFalse(model.requiresPipelineRebuild)
        await model.applyConfiguration()
        XCTAssertEqual(model.pipeline?.id, initialPipelineID)
        XCTAssertEqual(model.activeConfiguration.transitionDuration, 0.65)

        model.draftConfiguration.maximumConcurrentFetches += 1
        XCTAssertTrue(model.requiresPipelineRebuild)
        await model.applyConfiguration()
        XCTAssertNotEqual(model.pipeline?.id, initialPipelineID)
        XCTAssertEqual(model.runtimeState, .ready)
    }

    @MainActor
    func testPipelineRebuildCancelsAndDrainsEvidenceRuntime_DEMO_PT_034() async throws {
        let suiteName = "FoveaWorkbenchDrainRuns.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoveaWorkbenchDrain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = WorkbenchAppModel(cacheRoot: root, configurationStore: store)
        await model.start()
        let scenario = try XCTUnwrap(WorkbenchScenarioCatalog.scenario(id: "slow-placeholder"))
        let runID = try XCTUnwrap(model.run(scenario, count: 8))
        XCTAssertEqual(model.pendingRunTaskCount, 1)

        model.draftConfiguration.maximumConcurrentFetches += 1
        await model.applyConfiguration()

        XCTAssertEqual(model.pendingRunTaskCount, 0)
        XCTAssertEqual(model.activeRunCount, 0)
        XCTAssertEqual(model.runs.first(where: { $0.id == runID })?.state, .cancelled)
        XCTAssertEqual(model.runtimeState, .ready)
    }

    @MainActor
    func testEvidenceRunsAreSerializedInsteadOfCrossContaminated() async throws {
        let suiteName = "FoveaWorkbenchSerializedRuns.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FoveaWorkbenchSerialized-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = WorkbenchAppModel(cacheRoot: root, configurationStore: store)
        await model.start()
        let slow = try XCTUnwrap(WorkbenchScenarioCatalog.scenario(id: "slow-placeholder"))
        let cacheable = try XCTUnwrap(WorkbenchScenarioCatalog.scenario(id: "cacheable-image"))
        let first = try XCTUnwrap(model.run(slow, count: 8))
        XCTAssertNil(model.run(cacheable))
        XCTAssertNotNil(model.presentedErrorMessage)
        model.dismissPresentedError()
        model.cancelRun(first)
    }

    @MainActor
    func testAppModelDirectRunPublishesCompletionWithoutRetainingFinishedTask() async throws {
        let suiteName = "FoveaWorkbenchTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoveaWorkbenchModel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = WorkbenchAppModel(cacheRoot: root, configurationStore: store)
        await model.start()
        XCTAssertTrue(model.isReady)
        let scenario = try XCTUnwrap(WorkbenchScenarioCatalog.scenario(id: "cacheable-image"))
        let interactiveRequest = try WorkbenchRequestFactory.makeRequest(
            scenario: scenario,
            target: TargetPixels(width: 400, height: 300),
            configuration: model.activeConfiguration,
            identityRevision: "interactive-warmup"
        )
        _ = try await XCTUnwrap(model.pipeline).image(for: interactiveRequest)
        let runID = try XCTUnwrap(model.run(scenario, count: 8))

        try await waitUntilOnMainActor("直接证据运行完成") {
            model.latestRun(for: scenario.id)?.state != .running
        }

        let run = try XCTUnwrap(model.runs.first { $0.id == runID })
        XCTAssertEqual(run.state, .success)
        XCTAssertEqual(run.completedCount, 8)
        XCTAssertEqual(run.evidence.originRequests, 1)
        XCTAssertEqual(run.evidence.eventCounts[.fetchStarted], 1)
        XCTAssertEqual(run.evidence.targetWidth, 400)
        XCTAssertEqual(run.evidence.targetHeight, 300)
        XCTAssertEqual(model.activeRunCount, 0)
    }

    @MainActor
    func testCancelledRunCannotBeOverwrittenByLateCompletion() async throws {
        let suiteName = "FoveaWorkbenchCancellationTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoveaWorkbenchCancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = WorkbenchAppModel(cacheRoot: root, configurationStore: store)
        await model.start()
        let scenario = try XCTUnwrap(WorkbenchScenarioCatalog.scenario(id: "slow-placeholder"))
        let runID = try XCTUnwrap(model.run(scenario, count: 8))

        model.cancelRun(runID)
        XCTAssertEqual(model.runs.first { $0.id == runID }?.state, .cancelled)

        try await waitUntilOnMainActor("取消后的底层证据任务完成收敛") {
            model.pendingRunTaskCount == 0
        }
        XCTAssertEqual(model.runs.first { $0.id == runID }?.state, .cancelled)
        XCTAssertEqual(model.activeRunCount, 0)
    }

}

private actor ControlledPrefetchLoader {
    private var invocationCount = 0
    private var continuations: [Int: CheckedContinuation<Bool, Never>] = [:]

    func load() async -> Bool {
        let invocation = invocationCount
        invocationCount += 1
        return await withCheckedContinuation { continuation in
            continuations[invocation] = continuation
        }
    }

    func waitForInvocationCount(_ expected: Int) async {
        while invocationCount < expected { await Task.yield() }
    }

    func resolve(invocation: Int, result: Bool) {
        continuations.removeValue(forKey: invocation)?.resume(returning: result)
    }
}

private actor PrefetchLoadCounter {
    private(set) var count = 0

    func recordSuccess() -> Bool {
        count += 1
        return true
    }
}

@MainActor
private func settleMainActorTasks() async {
    for _ in 0..<8 { await Task.yield() }
}
