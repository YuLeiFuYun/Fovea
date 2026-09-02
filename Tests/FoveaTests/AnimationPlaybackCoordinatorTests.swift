import CoreGraphics
import Foundation
import FoveaCore
import ImageCraftCore
import XCTest

final class AnimationPlaybackCoordinatorTests: XCTestCase {
    func testCoordinatorDecodesMissingWindowThenUsesSharedCache_W5_PT_032() async throws {
        let provider = TestAnimationProvider(image: makeImage())
        let fixture = try makeFixture(provider: provider)
        try await fixture.coordinator.start(at: 0)

        let first = try await fixture.coordinator.advance(at: 0)
        XCTAssertEqual(first.decision.frameIndex, 0)
        XCTAssertEqual(first.decodedFrameCount, 4)
        XCTAssertFalse(first.currentFrameWasCached)
        XCTAssertNotNil(first.image)
        let rangesAfterFirst = await provider.ranges()
        XCTAssertEqual(rangesAfterFirst, [0..<4])

        let second = try await fixture.coordinator.advance(at: 0)
        XCTAssertEqual(second.decodedFrameCount, 0)
        XCTAssertTrue(second.currentFrameWasCached)
        XCTAssertNotNil(second.image)
        let rangesAfterSecond = await provider.ranges()
        XCTAssertEqual(rangesAfterSecond, [0..<4])
    }

    func testConcurrentAdvancesSerializeAndAvoidDuplicateDecode_W5_PT_033() async throws {
        let provider = TestAnimationProvider(
            image: makeImage(),
            suspension: .firstCall
        )
        let fixture = try makeFixture(provider: provider)
        try await fixture.coordinator.start(at: 0)

        async let first = fixture.coordinator.advance(at: 0)
        try await waitUntil("animation provider first call") {
            await provider.callCount() == 1
        }
        async let second = fixture.coordinator.advance(at: 0)
        await provider.releaseSuspendedCall()
        let outputs = try await [first, second]

        XCTAssertEqual(outputs.map(\.decodedFrameCount).sorted(), [0, 4])
        let concurrentCallCount = await provider.callCount()
        XCTAssertEqual(concurrentCallCount, 1)
        XCTAssertNotNil(outputs[0].image)
        XCTAssertNotNil(outputs[1].image)
    }

    func testProviderUnderDeliveryFailsBeforeAnyFramePublication_W5_PT_034() async throws {
        let provider = TestAnimationProvider(
            image: makeImage(),
            resultMode: .underDeliver
        )
        let fixture = try makeFixture(provider: provider)
        try await fixture.coordinator.start(at: 0)

        do {
            _ = try await fixture.coordinator.advance(at: 0)
            XCTFail("Under-delivering provider unexpectedly published animation frames")
        } catch {
            XCTAssertEqual(
                error as? AnimationPlaybackCoordinatorError,
                .providerResultMismatch
            )
        }
        XCTAssertEqual(fixture.memory.count, 0)
    }

    func testProviderWrongIndexFailsBeforeAnyFramePublication_W5_PT_035() async throws {
        let provider = TestAnimationProvider(
            image: makeImage(),
            resultMode: .wrongFirstIndex
        )
        let fixture = try makeFixture(provider: provider)
        try await fixture.coordinator.start(at: 0)

        do {
            _ = try await fixture.coordinator.advance(at: 0)
            XCTFail("Wrong-index provider unexpectedly published animation frames")
        } catch {
            XCTAssertEqual(
                error as? AnimationPlaybackCoordinatorError,
                .providerResultMismatch
            )
        }
        XCTAssertEqual(fixture.memory.count, 0)
    }

    func testOffscreenTransitionRevokesLatePublicationAndCanResume_W5_PT_036() async throws {
        let provider = TestAnimationProvider(
            image: makeImage(),
            suspension: .firstCall
        )
        let fixture = try makeFixture(provider: provider)
        try await fixture.coordinator.start(at: 0)
        let advance = Task { try await fixture.coordinator.advance(at: 0) }
        try await waitUntil("animation provider suspended call") {
            await provider.callCount() == 1
        }

        try await fixture.coordinator.setVisible(false, at: 1)
        await provider.releaseSuspendedCall()
        do {
            _ = try await advance.value
            XCTFail("Offscreen generation unexpectedly published late frames")
        } catch {
            XCTAssertEqual(
                error as? AnimationPlaybackCoordinatorError,
                .publicationRevoked
            )
        }
        XCTAssertEqual(fixture.memory.count, 0)
        let nonterminalCancelCount = await provider.cancelCount()
        XCTAssertEqual(nonterminalCancelCount, 0)

        try await fixture.coordinator.setVisible(true, at: 10)
        let resumed = try await fixture.coordinator.advance(at: 10)
        XCTAssertEqual(resumed.decodedFrameCount, 4)
        XCTAssertNotNil(resumed.image)
        let resumedCallCount = await provider.callCount()
        XCTAssertEqual(resumedCallCount, 2)
    }

