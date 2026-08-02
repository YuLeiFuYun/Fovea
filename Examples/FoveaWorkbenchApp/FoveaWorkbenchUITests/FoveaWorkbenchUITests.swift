import XCTest

@MainActor
final class FoveaWorkbenchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchShowsEcologicalAtlasAndOpensFeaturedEditorialStory_DEMO_PT_023() {
        let app = launchApp()

        XCTAssertTrue(app.navigationBars["生态图谱"].exists)
        XCTAssertTrue(element("ecology.root", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("ecology.hero", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("ecology.navigation-deck", in: app).waitForExistence(timeout: 5))

        let featured = element("ecology.featured.climate-gap", in: app)
        scrollUntilVisible(featured, in: app)
        XCTAssertTrue(featured.waitForExistence(timeout: 5))
        featured.tap()

        XCTAssertTrue(element("ecology.story.climate-gap", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(
            element("ecology.media-surface.editorial.climate-gap", in: app)
                .waitForExistence(timeout: 8)
        )
    }

    func testEcologicalAtlasOpensLibraryCasesMapGlossaryAndMethodology_DEMO_PT_024() {
        let app = launchApp()
        for (identifier, destination) in [
            ("ecology.open-library", "ecology.library.root"),
            ("ecology.open-cases", "ecology.cases.root"),
            ("ecology.open-map", "ecology.map.root"),
            ("ecology.open-glossary", "ecology.glossary.root"),
        ] {
            let entry = element(identifier, in: app)
            scrollUntilVisible(entry, in: app)
            XCTAssertTrue(entry.waitForExistence(timeout: 5), identifier)
            entry.tap()
            XCTAssertTrue(element(destination, in: app).waitForExistence(timeout: 8), destination)
            navigateBack(in: app)
        }

        let methodology = app.buttons["ecology.methodology"]
        XCTAssertTrue(methodology.waitForExistence(timeout: 5))
        methodology.tap()
        XCTAssertTrue(element("ecology.methodology.root", in: app).waitForExistence(timeout: 8))
    }

    func testEcologicalSearchReachesEveryMediaSurface_DEMO_PT_025() {
        let representatives = [
            ("climate-gap", "温升数字", "editorial"),
            ("biodiversity-web", "生物多样性", "mosaic"),
            ("one-health", "大流行病预防", "timeline"),
            ("energy-rebound", "效率为什么", "comparison"),
            ("mobility-city", "城市形态", "atlas"),
            ("ai-data-centres", "AI 不是", "dossier"),
            ("transition-minerals", "能源转型也有矿山", "fieldNotes"),
            ("animal-ethics", "动物不是碳核算", "immersive"),
        ]

        for (storyID, query, layout) in representatives {
            let app = launchApp()
            openEcologicalStory(storyID, query: query, in: app)
            XCTAssertTrue(
                element("ecology.media-surface.\(layout).\(storyID)", in: app)
                    .waitForExistence(timeout: 10),
                "Missing layout \(layout) for \(storyID)"
            )
            app.terminate()
        }
    }

    private static let ecologicalStoryMediaMatrix: [(id: String, layout: String)] = [
        ("climate-gap", "editorial"),
        ("planetary-boundaries", "atlas"),
        ("biodiversity-web", "mosaic"),
        ("water-ocean-cryosphere", "timeline"),
        ("material-throughput", "dossier"),
        ("energy-rebound", "comparison"),
        ("pollution-plastics", "atlas"),
        ("transition-minerals", "fieldNotes"),
        ("food-land", "mosaic"),
        ("animal-ethics", "immersive"),
        ("one-health", "timeline"),
        ("soil-pollinators", "fieldNotes"),
        ("historical-responsibility", "dossier"),
        ("unequal-exchange", "comparison"),
        ("colonial-extractivism", "timeline"),
        ("adaptation-debt", "dossier"),
        ("military-environment", "atlas"),
        ("conflict-toxic-legacy", "immersive"),
        ("energy-security", "comparison"),
        ("borders-displacement", "fieldNotes"),
        ("fast-fashion", "mosaic"),
        ("mobility-city", "atlas"),
        ("housing-cooling", "comparison"),
        ("ai-data-centres", "dossier"),
        ("green-growth", "comparison"),
        ("degrowth", "editorial"),
        ("ecosocialism", "immersive"),
        ("rights-of-nature", "fieldNotes"),
        ("transformative-change", "timeline"),
        ("just-transition", "dossier"),
        ("public-provisioning", "mosaic"),
        ("action-scales", "atlas"),
    ]

    // 每段至多启动八个 App 实例。完整验证器会把五个矩阵测试放入独立
    // Xcode shard，并在 shard 之间重启模拟器；这保留全部断言，同时隔离
    // Simulator AXBinaryMonitor 在高频应用生命周期下的系统级崩溃域。
    func testEveryEcologicalStoryBuildsItsDeclaredMediaSurface_DEMO_PT_028() {
        verifyEcologicalStories(in: 0..<8)
    }

    func testEveryEcologicalStoryBuildsItsDeclaredMediaSurfacePart2() {
        verifyEcologicalStories(in: 8..<16)
    }

    func testEveryEcologicalStoryBuildsItsDeclaredMediaSurfacePart3() {
        verifyEcologicalStories(in: 16..<24)
    }

    func testEveryEcologicalStoryBuildsItsDeclaredMediaSurfacePart4() {
        verifyEcologicalStories(in: 24..<32)
    }

    func testFastFashionMediaSurfaceRetainsFiveIdentities() {
        verifyEcologicalStory((id: "fast-fashion", layout: "mosaic"))
    }

    private func verifyEcologicalStories(in range: Range<Int>) {
        XCTAssertTrue(
            range.clamped(to: Self.ecologicalStoryMediaMatrix.indices) == range,
            "Ecological story matrix range is out of bounds"
        )
        for story in Self.ecologicalStoryMediaMatrix[range] {
            verifyEcologicalStory(story)
        }
    }

    private func verifyEcologicalStory(_ story: (id: String, layout: String)) {
        let app = launchStoryApp(story.id)
        defer { app.terminate() }

        let surface = element(
            "ecology.media-surface.\(story.layout).\(story.id)",
            in: app
        )
        XCTAssertTrue(
            surface.waitForExistence(timeout: 8),
            "Missing media surface for \(story.id)"
        )
        let imageCount = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "images:5"),
            object: surface
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [imageCount], timeout: 8),
            .completed,
            "Incorrect media identity count for \(story.id)"
        )
    }

