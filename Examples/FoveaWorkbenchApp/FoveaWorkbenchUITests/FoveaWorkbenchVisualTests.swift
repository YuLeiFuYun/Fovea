import XCTest

/// Workbench 的视觉证据采集套件。
///
/// 该套件不把“元素存在”当成视觉正确。每个检查点同时保留：
/// - 屏幕截图；
/// - Accessibility 树；
/// - 可见按钮、图片和文本的几何 JSON；
/// - 可疑重叠、越界与触控尺寸记录。
///
/// Python 审查器会读取这些附件并执行独立像素与几何检查。当前测试先负责稳定采集，
/// 重写完成后由严格审查模式把仍存在的视觉缺陷升级为失败。
@MainActor
final class FoveaWorkbenchVisualTests: XCTestCase {
    private struct ElementGeometry: Codable {
        let kind: String
        let identifier: String
        let label: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    private struct OverlapFinding: Codable {
        let lhs: String
        let rhs: String
        let intersectionRatio: Double
    }

    private struct GeometrySnapshot: Codable {
        let checkpoint: String
        let screenWidth: Double
        let screenHeight: Double
        let elements: [ElementGeometry]
        let undersizedButtons: [String]
        let offscreenElements: [String]
        let suspiciousOverlaps: [OverlapFinding]
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCaptureProductVisualMatrix_VISUAL_PT_001() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = launch(arguments: ["--ui-testing"])
        XCTAssertTrue(element("ecology.root", in: app).waitForExistence(timeout: 15))
        capture("首页-生态图谱", app: app)

        tapTab("tab.scenarios", label: "验证", in: app)
        XCTAssertTrue(app.navigationBars["验证中心"].waitForExistence(timeout: 10))
        capture("验证中心", app: app)

        tapTab("tab.evidence", label: "证据", in: app)
        XCTAssertTrue(app.navigationBars["证据与运行"].waitForExistence(timeout: 10))
        capture("证据与运行", app: app)

        tapTab("tab.settings", label: "设置", in: app)
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        capture("设置", app: app)
        app.terminate()

        let story = launch(arguments: ["--ui-testing", "--ui-story", "climate-gap"])
        XCTAssertTrue(element("ecology.story.climate-gap", in: story).waitForExistence(timeout: 15))
        capture("专题-气候差距", app: story)
        story.terminate()

        let studio = launch(arguments: ["--ui-testing", "--ui-studio"])
        XCTAssertTrue(element("studio.root", in: studio).waitForExistence(timeout: 15))
        capture("场景工坊-竖屏", app: studio)

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForStableOrientation(app: studio)
        capture("场景工坊-横屏", app: studio)
        studio.terminate()
    }

    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func tapTab(
        _ identifier: String,
        label: String,
        in app: XCUIApplication
    ) {
        let identified = element(identifier, in: app)
        if identified.waitForExistence(timeout: 4) {
            identified.tap()
            return
        }

        let labeled = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
        XCTAssertTrue(
            labeled.waitForExistence(timeout: 6),
            "缺少标签页：\(label)（\(identifier)）"
        )
        labeled.tap()
    }

    private func waitForStableOrientation(app: XCUIApplication) {
        let original = app.windows.firstMatch.frame
        let predicate = NSPredicate { object, _ in
            guard let window = object as? XCUIElement else { return false }
            let frame = window.frame
            return frame.width > frame.height && frame != original
        }
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: app.windows.firstMatch
        )
        _ = XCTWaiter.wait(for: [expectation], timeout: 8)
    }

