import FoveaCore
import ImageCraftCore
import XCTest

final class AdaptiveImageLoadAdmissionTests: XCTestCase {
    func testTwoRapidCancellationsEnableFetchHandoffForSamePresentationClass_UI_PT_026()
        async throws
    {
        let clock = TestMonotonicTimeSource()
        let controller = AdaptiveImageLoadAdmission(maximumStateCount: 64, timeSource: clock)
        let request = try imageRequest(path: "first.png", width: 320, height: 240)

        let first = controller.begin(for: request)
        XCTAssertFalse(first.preservesFetchOnCancellation)
        XCTAssertEqual(first.stabilizationNanoseconds, 0)
        let firstObservation = controller.recordCancellation(for: request)
        XCTAssertFalse(firstObservation.shouldWarmCancelledRequest)
        controller.finish(first)
        clock.advance(nanoseconds: 10_000_000)

        let second = controller.begin(for: request)
        XCTAssertFalse(second.preservesFetchOnCancellation)
        XCTAssertEqual(second.stabilizationNanoseconds, 0)
        let secondObservation = controller.recordCancellation(for: request)
        XCTAssertTrue(secondObservation.shouldWarmCancelledRequest)
        XCTAssertEqual(secondObservation.observedPeriodNanoseconds, 10_000_000)
        controller.finish(second)
        clock.advance(nanoseconds: 2_000_000)

        let third = controller.begin(for: request)
        XCTAssertTrue(third.preservesFetchOnCancellation)
        XCTAssertEqual(third.stabilizationNanoseconds, 10_000_001)
        let thirdObservation = controller.recordCancellation(for: request)
        XCTAssertEqual(thirdObservation.observedPeriodNanoseconds, 2_000_000)
        controller.finish(third)

        // 较短的新周期不能降低稳定门；经验不确定集的上界只能在 cohort 内单调增加。
        let fourth = controller.begin(for: request)
        XCTAssertEqual(fourth.stabilizationNanoseconds, 10_000_001)
        controller.finish(fourth)

        clock.advance(nanoseconds: 3_000_000)
        let fifth = controller.begin(for: request)
        XCTAssertEqual(fifth.stabilizationNanoseconds, 10_000_001)
        controller.finish(fifth)

        clock.advance(nanoseconds: 8_000_000)
        let alreadyStable = controller.begin(for: request)
        XCTAssertEqual(alreadyStable.stabilizationNanoseconds, 10_000_001)
        XCTAssertTrue(alreadyStable.preservesFetchOnCancellation)
        controller.finish(alreadyStable)
    }

    func testAdmissionStateDoesNotCrossLogicalSourceAtSameGeometry_UI_PT_026() async throws {
        let clock = TestMonotonicTimeSource()
        let controller = AdaptiveImageLoadAdmission(maximumStateCount: 64, timeSource: clock)
        let firstSource = try imageRequest(path: "a.png", width: 320, height: 240)
        let secondSource = try imageRequest(path: "b.png", width: 320, height: 240)

        let first = controller.begin(for: firstSource)
        controller.recordCancellation(for: firstSource)
        controller.finish(first)
        clock.advance(nanoseconds: 10_000_000)
        let second = controller.begin(for: firstSource)
        XCTAssertTrue(controller.recordCancellation(for: firstSource).shouldWarmCancelledRequest)
        controller.finish(second)

        let independent = controller.begin(for: secondSource)
        XCTAssertFalse(independent.preservesFetchOnCancellation)
        XCTAssertEqual(independent.stabilizationNanoseconds, 0)
        XCTAssertFalse(
            controller.recordCancellation(for: secondSource).shouldWarmCancelledRequest
        )
        controller.finish(independent)
        XCTAssertEqual(controller.trackedStateCount(), 2)
    }

    func testAdmissionStateDoesNotCrossTargetGeometry_UI_PT_026() async throws {
        let controller = AdaptiveImageLoadAdmission(maximumStateCount: 64)
        let firstTarget = try imageRequest(path: "a.png", width: 320, height: 240)
        let secondTarget = try imageRequest(path: "b.png", width: 640, height: 480)

        for _ in 0..<2 {
            let ticket = controller.begin(for: firstTarget)
            controller.recordCancellation(for: firstTarget)
            controller.finish(ticket)
        }
        let independent = controller.begin(for: secondTarget)

        let trackedStateCount = controller.trackedStateCount()
        XCTAssertFalse(independent.preservesFetchOnCancellation)
        XCTAssertEqual(independent.stabilizationNanoseconds, 0)
        XCTAssertEqual(trackedStateCount, 2)
    }

    private func imageRequest(path: String, width: Int, height: Int) throws -> ImageRequest {
        try ImageRequest.publicImage(
            url: XCTUnwrap(URL(string: "https://example.test/\(path)")),
            target: TargetPixels(width: width, height: height),
            appID: "adaptive-admission-tests"
        )
    }
}

private final class TestMonotonicTimeSource: MonotonicTimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1_000_000_000

    func nowNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(nanoseconds: UInt64) {
        lock.lock()
        value &+= nanoseconds
        lock.unlock()
    }
}
