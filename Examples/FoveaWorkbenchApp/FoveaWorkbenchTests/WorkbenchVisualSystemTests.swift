import CoreGraphics
import ImageIO
import XCTest

@testable import FoveaWorkbench

final class WorkbenchVisualSystemTests: XCTestCase {
    func testDesignSystemKeepsInteractiveControlsAboveAccessibilityMinimum() {
        XCTAssertGreaterThanOrEqual(WorkbenchDesign.controlMinimumHeight, 44)
        XCTAssertGreaterThan(
            WorkbenchDesign.regularHorizontalPadding, WorkbenchDesign.compactHorizontalPadding)
        XCTAssertGreaterThan(WorkbenchDesign.prominentCardRadius, WorkbenchDesign.compactCardRadius)
    }

    func testAdaptiveColumnsRemainBoundedForHostileAndNormalWidths() {
        XCTAssertEqual(
            WorkbenchDesign.adaptiveColumnCount(
                availableWidth: .nan,
                minimumItemWidth: 180,
                maximum: 4
            ),
            1
        )
        XCTAssertEqual(
            WorkbenchDesign.adaptiveColumnCount(
                availableWidth: 390,
                minimumItemWidth: 180,
                maximum: 4
            ),
            2
        )
        XCTAssertEqual(
            WorkbenchDesign.adaptiveColumnCount(
                availableWidth: 10_000,
                minimumItemWidth: 180,
                maximum: 4
            ),
            4
        )
        XCTAssertEqual(
            WorkbenchDesign.adaptiveColumnCount(
                availableWidth: .greatestFiniteMagnitude,
                minimumItemWidth: 1,
                maximum: 4
            ),
            4,
            "A finite but Int-unrepresentable quotient must clamp before conversion"
        )
        XCTAssertEqual(
            WorkbenchDesign.adaptiveColumnCount(
                availableWidth: 390,
                minimumItemWidth: 180,
                spacing: -1,
                maximum: 4
            ),
            1
        )
    }

    func testImageSurfaceSanitizesGeometryAndOwnsOneDisplayMode() {
        let invalid = WorkbenchImageSurfaceConfiguration(
            aspectRatio: .infinity,
            contentMode: .fill,
            cornerRadius: .nan
        )
        XCTAssertEqual(invalid.aspectRatio, 4.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(invalid.cornerRadius, WorkbenchDesign.compactCardRadius)
        XCTAssertEqual(invalid.contentMode, .fill)

        let fit = WorkbenchImageSurfaceConfiguration.detail(
            assetAspectRatio: 3.0 / 2.0,
            contentMode: .fit
        )
        let fill = WorkbenchImageSurfaceConfiguration.detail(
            assetAspectRatio: 3.0 / 2.0,
            contentMode: .fill
        )
        XCTAssertEqual(fit.aspectRatio, 3.0 / 2.0, accuracy: 0.000_001)
        XCTAssertEqual(fill.aspectRatio, 16.0 / 9.0, accuracy: 0.000_001)
        XCTAssertNotEqual(fit.contentMode, fill.contentMode)

        let bounded = WorkbenchImageSurfaceConfiguration(
            aspectRatio: .greatestFiniteMagnitude,
            contentMode: .fit,
            cornerRadius: -.greatestFiniteMagnitude
        )
        XCTAssertEqual(bounded.aspectRatio, 4)
        XCTAssertEqual(bounded.cornerRadius, 0)
    }

    func testDeterministicFixturesHaveDistinctStableIdentitiesAndCatalogProvenance() throws {
        let fixtures = WorkbenchDeterministicFixture.allCases
        XCTAssertEqual(Set(fixtures.map(\.cacheIdentity)).count, fixtures.count)
        XCTAssertEqual(Set(fixtures.map(\.resourceName)).count, fixtures.count)

        for fixture in fixtures {
            let asset = try XCTUnwrap(WorkbenchRemoteAssetCatalog.asset(id: fixture.catalogAssetID))
            XCTAssertEqual(asset.sourceKind, .bundled)
            XCTAssertNotNil(fixture.bundledURL)
            XCTAssertEqual(asset.bundledURL, fixture.bundledURL)
            XCTAssertFalse(asset.author.isEmpty)
            XCTAssertFalse(asset.license.isEmpty)
            XCTAssertTrue(asset.sourcePageURL.absoluteString.hasPrefix("https://"))
        }
    }

    func testBundledRealAssetsRetainMinimumRasterResolution() throws {
        for asset in WorkbenchRemoteAssetCatalog.bundledAssets {
            let url = try XCTUnwrap(asset.bundledURL, asset.id)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), asset.id)
            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                asset.id
            )
            let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int, asset.id)
            let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int, asset.id)

            XCTAssertGreaterThanOrEqual(min(width, height), 480, asset.id)
            XCTAssertLessThanOrEqual(width, asset.originalPixelWidth, asset.id)
            XCTAssertLessThanOrEqual(height, asset.originalPixelHeight, asset.id)
        }
    }

    func testEvidenceDeviceFamilyCoversKnownUIKitIdioms() {
        XCTAssertEqual(WorkbenchEvidenceBundle.deviceFamily(.phone), "phone")
        XCTAssertEqual(WorkbenchEvidenceBundle.deviceFamily(.pad), "tablet")
        XCTAssertEqual(WorkbenchEvidenceBundle.deviceFamily(.tv), "television")
        XCTAssertEqual(WorkbenchEvidenceBundle.deviceFamily(.carPlay), "car-play")
        XCTAssertEqual(WorkbenchEvidenceBundle.deviceFamily(.mac), "mac")
        XCTAssertEqual(WorkbenchEvidenceBundle.deviceFamily(.unspecified), "unspecified")
        if #available(iOS 17.0, *) {
            XCTAssertEqual(WorkbenchEvidenceBundle.deviceFamily(.vision), "vision")
        }
    }
}