    private func capture(_ checkpoint: String, app: XCUIApplication) {
        let prefix = devicePrefix(app: app)
        let stableName = "\(prefix)-\(checkpoint)"

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "截图-\(stableName)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "辅助功能树-\(stableName).txt"
        tree.lifetime = .keepAlways
        add(tree)

        let snapshot = geometrySnapshot(checkpoint: stableName, app: app)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            let geometry = XCTAttachment(
                data: data,
                uniformTypeIdentifier: "public.json"
            )
            geometry.name = "几何-\(stableName).json"
            geometry.lifetime = .keepAlways
            add(geometry)
        }
    }

    private func devicePrefix(app: XCUIApplication) -> String {
        let frame = app.windows.firstMatch.frame
        return max(frame.width, frame.height) >= 1_000 ? "iPad" : "iPhone"
    }

    private func geometrySnapshot(
        checkpoint: String,
        app: XCUIApplication
    ) -> GeometrySnapshot {
        let screen = app.windows.firstMatch.frame
        var records: [ElementGeometry] = []
        records += geometries(app.buttons.allElementsBoundByIndex, kind: "button", screen: screen)
        records += geometries(app.images.allElementsBoundByIndex, kind: "image", screen: screen)
        records += geometries(app.staticTexts.allElementsBoundByIndex, kind: "text", screen: screen)

        let buttons = records.filter {
            $0.kind == "button" && isActionIdentifier($0.identifier)
        }
        let undersized = buttons.compactMap { item -> String? in
            guard item.width < 44 || item.height < 44 else { return nil }
            return stableElementName(item)
        }
        let offscreen = records.compactMap { item -> String? in
            guard isApplicationIdentifier(item.identifier) else { return nil }
            let frame = CGRect(x: item.x, y: item.y, width: item.width, height: item.height)
            guard !screen.contains(frame) else { return nil }
            return stableElementName(item)
        }
        let imageRecords = records.filter {
            $0.kind == "image" && isContentImageIdentifier($0.identifier)
        }
        let overlaps = suspiciousOverlaps(in: imageRecords)

        return GeometrySnapshot(
            checkpoint: checkpoint,
            screenWidth: screen.width,
            screenHeight: screen.height,
            elements: records,
            undersizedButtons: undersized.sorted(),
            offscreenElements: offscreen.sorted(),
            suspiciousOverlaps: overlaps
        )
    }

    private func geometries(
        _ elements: [XCUIElement],
        kind: String,
        screen: CGRect
    ) -> [ElementGeometry] {
        elements.compactMap { element in
            guard element.exists else { return nil }
            let frame = element.frame
            guard !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0 else {
                return nil
            }
            guard frame.intersects(screen) else { return nil }
            return ElementGeometry(
                kind: kind,
                identifier: element.identifier,
                label: element.label,
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height
            )
        }
    }

    private func suspiciousOverlaps(in images: [ElementGeometry]) -> [OverlapFinding] {
        var findings: [OverlapFinding] = []
        for lhsIndex in images.indices {
            for rhsIndex in images.indices where rhsIndex > lhsIndex {
                let lhs = images[lhsIndex]
                let rhs = images[rhsIndex]
                let lhsFrame = CGRect(x: lhs.x, y: lhs.y, width: lhs.width, height: lhs.height)
                let rhsFrame = CGRect(x: rhs.x, y: rhs.y, width: rhs.width, height: rhs.height)
                let intersection = lhsFrame.intersection(rhsFrame)
                guard !intersection.isNull, intersection.width > 1, intersection.height > 1 else {
                    continue
                }
                let minimumArea = min(
                    lhsFrame.width * lhsFrame.height,
                    rhsFrame.width * rhsFrame.height
                )
                guard minimumArea > 0 else { continue }
                let ratio = intersection.width * intersection.height / minimumArea
                // 小装饰叠加不进入报告；超过较小图片四分之一才视为可疑。
                guard ratio >= 0.25 else { continue }
                findings.append(
                    OverlapFinding(
                        lhs: stableElementName(lhs),
                        rhs: stableElementName(rhs),
                        intersectionRatio: ratio
                    )
                )
            }
        }
        return findings.sorted {
            if $0.lhs == $1.lhs { return $0.rhs < $1.rhs }
            return $0.lhs < $1.lhs
        }
    }

    private func isApplicationIdentifier(_ identifier: String) -> Bool {
        let prefixes = [
            "auth.", "cache.", "catalog.", "concurrency.", "diagnostics.",
            "discover.", "ecology.", "evidence.", "expectation.", "experiments.",
            "failure.", "feed.", "lab.", "performance.", "product.", "run.",
            "settings.", "studio.", "tab.",
        ]
        return prefixes.contains { identifier.hasPrefix($0) }
    }

    private func isActionIdentifier(_ identifier: String) -> Bool {
        let nonActionPrefixes = ["tab.", "ecology.metric."]
        return isApplicationIdentifier(identifier)
            && !nonActionPrefixes.contains { identifier.hasPrefix($0) }
    }

    private func isContentImageIdentifier(_ identifier: String) -> Bool {
        let markers = [
            ".avatar.", ".attachment.", ".cover", ".featured-image", ".hero",
            ".image", ".preview.", ".story-image.", ".thumbnail", ".work.",
        ]
        guard isApplicationIdentifier(identifier) else { return false }
        return markers.contains { identifier.contains($0) }
    }

    private func stableElementName(_ item: ElementGeometry) -> String {
        if !item.identifier.isEmpty { return item.identifier }
        if !item.label.isEmpty { return item.label }
        return "\(item.kind)@\(Int(item.x)),\(Int(item.y))"
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
