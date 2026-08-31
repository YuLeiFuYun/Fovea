import FoveaCore
import FoveaHTTP
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
        let firstObservation = controller.recordCancellation(first)
        XCTAssertFalse(firstObservation.shouldWarmCancelledRequest)
        controller.finish(first)
        clock.advance(nanoseconds: 10_000_000)

        let second = controller.begin(for: request)
        XCTAssertFalse(second.preservesFetchOnCancellation)
        XCTAssertEqual(second.stabilizationNanoseconds, 0)
        let secondObservation = controller.recordCancellation(second)
        XCTAssertTrue(secondObservation.shouldWarmCancelledRequest)
        XCTAssertEqual(secondObservation.observedPeriodNanoseconds, 10_000_000)
        controller.finish(second)
        clock.advance(nanoseconds: 2_000_000)

        let third = controller.begin(for: request)
        XCTAssertTrue(third.preservesFetchOnCancellation)
        XCTAssertEqual(third.stabilizationNanoseconds, 10_000_001)
        let thirdObservation = controller.recordCancellation(third)
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

    func testConcurrentCancellationFanoutDoesNotMasqueradeAsSequentialChurn_UI_PT_028()
        async throws
    {
        let clock = TestMonotonicTimeSource()
        let controller = AdaptiveImageLoadAdmission(maximumStateCount: 64, timeSource: clock)
        let request = try imageRequest(path: "fanout.png", width: 320, height: 240)
        let concurrent = (0..<32).map { _ in controller.begin(for: request) }

        XCTAssertFalse(controller.recordCancellation(concurrent[0]).shouldWarmCancelledRequest)
        for ticket in concurrent.dropFirst() {
            clock.advance(nanoseconds: 1_000_000)
            XCTAssertFalse(controller.recordCancellation(ticket).shouldWarmCancelledRequest)
            controller.finish(ticket)
        }
        controller.finish(concurrent[0])

        let replacement = controller.begin(for: request)
        XCTAssertFalse(replacement.preservesFetchOnCancellation)
        clock.advance(nanoseconds: 10_000_000)
        let replacementCancellation = controller.recordCancellation(replacement)
        XCTAssertTrue(replacementCancellation.shouldWarmCancelledRequest)
        XCTAssertEqual(replacementCancellation.observedPeriodNanoseconds, 41_000_000)
        controller.finish(replacement)

        let stable = controller.begin(for: request)
        XCTAssertTrue(stable.preservesFetchOnCancellation)
        XCTAssertEqual(stable.stabilizationNanoseconds, 41_000_001)
        controller.finish(stable)
    }

    func testAdmissionStateDoesNotCrossLogicalSourceAtSameGeometry_UI_PT_026() async throws {
        let clock = TestMonotonicTimeSource()
        let controller = AdaptiveImageLoadAdmission(maximumStateCount: 64, timeSource: clock)
        let firstSource = try imageRequest(path: "a.png", width: 320, height: 240)
        let secondSource = try imageRequest(path: "b.png", width: 320, height: 240)

        let first = controller.begin(for: firstSource)
        controller.recordCancellation(first)
        controller.finish(first)
        clock.advance(nanoseconds: 10_000_000)
        let second = controller.begin(for: firstSource)
        XCTAssertTrue(controller.recordCancellation(second).shouldWarmCancelledRequest)
        controller.finish(second)

        let independent = controller.begin(for: secondSource)
        XCTAssertFalse(independent.preservesFetchOnCancellation)
        XCTAssertEqual(independent.stabilizationNanoseconds, 0)
        XCTAssertFalse(
            controller.recordCancellation(independent).shouldWarmCancelledRequest
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
            controller.recordCancellation(ticket)
            controller.finish(ticket)
        }
        let independent = controller.begin(for: secondTarget)

        let trackedStateCount = controller.trackedStateCount()
        XCTAssertFalse(independent.preservesFetchOnCancellation)
        XCTAssertEqual(independent.stabilizationNanoseconds, 0)
        XCTAssertEqual(trackedStateCount, 2)
    }

    func testHandoffLeaseRequiresKnownBoundedRemainingBytes_UI_PT_029() throws {
        let lease = FetchCancellationHandoffLease()
        lease.activate(graceNanoseconds: 250_000_000)
        lease.configureProgressObservation(supported: true)

        XCTAssertEqual(
            lease.eligibleGraceNanoseconds(maximumRemainingBytes: 1_048_576),
            0
        )

        let head = try TransportResponseHead(
            statusCode: 200,
            headers: ["Content-Length": "2097152"],
            url: URL(string: "https://example.test/large.jpg")
        )
        lease.observe(.response(head))
        lease.observe(.data(Data(), cumulativeByteCount: 524_288))
        XCTAssertEqual(lease.eligibleGraceNanoseconds(maximumRemainingBytes: 1_048_576), 0)

        lease.observe(.data(Data(), cumulativeByteCount: 1_310_720))
        XCTAssertEqual(
            lease.eligibleGraceNanoseconds(maximumRemainingBytes: 1_048_576),
            250_000_000
        )

        lease.observe(.data(Data(), cumulativeByteCount: 2_097_153))
        XCTAssertEqual(lease.eligibleGraceNanoseconds(maximumRemainingBytes: 1_048_576), 0)
    }

    func testHandoffLeaseResetsProgressForEachRetryAttempt_UI_PT_029() throws {
        let lease = FetchCancellationHandoffLease()
        lease.activate(graceNanoseconds: 250_000_000)
        lease.configureProgressObservation(supported: true)
        let head = try TransportResponseHead(
            statusCode: 200,
            headers: ["Content-Length": "2097152"],
            url: URL(string: "https://example.test/retried.jpg")
        )

        lease.observe(.response(head))
        lease.observe(.data(Data(), cumulativeByteCount: 1_572_864))
        XCTAssertEqual(
            lease.eligibleGraceNanoseconds(maximumRemainingBytes: 1_048_576),
            250_000_000
        )

        lease.observe(.response(head))
        XCTAssertEqual(lease.eligibleGraceNanoseconds(maximumRemainingBytes: 1_048_576), 0)
    }

    func testHandoffLeaseRejectsEncodedContentLengthDomain_UI_PT_029() throws {
        let lease = FetchCancellationHandoffLease()
        lease.activate(graceNanoseconds: 250_000_000)
        lease.configureProgressObservation(supported: true)
        lease.observe(
            .response(
                try TransportResponseHead(
                    statusCode: 200,
                    headers: [
                        "Content-Length": "262144",
                        "Content-Encoding": "gzip",
                    ],
                    url: URL(string: "https://example.test/compressed.jpg")
                )
            )
        )
        lease.observe(.data(Data(), cumulativeByteCount: 196_608))

        XCTAssertEqual(lease.eligibleGraceNanoseconds(maximumRemainingBytes: 1_048_576), 0)
    }

    func testHandoffRemainingByteLimitUsesTargetSurfaceAndTransportCap_UI_PT_029() throws {
        XCTAssertEqual(
            FetchCancellationHandoffPolicy.maximumRemainingBytes(
                targetWidth: 320,
                targetHeight: 240,
                transportMemoryThreshold: 1_048_576
            ),
            307_200
        )
        XCTAssertEqual(
            FetchCancellationHandoffPolicy.maximumRemainingBytes(
                targetWidth: 1_024,
                targetHeight: 1_024,
                transportMemoryThreshold: 1_048_576
            ),
            1_048_576
        )
        XCTAssertEqual(
            FetchCancellationHandoffPolicy.maximumRemainingBytes(
                targetWidth: 32,
                targetHeight: 32,
                transportMemoryThreshold: 0
            ),
            0
        )
    }

    func testHandoffLeasePreservesLegacyBehaviorWithoutProgressObservation_UI_PT_029() {
        let lease = FetchCancellationHandoffLease()
        lease.activate(graceNanoseconds: 75_000_000)
        XCTAssertEqual(
            lease.eligibleGraceNanoseconds(maximumRemainingBytes: 1_048_576),
            75_000_000
        )
    }

    func testHandoffLeaseRejectsUnknownLengthUntilCompletion_UI_PT_029() throws {
        let lease = FetchCancellationHandoffLease()
        lease.activate(graceNanoseconds: 100_000_000)
        lease.configureProgressObservation(supported: true)
        lease.observe(
            .response(
                try TransportResponseHead(
                    statusCode: 200,
                    headers: [:],
                    url: URL(string: "https://example.test/chunked.jpg")
                )
            )
        )
        lease.observe(.data(Data(), cumulativeByteCount: 32_768))
        XCTAssertEqual(lease.eligibleGraceNanoseconds(maximumRemainingBytes: 1_048_576), 0)

        lease.observe(.complete(digestHex: String(repeating: "0", count: 64), byteCount: 32_768))
        XCTAssertEqual(
            lease.eligibleGraceNanoseconds(maximumRemainingBytes: 1_048_576),
            100_000_000
        )
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