    func testWarningPressureRevokesInFlightNormalWindowThenUsesWarningWindow_W5_PT_136()
        async throws
    {
        let provider = TestAnimationProvider(
            image: makeImage(),
            suspension: .firstCall
        )
        let fixture = try makeFixture(provider: provider)
        try await fixture.coordinator.start(at: 0)
        let advance = Task { try await fixture.coordinator.advance(at: 0) }
        try await waitUntil("animation provider before warning pressure") {
            await provider.callCount() == 1
        }

        let removal = try await fixture.coordinator.applyMemoryPressure(.warning, at: 1)
        XCTAssertEqual(removal.itemCount, 0)
        await provider.releaseSuspendedCall()
        do {
            _ = try await advance.value
            XCTFail("Pre-warning normal window unexpectedly published after warning pressure")
        } catch {
            XCTAssertEqual(
                error as? AnimationPlaybackCoordinatorError,
                .publicationRevoked
            )
        }
        XCTAssertEqual(fixture.memory.count, 0)

        let warning = try await fixture.coordinator.advance(at: 1)
        XCTAssertEqual(warning.decodedFrameCount, 2)
        XCTAssertNotNil(warning.image)
        let ranges = await provider.ranges()
        XCTAssertEqual(ranges, [0..<4, 0..<2])
    }

    func testTerminalCancelClosesProviderAndPreventsLatePublication_W5_PT_037() async throws {
        let provider = TestAnimationProvider(
            image: makeImage(),
            suspension: .firstCall
        )
        let fixture = try makeFixture(provider: provider)
        try await fixture.coordinator.start(at: 0)
        let advance = Task { try await fixture.coordinator.advance(at: 0) }
        try await waitUntil("animation provider before cancel") {
            await provider.callCount() == 1
        }

        await fixture.coordinator.cancel()
        await fixture.coordinator.cancel()
        do {
            _ = try await advance.value
            XCTFail("Cancelled coordinator unexpectedly produced a frame")
        } catch {
            XCTAssertTrue(
                error is CancellationError
                    || error as? AnimationPlaybackCoordinatorError == .cancelled
            )
        }
        let terminalCancelCount = await provider.cancelCount()
        XCTAssertEqual(terminalCancelCount, 1)
        XCTAssertEqual(fixture.memory.count, 0)
        do {
            _ = try await fixture.coordinator.advance(at: 1)
            XCTFail("Cancelled coordinator accepted a new advance")
        } catch {
            XCTAssertEqual(error as? AnimationPlaybackCoordinatorError, .cancelled)
        }
    }

    func testWrappedWindowUsesTwoExactProviderRanges_W5_PT_038() async throws {
        let provider = TestAnimationProvider(image: makeImage())
        let fixture = try makeFixture(provider: provider, frameCount: 6)
        try await fixture.coordinator.start(at: 0)
        try await fixture.coordinator.seek(toFrame: 4, at: 0)

        let output = try await fixture.coordinator.advance(at: 0)
        XCTAssertEqual(output.decision.frameIndex, 4)
        XCTAssertEqual(output.decodedFrameCount, 4)
        let wrappedRanges = await provider.ranges()
        XCTAssertEqual(wrappedRanges, [4..<6, 0..<2])
    }

    func testFrameLargerThanMemoryBudgetFailsDisplayBoundary_W5_PT_039() async throws {
        let provider = TestAnimationProvider(image: makeImage(width: 8, height: 8))
        let fixture = try makeFixture(provider: provider, memoryCostLimit: 64)
        try await fixture.coordinator.start(at: 0)

        do {
            _ = try await fixture.coordinator.advance(at: 0)
            XCTFail("Oversized provider frame unexpectedly crossed display boundary")
        } catch {
            XCTAssertEqual(
                error as? AnimationPlaybackCoordinatorError,
                .providerResultMismatch
            )
        }
        XCTAssertEqual(fixture.memory.count, 0)
    }

