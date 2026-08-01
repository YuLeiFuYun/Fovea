import XCTest

@MainActor
extension FoveaWorkbenchUITests {
    func launchStoryApp(
        _ storyID: String,
        contractFirst: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-story", storyID]
        if contractFirst {
            app.launchArguments.append("--ui-contract-first")
        }
        app.launch()
        registerTermination(of: app)
        XCTAssertTrue(element("ecology.story.\(storyID)", in: app).waitForExistence(timeout: 15))
        let runtime = element("runtime.state", in: app)
        XCTAssertTrue(runtime.waitForExistence(timeout: 15))
        waitForValue("ready", of: runtime, timeout: 30)
        return app
    }

    func launchStudioApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-studio"]
        app.launch()
        registerTermination(of: app)
        XCTAssertTrue(element("studio.root", in: app).waitForExistence(timeout: 15))
        let runtime = element("runtime.state", in: app)
        XCTAssertTrue(runtime.waitForExistence(timeout: 15))
        waitForValue("ready", of: runtime, timeout: 30)
        return app
    }

    func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        registerTermination(of: app)
        XCTAssertTrue(app.navigationBars["生态图谱"].waitForExistence(timeout: 15))
        return app
    }

    /// 每个测试显式终止自己启动的 App，防止前一测试的 runtime、导航状态或
    /// 可访问性进程在同一 Xcode shard 中泄漏到下一测试。
    private func registerTermination(of app: XCUIApplication) {
        addTeardownBlock { @MainActor in
            app.terminate()
        }
    }

    func openEcologicalStory(
        _ storyID: String,
        query: String,
        in app: XCUIApplication
    ) {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(query)
        XCTAssertTrue(element("ecology.search.results", in: app).waitForExistence(timeout: 5))
        let result = element("ecology.search.\(storyID)", in: app)
        scrollUntilVisible(result, in: app)
        XCTAssertTrue(result.waitForExistence(timeout: 8), storyID)
        result.tap()
        XCTAssertTrue(element("ecology.story.\(storyID)", in: app).waitForExistence(timeout: 10))
    }

    func navigateBack(in app: XCUIApplication) {
        let button = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        XCTAssertTrue(element("ecology.root", in: app).waitForExistence(timeout: 8))
    }

    func openImageWorkbench(in app: XCUIApplication) {
        let entry = element("ecology.open-workbench", in: app)
        scrollUntilVisible(entry, in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(element("discover.root", in: app).waitForExistence(timeout: 8))
    }

    func openLab(_ identifier: String, in app: XCUIApplication) {
        tapTab("tab.scenarios", label: "验证", in: app)
        let lab = element("lab.\(identifier)", in: app)
        scrollUntilVisible(lab, in: app)
        XCTAssertTrue(lab.waitForExistence(timeout: 5), "Missing lab: \(identifier)")
        lab.tap()
        XCTAssertTrue(
            element("lab.\(identifier)", in: app).waitForExistence(timeout: 5)
                || app.navigationBars.firstMatch.waitForExistence(timeout: 5)
        )
    }

    @discardableResult
    func runAndWaitForCompletion(
        _ button: XCUIElement,
        statusIdentifier: String,
        previousValue: String?,
        in app: XCUIApplication
    ) -> String {
        scrollUntilVisible(button, in: app)
        waitUntilEnabled(button)
        button.tap()

        let status = element(statusIdentifier, in: app)
        scrollUntilVisible(status, in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 12))
        let predicate: NSPredicate
        if let previousValue {
            predicate = NSPredicate(
                format: "value BEGINSWITH %@ AND value != %@",
                "finished:",
                previousValue
            )
        } else {
            predicate = NSPredicate(format: "value BEGINSWITH %@", "finished:")
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 30), .completed)
        return status.value as? String ?? ""
    }

    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    func assertLabelContainsOneOf(
        _ labels: [String],
        identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 5
    ) {
        XCTAssertFalse(labels.isEmpty)
        let item = element(identifier, in: app)
        XCTAssertTrue(item.waitForExistence(timeout: min(1, timeout)))
        let predicates = labels.map { NSPredicate(format: "label CONTAINS %@", $0) }
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    func assertLabel(
        _ label: String,
        identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 5
    ) {
        let item = element(identifier, in: app)
        let predicate = NSPredicate(format: "label CONTAINS %@", label)
        if item.waitForExistence(timeout: 1) {
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: item)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
            return
        }

        let visibleText = app.staticTexts.containing(predicate).firstMatch
        XCTAssertTrue(
            visibleText.waitForExistence(timeout: timeout),
            "Missing status text for \(identifier): \(label)"
        )
    }

    func assertAccessibilityValue(
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

    func waitForValue(
        _ value: String,
        of element: XCUIElement,
        timeout: TimeInterval
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    func waitUntilEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval = 10
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication) {
        let preferred = app.scrollViews["single-image.scroll"]
        let container: XCUIElement
        if preferred.exists {
            container = preferred
        } else if app.collectionViews.firstMatch.exists {
            container = app.collectionViews.firstMatch
        } else if app.scrollViews.firstMatch.exists {
            container = app.scrollViews.firstMatch
        } else {
            container = app
        }

        // 场景运行后焦点可能停留在结果卡下方；先向后搜索，再有界回溯到上方控件。
        for _ in 0..<18 where !element.isHittable { container.swipeUp() }
        if element.isHittable { return }
        for _ in 0..<18 where !element.isHittable { container.swipeDown() }
    }

    func tapTab(
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

        let tabBarItem = app.tabBars.firstMatch.buttons[label]
        XCTAssertTrue(tabBarItem.waitForExistence(timeout: 5))
        tabBarItem.tap()
    }
}