    func testEcologicalStoryExercisesFitFillReloadPurgeAndContract_DEMO_PT_026() {
        let app = launchStoryApp("climate-gap", contractFirst: true)

        let mode = element("ecology.content-mode.climate-gap", in: app)
        scrollUntilVisible(mode, in: app)
        XCTAssertTrue(mode.waitForExistence(timeout: 8))
        let fit = app.buttons["完整"]
        if fit.exists { fit.tap() }

        let reload = element("ecology.reload.climate-gap", in: app)
        scrollUntilVisible(reload, in: app)
        XCTAssertTrue(reload.waitForExistence(timeout: 8))
        reload.tap()
        assertLabel(
            "全部专题图片已使用新身份重建",
            identifier: "ecology.image-action-status.climate-gap",
            in: app
        )

        let purge = element("ecology.purge.climate-gap", in: app)
        scrollUntilVisible(purge, in: app)
        waitUntilEnabled(purge, timeout: 30)
        purge.tap()
        assertLabel(
            "内存图片已清空并重新加载",
            identifier: "ecology.image-action-status.climate-gap",
            in: app,
            timeout: 15
        )

        let contract = element("ecology.contract.climate-gap", in: app)
        scrollUntilVisible(contract, in: app)
        XCTAssertTrue(contract.waitForExistence(timeout: 8))
        contract.tap()
        assertLabel(
            "图片契约已展开",
            identifier: "ecology.image-action-status.climate-gap",
            in: app
        )

        XCTAssertTrue(app.staticTexts["目标变体"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["交互脚本"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["预期行为"].waitForExistence(timeout: 5))
    }

    func testScenarioStudioExposesSourceLayoutPrefetchAndCacheControls() {
        let app = launchStudioApp()

        XCTAssertTrue(element("studio.root", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("studio.pattern", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("studio.source", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("studio.surface", in: app).waitForExistence(timeout: 8))

        let local = app.buttons["本地"]
        XCTAssertTrue(local.waitForExistence(timeout: 5))
        local.tap()
        XCTAssertTrue(element("studio.social.image.0", in: app).waitForExistence(timeout: 8))

        for title in ["重新显示", "清内存再看", "预取当前内容", "清空证据"] {
            let button = app.buttons[title]
            scrollUntilVisible(button, in: app)
            XCTAssertTrue(button.waitForExistence(timeout: 5), title)
        }
    }

    func testProductPatternsUseDistinctHostLayouts() {
        let app = launchApp()
        openLab("product-patterns", in: app)

        XCTAssertTrue(element("product.hero", in: app).waitForExistence(timeout: 5))
        scrollUntilVisible(element("product.avatar", in: app), in: app)
        XCTAssertTrue(element("product.avatar", in: app).exists)
        XCTAssertTrue(element("product.chat-thumbnail", in: app).exists)
        scrollUntilVisible(element("product.grid.0", in: app), in: app)
        XCTAssertTrue(element("product.grid.0", in: app).exists)

        let rebuild = app.buttons["product.rebuild"]
        scrollUntilVisible(rebuild, in: app)
        rebuild.tap()
        assertLabel("产品图片视图已重新构建", identifier: "product.action-status", in: app)

        let purge = app.buttons["product.purge"]
        scrollUntilVisible(purge, in: app)
        waitUntilEnabled(purge)
        purge.tap()
        assertLabel("内存图片已清空并重新加载", identifier: "product.action-status", in: app)
    }

    func testSingleImageLabPublishesExpectedActualEvidence() {
        let app = launchApp()
        openLab("single-image", in: app)

        let run = app.buttons["single-image.run"]
        scrollUntilVisible(run, in: app)
        waitUntilEnabled(run)
        run.tap()
        assertAccessibilityValue(
            "passed",
            identifier: "expectation.complete",
            in: app,
            timeout: 30
        )
    }

    func testSingleFlightLabClosesJoinEvidenceLoop() {
        let app = launchApp()
        openLab("single-flight", in: app)

        let run = app.buttons["concurrency.run"]
        scrollUntilVisible(run, in: app)
        waitUntilEnabled(run)
        run.tap()

        let join = element("expectation.join", in: app)
        scrollUntilVisible(join, in: app)
        XCTAssertTrue(join.waitForExistence(timeout: 12))
        assertAccessibilityValue("passed", identifier: "expectation.origin", in: app)
        assertAccessibilityValue("passed", identifier: "expectation.join", in: app)
    }

    func testCacheNoStoreScriptClosesOriginEvidenceLoop() {
        let app = launchApp()
        openLab("cache-identity", in: app)

        let reset = app.buttons["cache.reset-evidence"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()
        assertLabel("缓存与诊断证据已重置", identifier: "cache.action-status", in: app)

        let first = app.buttons["cache.first-run"]
        let firstRunValue = runAndWaitForCompletion(
            first,
            statusIdentifier: "lab.latest-result.complete",
            previousValue: nil,
            in: app
        )

        let second = app.buttons["cache.second-run"]
        _ = runAndWaitForCompletion(
            second,
            statusIdentifier: "lab.latest-result.complete",
            previousValue: firstRunValue,
            in: app
        )

        let origin = element("evidence.metric.origin", in: app)
        scrollUntilVisible(origin, in: app)
        XCTAssertTrue(origin.waitForExistence(timeout: 8))
        XCTAssertFalse(origin.label.contains("源站请求 0"))
        assertAccessibilityValue("passed", identifier: "expectation.origin", in: app)
    }

    func testAuthenticationLabSeparatesAccountsAndRejectsInvalidToken() {
        let app = launchApp()
        openLab("authentication-isolation", in: app)

        let accountA = app.buttons["auth.account-a.run"]
        _ = runAndWaitForCompletion(
            accountA,
            statusIdentifier: "lab.latest-result.a",
            previousValue: nil,
            in: app
        )

        let accountB = app.buttons["auth.account-b.run"]
        _ = runAndWaitForCompletion(
            accountB,
            statusIdentifier: "lab.latest-result.b",
            previousValue: nil,
            in: app
        )

        let invalid = app.buttons["auth.invalid-token"]
        scrollUntilVisible(invalid, in: app)
        waitUntilEnabled(invalid)
        invalid.tap()

        let invalidExpectation = element("expectation.invalid", in: app)
        scrollUntilVisible(invalidExpectation, in: app)
        XCTAssertTrue(invalidExpectation.waitForExistence(timeout: 10))
        assertAccessibilityValue("passed", identifier: "expectation.invalid", in: app)
    }

    func testFailureMatrixValidatesStableReasonCode() {
        let app = launchApp()
        openLab("failure-matrix", in: app)

        let serverFailure = app.buttons["failure.case.http-500"]
        XCTAssertTrue(serverFailure.waitForExistence(timeout: 5))
        serverFailure.tap()

        let run = app.buttons["failure.run"]
        scrollUntilVisible(run, in: app)
        waitUntilEnabled(run)
        run.tap()

        let expectation = element("expectation.reason", in: app)
        scrollUntilVisible(expectation, in: app)
        XCTAssertTrue(expectation.waitForExistence(timeout: 10))
        assertAccessibilityValue("passed", identifier: "expectation.reason", in: app)
    }

    func testFeedRunsScriptAndExercisesUIKitReuseHost() {
        let app = launchApp()
        openLab("host-feed", in: app)
        XCTAssertTrue(element("feed-lab", in: app).waitForExistence(timeout: 5))
        let workloadSize = element("feed.workload-size", in: app)
        XCTAssertTrue(workloadSize.waitForExistence(timeout: 5))
        let expectedItemCount = Int(workloadSize.value as? String ?? "") ?? 240

        let workload = element("feed.workload-toggle", in: app)
        XCTAssertTrue(workload.waitForExistence(timeout: 5))
        workload.tap()

        XCTAssertTrue(element("feed-lab", in: app).waitForExistence(timeout: 5))
        let fastScript = app.buttons["feed.script-fast"]
        XCTAssertTrue(fastScript.waitForExistence(timeout: 5))
        fastScript.tap()
        assertLabel("快速反向 已完成", identifier: "feed.action-status", in: app, timeout: 8)
        assertLabel("内存占用 +", identifier: "feed.action-status", in: app, timeout: 5)
        XCTAssertTrue(element("feed.metric.max-interval-ms", in: app).waitForExistence(timeout: 5))

        let uiKit = app.buttons["UIKit"]
        XCTAssertTrue(uiKit.waitForExistence(timeout: 5))
        uiKit.tap()
        XCTAssertTrue(element("feed.uikit.collection", in: app).waitForExistence(timeout: 8))

        let bottom = app.buttons["feed.scroll-bottom"]
        bottom.tap()
        assertLabel("已滚动到底部", identifier: "feed.action-status", in: app)
        XCTAssertTrue(
            element("feed.uikit.cell.\(expectedItemCount - 1)", in: app).waitForExistence(
                timeout: 8))
    }

    func testUITestingUsesDeterministicNetworkingByDefault() {
        let app = launchApp()
        tapTab("tab.settings", label: "设置", in: app)

        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        assertAccessibilityValue(
            "就绪",
            identifier: "settings.runtime-state",
            in: app,
            timeout: 30
        )

        let externalNetworkSwitch = app.switches["settings.external-network"]
        scrollUntilVisible(externalNetworkSwitch, in: app)
        XCTAssertTrue(externalNetworkSwitch.waitForExistence(timeout: 5))
        XCTAssertEqual(externalNetworkSwitch.value as? String, "0")
        externalNetworkSwitch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)
        ).tap()
        waitForValue("1", of: externalNetworkSwitch, timeout: 10)
        let apply = app.buttons["settings.apply"]
        scrollUntilVisible(apply, in: app)
        waitUntilEnabled(apply, timeout: 30)
        apply.tap()
        assertLabel("设置已应用到当前图片管线", identifier: "settings.action-status", in: app, timeout: 15)
    }

    func testCoreSuiteRunsEveryScenarioSequentially() {
        let app = launchApp()
        tapTab("tab.evidence", label: "证据", in: app)

        let runSuite = app.buttons["experiments.run-core-suite"]
        scrollUntilVisible(runSuite, in: app)
        waitUntilEnabled(runSuite, timeout: 30)
        runSuite.tap()

        assertLabelContainsOneOf(
            ["确定性核心套件运行中", "确定性核心套件已完成：13/13"],
            identifier: "experiments.action-status",
            in: app,
            timeout: 15
        )
        assertLabel(
            "确定性核心套件已完成：13/13",
            identifier: "experiments.action-status",
            in: app,
            timeout: 180
        )
    }

    func testDiagnosticsMaintenancePublishesObservableStatus() {
        let app = launchApp()
        tapTab("tab.evidence", label: "证据", in: app)

        let diagnostics = element("evidence.open-diagnostics", in: app)
        scrollUntilVisible(diagnostics, in: app)
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        diagnostics.tap()
        XCTAssertTrue(app.navigationBars["管线诊断"].waitForExistence(timeout: 8))

        let copy = app.buttons["diagnostics.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        assertLabel("已复制", identifier: "diagnostics.action-status", in: app)

        let clear = app.buttons["diagnostics.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        assertLabel("诊断时间线已清空", identifier: "diagnostics.action-status", in: app)
    }

}