    func testProviderFrameLargerThanDecodeTargetFailsBeforePublication_W5_PT_134() async throws {
        let provider = TestAnimationProvider(image: makeImage(width: 33, height: 1))
        let fixture = try makeFixture(provider: provider)
        try await fixture.coordinator.start(at: 0)

        do {
            _ = try await fixture.coordinator.advance(at: 0)
            XCTFail("Out-of-target provider frame unexpectedly crossed display boundary")
        } catch {
            XCTAssertEqual(
                error as? AnimationPlaybackCoordinatorError,
                .providerResultMismatch
            )
        }
        XCTAssertEqual(fixture.memory.count, 0)
    }

    func testTightBudgetRetainsCurrentFrameThenLearnsSmallerWindow_W5_PT_135() async throws {
        let provider = TestAnimationProvider(image: makeImage())
        let fixture = try makeFixture(provider: provider, memoryCostLimit: 128)
        try await fixture.coordinator.start(at: 0)

        let first = try await fixture.coordinator.advance(at: 0)
        XCTAssertEqual(first.decodedFrameCount, 4)
        XCTAssertNotNil(first.image)
        XCTAssertEqual(fixture.memory.count, 2)
        let firstRanges = await provider.ranges()
        XCTAssertEqual(firstRanges, [0..<4])

        let second = try await fixture.coordinator.advance(at: 0)
        XCTAssertTrue(second.currentFrameWasCached)
        XCTAssertEqual(second.decodedFrameCount, 1)
        XCTAssertNotNil(second.image)
        let secondRanges = await provider.ranges()
        XCTAssertEqual(secondRanges, [0..<4, 1..<2])
    }

    func testSharedDecodePermitSerializesDifferentCoordinators_W5_PT_207() async throws {
        let sharedDecodePermits = AsyncPermitPool(limit: 1, queueLimit: 8)
        let firstProvider = TestAnimationProvider(
            image: makeImage(),
            suspension: .firstCall
        )
        let secondProvider = TestAnimationProvider(image: makeImage())
        let first = try makeFixture(
            provider: firstProvider,
            sharedDecodePermits: sharedDecodePermits
        )
        let second = try makeFixture(
            provider: secondProvider,
            sharedDecodePermits: sharedDecodePermits
        )
        try await first.coordinator.start(at: 0)
        try await second.coordinator.start(at: 0)

        let firstAdvance = Task { try await first.coordinator.advance(at: 0) }
        try await waitUntil("first animation holds shared decode permit") {
            await firstProvider.callCount() == 1
        }
        let secondAdvance = Task { try await second.coordinator.advance(at: 0) }
        try await waitUntil("second animation waits for shared decode permit") {
            await sharedDecodePermits.queuedCount() == 1
        }
        let secondCallsWhileBlocked = await secondProvider.callCount()
        XCTAssertEqual(secondCallsWhileBlocked, 0)

        await firstProvider.releaseSuspendedCall()
        _ = try await firstAdvance.value
        _ = try await secondAdvance.value
        let secondCallsAfterRelease = await secondProvider.callCount()
        XCTAssertEqual(secondCallsAfterRelease, 1)
    }

    func testProvenWindowPeakSharesWorkingSetAcrossCoordinators_W5_PT_208() async throws {
        let sharedWorkingSetPermits = AsyncPermitPool(limit: 1_024, queueLimit: 8)
        let sharedDecodePermits = AsyncPermitPool(limit: 2, queueLimit: 8)
        let firstProvider = TestAnimationProvider(
            image: makeImage(),
            suspension: .firstCall,
            windowPeakByteCostUpperBound: 1_024
        )
        let secondProvider = TestAnimationProvider(
            image: makeImage(),
            windowPeakByteCostUpperBound: 1_024
        )
        let first = try makeFixture(
            provider: firstProvider,
            sharedDecodeWorkingSetPermits: sharedWorkingSetPermits,
            sharedDecodePermits: sharedDecodePermits
        )
        let second = try makeFixture(
            provider: secondProvider,
            sharedDecodeWorkingSetPermits: sharedWorkingSetPermits,
            sharedDecodePermits: sharedDecodePermits
        )
        try await first.coordinator.start(at: 0)
        try await second.coordinator.start(at: 0)

        let firstAdvance = Task { try await first.coordinator.advance(at: 0) }
        try await waitUntil("first animation holds shared working-set permit") {
            await firstProvider.callCount() == 1
        }
        let secondAdvance = Task { try await second.coordinator.advance(at: 0) }
        try await waitUntil("second animation waits for shared working-set permit") {
            await sharedWorkingSetPermits.queuedCount() == 1
        }
        let secondCallsWhileWorkingSetBlocked = await secondProvider.callCount()
        XCTAssertEqual(secondCallsWhileWorkingSetBlocked, 0)

        await firstProvider.releaseSuspendedCall()
        _ = try await firstAdvance.value
        _ = try await secondAdvance.value
        let secondCallsAfterWorkingSetRelease = await secondProvider.callCount()
        XCTAssertEqual(secondCallsAfterWorkingSetRelease, 1)
    }

