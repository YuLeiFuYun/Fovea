import XCTest

@MainActor
final class FoveaWorkbenchIPadUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testIPadLaunchShowsResponsiveEcologicalAtlas_DEMO_PT_027() {
        let app = launchApp()
        let window = app.windows.firstMatch.frame
        // iPadOS 窗口化不保证应用占满物理屏幕；布局契约绑定有效窗口而不是设备面板。
        XCTAssertGreaterThanOrEqual(window.width, 500)
        XCTAssertGreaterThan(window.height, window.width)
        XCTAssertTrue(element("ecology.root", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("ecology.hero", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("ecology.navigation-deck", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("ecology.featured.climate-gap", in: app).waitForExistence(timeout: 8))
    }

    func testIPadWindowShowsProductPatternsWithoutBlankColumns() {
        let app = launchApp()
        XCTAssertGreaterThanOrEqual(app.windows.firstMatch.frame.width, 500)

        openLab("product-patterns", in: app)
        XCTAssertTrue(element("product.hero", in: app).waitForExistence(timeout: 5))
        scrollUntilVisible(element("product.avatar", in: app), in: app)
        XCTAssertTrue(element("product.avatar", in: app).exists)
        XCTAssertTrue(element("product.chat-thumbnail", in: app).exists)
        scrollUntilVisible(element("product.grid.0", in: app), in: app)
        XCTAssertTrue(element("product.grid.0", in: app).exists)
        XCTAssertTrue(element("product.grid.1", in: app).exists)
    }

    func testIPadFeedExercisesGridDensityPerformanceAndUIKitHost() {
        let app = launchApp()
        openLab("host-feed", in: app)
        XCTAssertTrue(element("feed-lab", in: app).waitForExistence(timeout: 5))
        let workloadSize = element("feed.workload-size", in: app)
        XCTAssertTrue(workloadSize.waitForExistence(timeout: 5))
        let expectedItemCount = Int(workloadSize.value as? String ?? "") ?? 240

        let workload = element("feed.workload-toggle", in: app)
        XCTAssertTrue(workload.waitForExistence(timeout: 5))
        workload.tap()

        let grid = app.buttons["网格"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        grid.tap()
        XCTAssertTrue(element("feed.cell.0", in: app).waitForExistence(timeout: 8))

        let script = app.buttons["feed.script-fast"]
        XCTAssertTrue(script.waitForExistence(timeout: 5))
        script.tap()
        assertLabel(
            "脚本 快速反向 已完成", identifier: "feed.action-status", in: app, timeout: 10)
        assertLabel("内存占用 +", identifier: "feed.action-status", in: app, timeout: 2)

        let uiKit = app.buttons["UIKit"]
        XCTAssertTrue(uiKit.waitForExistence(timeout: 5))
        uiKit.tap()
        XCTAssertTrue(element("feed.uikit.collection", in: app).waitForExistence(timeout: 8))

        let bottom = app.buttons["feed.scroll-bottom"]
        XCTAssertTrue(bottom.waitForExistence(timeout: 5))
        bottom.tap()
        XCTAssertTrue(
            element("feed.uikit.cell.\(expectedItemCount - 1)", in: app).waitForExistence(
                timeout: 8))
    }

    func testIPadSingleImagePublishesBehaviorEvidence() {
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

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        registerTermination(of: app)
        XCTAssertTrue(app.navigationBars["生态图谱"].waitForExistence(timeout: 15))
        return app
    }

    /// 每个 regular-width 测试独占自己的 App 生命周期，避免 shard 内状态串扰。
    private func registerTermination(of app: XCUIApplication) {
        addTeardownBlock { @MainActor in
            app.terminate()
        }
    }

    private func openLab(_ identifier: String, in app: XCUIApplication) {
        tapTab("tab.scenarios", label: "验证", in: app)

        let searchField = app.searchFields.firstMatch
        if !searchField.waitForExistence(timeout: 15) {
            // 首次启动时 split-view 目录可能仍在安装可访问性树；重新选择验证页后再等待。
            tapTab("tab.scenarios", label: "验证", in: app)
        }
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 10),
            "Validation catalog search field did not become available"
        )
        searchField.tap()
        searchField.typeText(labSearchQuery(identifier))

        let matches = app.descendants(matching: .any).matching(identifier: "lab.\(identifier)")
        XCTAssertTrue(
            matches.firstMatch.waitForExistence(timeout: 10), "Missing lab: \(identifier)")
        var tapped = false
        for index in 0..<matches.count {
            let candidate = matches.element(boundBy: index)
            if candidate.isHittable {
                candidate.tap()
                tapped = true
                break
            }
        }
        XCTAssertTrue(tapped, "No hittable lab row: \(identifier)")
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
    }

    private func labSearchQuery(_ identifier: String) -> String {
        switch identifier {
        case "product-patterns": "头像"
        case "single-image": "单图"
        case "cache-identity": "缓存"
        case "authentication-isolation": "账户"
        case "single-flight": "并发"
        case "host-feed": "列表"
        case "failure-matrix": "失败"
        case "live-network": "真实网络"
        default: identifier
        }
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func assertLabel(
        _ label: String,
        identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let item = element(identifier, in: app)
        let predicate = NSPredicate(format: "label CONTAINS %@", label)
        if item.waitForExistence(timeout: 1) {
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: item)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
            return
        }
        XCTAssertTrue(
            app.staticTexts.containing(predicate).firstMatch.waitForExistence(timeout: timeout))
    }

    private func assertAccessibilityValue(
        _ value: String,
        identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        let item = element(identifier, in: app)
        scrollUntilVisible(item, in: app)
        XCTAssertTrue(item.waitForExistence(timeout: timeout))
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: item
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    private func waitUntilEnabled(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }

    private func tapTab(
        _ identifier: String,
        label: String,
        in app: XCUIApplication
    ) {
        let identifiedItems = app.descendants(matching: .any).matching(identifier: identifier)
        if identifiedItems.firstMatch.waitForExistence(timeout: 5) {
            for index in 0..<identifiedItems.count {
                let item = identifiedItems.element(boundBy: index)
                if item.isHittable {
                    item.tap()
                    return
                }
            }
        }

        let labeledButton = app.buttons[label]
        if labeledButton.waitForExistence(timeout: 3) {
            labeledButton.tap()
            return
        }

        let tabBarItem = app.tabBars.firstMatch.buttons[label]
        XCTAssertTrue(tabBarItem.waitForExistence(timeout: 5))
        tabBarItem.tap()
    }

    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication) {
        let preferred = app.scrollViews["single-image.scroll"]
        if preferred.exists {
            for _ in 0..<14 where !element.exists {
                preferred.swipeUp()
            }
            if element.exists { return }
        }
        for _ in 0..<8 where !element.exists {
            if app.collectionViews.firstMatch.exists {
                app.collectionViews.firstMatch.swipeUp()
            } else if app.scrollViews.firstMatch.exists {
                app.scrollViews.firstMatch.swipeUp()
            } else {
                app.swipeUp()
            }
        }
    }
}
