import FoveaCore
import XCTest

final class AnimationPresentationCadenceTests: XCTestCase {
    func testCadenceUsesExactCommonBoundaryForVariableDurations_W5_PT_138() throws {
        let recommendation = try XCTUnwrap(
            AnimationPresentationCadenceRecommendation(
                frameDurationsNanoseconds: [100_000_000, 150_000_000, 250_000_000]
            )
        )
        XCTAssertEqual(recommendation.alignmentQuantumNanoseconds, 50_000_000)
        XCTAssertEqual(
            recommendation.preferredFramesPerSecond(maximumFramesPerSecond: 120),
            20
        )
    }

    func testCadenceIncludesOneSecondSoIntegerFPSRemainsExact_W5_PT_139() throws {
        let recommendation = try XCTUnwrap(
            AnimationPresentationCadenceRecommendation(
                frameDurationsNanoseconds: [1_500_000_000, 2_000_000_000]
            )
        )
        XCTAssertEqual(recommendation.alignmentQuantumNanoseconds, 500_000_000)
        XCTAssertEqual(
            recommendation.preferredFramesPerSecond(maximumFramesPerSecond: 120),
            2
        )
    }

    func testCadenceDeclinesReductionWhenSourceNeedsAtLeastPlatformMaximum_W5_PT_140()
        throws
    {
        let sixtyFPS = try XCTUnwrap(
            AnimationPresentationCadenceRecommendation(
                frameDurationsNanoseconds: [50_000_000, 100_000_000]
            )
        )
        XCTAssertNil(sixtyFPS.preferredFramesPerSecond(maximumFramesPerSecond: 20))

        let nonintegral = try XCTUnwrap(
            AnimationPresentationCadenceRecommendation(
                frameDurationsNanoseconds: [16_666_667, 33_333_334]
            )
        )
        XCTAssertNil(nonintegral.preferredFramesPerSecond(maximumFramesPerSecond: 120))
    }

    func testCadenceRejectsInvalidDurations_W5_PT_141() {
        XCTAssertNil(
            AnimationPresentationCadenceRecommendation(frameDurationsNanoseconds: [])
        )
        XCTAssertNil(
            AnimationPresentationCadenceRecommendation(
                frameDurationsNanoseconds: [100_000_000, 0]
            )
        )
    }
}