    private func makeFixture(
        provider: TestAnimationProvider,
        frameCount: Int = 6,
        memoryCostLimit: Int = 4_096,
        sharedDecodeWorkingSetPermits: AsyncPermitPool? = nil,
        sharedDecodePermits: AsyncPermitPool? = nil
    ) throws -> (
        coordinator: AnimationPlaybackCoordinator,
        memory: AnimationFrameMemory
    ) {
        let memory = AnimationFrameMemory(costLimit: memoryCostLimit)
        let decodeKey = try XCTUnwrap(
            AnimationDecodeKey(
                contentID: ContentID(data: Data("coordinator-animation".utf8)),
                target: TargetPixels(width: 32, height: 32),
                contentMode: .fit,
                colorPolicy: .convertToSRGB,
                codecFingerprint: "test-provider-v1",
                animationPolicyVersion: 1,
                timingPolicyVersion: 1,
                frameStrategy: .boundedFrameCache
            )
        )
        let timeline = try AnimationPlaybackTimeline(
            frameDurationsNanoseconds: [UInt64](repeating: 10, count: frameCount),
            additionalRepeatCount: nil,
            zeroDurationReplacementNanoseconds: 1,
            timingPolicyVersion: 1
        )
        let session = AnimationPlaybackSession(
            namespace: SecurityNamespaceID("account-a"),
            generation: NamespaceGeneration(1),
            decodeKey: decodeKey,
            timeline: timeline,
            mode: .normal,
            frameMemory: memory,
            windowPolicy: AnimationFrameWindowPolicy(
                normalFrameCount: 4,
                warningFrameCount: 2
            )
        )
        return (
            AnimationPlaybackCoordinator(
                session: session,
                provider: provider,
                sharedDecodeWorkingSetPermits: sharedDecodeWorkingSetPermits,
                sharedDecodePermits: sharedDecodePermits
            ),
            memory
        )
    }

    private func makeImage(width: Int = 4, height: Int = 4) -> DecodedImage {
        let bytesPerRow = width * 4
        let data = Data(repeating: 0x99, count: bytesPerRow * height)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return DecodedImage(cgImage: image)
    }
}

private actor TestAnimationProvider: AnimationFrameProvider {
    enum ResultMode {
        case valid
        case underDeliver
        case wrongFirstIndex
    }

    enum Suspension {
        case none
        case firstCall
    }

    private let image: DecodedImage
    private let resultMode: ResultMode
    private let suspension: Suspension
    private let windowPeakByteCostUpperBound: Int?
    private var requestedRanges: [Range<Int>] = []
    private var suspendedContinuation: CheckedContinuation<Void, Never>?
    private var cancellationCount = 0
    private var isCancelled = false

    init(
        image: DecodedImage,
        resultMode: ResultMode = .valid,
        suspension: Suspension = .none,
        windowPeakByteCostUpperBound: Int? = nil
    ) {
        self.image = image
        self.resultMode = resultMode
        self.suspension = suspension
        self.windowPeakByteCostUpperBound = windowPeakByteCostUpperBound
    }

    func frames(in range: Range<Int>) async throws -> [AnimationProviderFrame] {
        requestedRanges.append(range)
        if suspension == .firstCall, requestedRanges.count == 1 {
            await withCheckedContinuation { continuation in
                suspendedContinuation = continuation
            }
        }
        try Task.checkCancellation()
        guard !isCancelled else { throw CancellationError() }
        switch resultMode {
        case .valid:
            return range.map { AnimationProviderFrame(index: $0, image: image) }
        case .underDeliver:
            return range.dropLast().map { AnimationProviderFrame(index: $0, image: image) }
        case .wrongFirstIndex:
            return range.enumerated().map { offset, index in
                AnimationProviderFrame(
                    index: offset == 0 ? index + 1 : index,
                    image: image
                )
            }
        }
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancellationCount += 1
        suspendedContinuation?.resume()
        suspendedContinuation = nil
    }

    func frameWindowPredecodePeakByteCostUpperBound(frameCount: Int) -> Int? {
        guard frameCount > 0 else { return nil }
        return windowPeakByteCostUpperBound
    }

    func releaseSuspendedCall() {
        suspendedContinuation?.resume()
        suspendedContinuation = nil
    }

    func ranges() -> [Range<Int>] { requestedRanges }
    func callCount() -> Int { requestedRanges.count }
    func cancelCount() -> Int { cancellationCount }
}
