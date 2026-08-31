import CoreGraphics
import Foundation
import FoveaCore
import ImageCraftCore
import XCTest

final class AnimationFrameMemoryTests: XCTestCase {
    func testAnimationFrameIdentitySeparatesFramePolicyCodecAndNamespace_W5_PT_017() throws {
        let base = try XCTUnwrap(makeDecodeKey())
        let changedPolicy = try XCTUnwrap(makeDecodeKey(animationPolicyVersion: 2))
        let changedCodec = try XCTUnwrap(makeDecodeKey(codecFingerprint: "codec-v2"))
        let first = try XCTUnwrap(makeMemoryKey(decodeKey: base, frameIndex: 0))

        XCTAssertNotEqual(first, makeMemoryKey(decodeKey: base, frameIndex: 1))
        XCTAssertNotEqual(first, makeMemoryKey(decodeKey: changedPolicy, frameIndex: 0))
        XCTAssertNotEqual(first, makeMemoryKey(decodeKey: changedCodec, frameIndex: 0))
        XCTAssertNotEqual(
            first,
            makeMemoryKey(
                namespace: SecurityNamespaceID("account-b"),
                decodeKey: base,
                frameIndex: 0
            )
        )
        XCTAssertNil(makeMemoryKey(decodeKey: base, frameIndex: -1))
        XCTAssertNil(makeDecodeKey(codecFingerprint: "bad\ncodec"))
    }

    func testAnimationFrameMemoryUsesActualBytesAndEvictsWithinOwnBudget_W5_PT_018() throws {
        let image = try makeImage(width: 4, height: 4)
        XCTAssertEqual(image.estimatedByteCost, 64)
        let memory = AnimationFrameMemory(costLimit: 128)
        let decodeKey = try XCTUnwrap(makeDecodeKey())
        let keys = try (0..<3).map {
            try XCTUnwrap(makeMemoryKey(decodeKey: decodeKey, frameIndex: $0))
        }

        XCTAssertTrue(memory.insert(image, for: keys[0]).isEmpty)
        XCTAssertTrue(memory.insert(image, for: keys[1]).isEmpty)
        let evicted = memory.insert(image, for: keys[2])

        XCTAssertEqual(evicted.count, 1)
        XCTAssertEqual(memory.count, 2)
        XCTAssertEqual(memory.currentCost, 128)
        XCTAssertNotNil(memory.image(for: keys[2]))
    }

    func testOversizedFrameDoesNotEnterAnimationMemory_W5_PT_019() throws {
        let memory = AnimationFrameMemory(costLimit: 64)
        let image = try makeImage(width: 8, height: 8)
        let key = try XCTUnwrap(
            makeMemoryKey(
                decodeKey: try XCTUnwrap(makeDecodeKey()),
                frameIndex: 0
            )
        )

        XCTAssertTrue(memory.insert(image, for: key).isEmpty)
        XCTAssertNil(memory.image(for: key))
        XCTAssertEqual(memory.count, 0)
        XCTAssertEqual(memory.currentCost, 0)
    }

    func testNamespaceAndAssetRemovalReturnExactCost_W5_PT_020() throws {
        let memory = AnimationFrameMemory(costLimit: 512)
        let image = try makeImage(width: 4, height: 4)
        let firstDecode = try XCTUnwrap(makeDecodeKey(seed: "first"))
        let secondDecode = try XCTUnwrap(makeDecodeKey(seed: "second"))
        let accountA = SecurityNamespaceID("account-a")
        let accountB = SecurityNamespaceID("account-b")
        let generation = NamespaceGeneration(4)
        let first = try XCTUnwrap(
            makeMemoryKey(
                namespace: accountA,
                generation: generation,
                decodeKey: firstDecode,
                frameIndex: 0
            )
        )
        let second = try XCTUnwrap(
            makeMemoryKey(
                namespace: accountA,
                generation: generation,
                decodeKey: secondDecode,
                frameIndex: 0
            )
        )
        let third = try XCTUnwrap(
            makeMemoryKey(
                namespace: accountB,
                generation: generation,
                decodeKey: firstDecode,
                frameIndex: 0
            )
        )
        memory.insert(image, for: first)
        memory.insert(image, for: second)
        memory.insert(image, for: third)

        let assetRemoval = memory.removeAll(
            namespace: accountA,
            generation: generation,
            decodeKey: firstDecode
        )
        XCTAssertEqual(assetRemoval.itemCount, 1)
        XCTAssertEqual(assetRemoval.costBytes, 64)
        XCTAssertNil(memory.image(for: first))
        XCTAssertNotNil(memory.image(for: second))
        XCTAssertNotNil(memory.image(for: third))

        let namespaceRemoval = memory.removeAll(namespace: accountA)
        XCTAssertEqual(namespaceRemoval.itemCount, 1)
        XCTAssertEqual(namespaceRemoval.costBytes, 64)
        XCTAssertEqual(memory.count, 1)
        XCTAssertEqual(memory.currentCost, 64)
    }

    func testPinnedFramesRemainChargedAndBlockBudgetEscape_W5_PT_162() throws {
        let memory = AnimationFrameMemory(costLimit: 128)
        let image = try makeImage(width: 4, height: 4)
        let decodeKey = try XCTUnwrap(makeDecodeKey())
        let keys = try (0..<3).map {
            try XCTUnwrap(makeMemoryKey(decodeKey: decodeKey, frameIndex: $0))
        }
        memory.insert(image, for: keys[0])
        memory.insert(image, for: keys[1])

        let lease = try XCTUnwrap(memory.pinResidentFrames(for: [keys[0], keys[1]]))
        XCTAssertEqual(lease.byteCost, 128)
        XCTAssertEqual(memory.pinnedCostForTesting, 128)
        XCTAssertEqual(memory.pinnedCountForTesting, 2)
        XCTAssertEqual(memory.currentCost, 128)

        XCTAssertTrue(memory.insert(image, for: keys[2]).isEmpty)
        XCTAssertNil(memory.image(for: keys[2]))
        XCTAssertEqual(memory.currentCost, 128)
        XCTAssertEqual(memory.count, 2)

        lease.release()
        XCTAssertEqual(memory.pinnedCostForTesting, 0)
        XCTAssertEqual(memory.currentCost, 128)
        XCTAssertEqual(memory.count, 2)
        XCTAssertNotNil(memory.image(for: keys[0]))
        XCTAssertNotNil(memory.image(for: keys[1]))
    }

    func testSharedPinLeasesDoNotDoubleChargePixelBytes_W5_PT_163() throws {
        let memory = AnimationFrameMemory(costLimit: 128)
        let image = try makeImage(width: 4, height: 4)
        let decodeKey = try XCTUnwrap(makeDecodeKey())
        let keys = try (0..<2).map {
            try XCTUnwrap(makeMemoryKey(decodeKey: decodeKey, frameIndex: $0))
        }
        for key in keys { memory.insert(image, for: key) }

        let first = try XCTUnwrap(memory.pinResidentFrames(for: keys))
        let second = try XCTUnwrap(memory.pinResidentFrames(for: keys))
        XCTAssertEqual(first.byteCost, 128)
        XCTAssertEqual(second.byteCost, 128)
        XCTAssertEqual(memory.pinnedCostForTesting, 128)
        XCTAssertEqual(memory.currentCost, 128)

        first.release()
        XCTAssertEqual(memory.pinnedCostForTesting, 128)
        XCTAssertEqual(memory.currentCost, 128)
        second.release()
        XCTAssertEqual(memory.pinnedCostForTesting, 0)
        XCTAssertEqual(memory.currentCost, 128)
        XCTAssertEqual(memory.count, 2)
    }

    func testPurgedPinnedFramesDoNotResurrectOnLeaseRelease_W5_PT_164() throws {
        let memory = AnimationFrameMemory(costLimit: 128)
        let image = try makeImage(width: 4, height: 4)
        let decodeKey = try XCTUnwrap(makeDecodeKey())
        let keys = try (0..<2).map {
            try XCTUnwrap(makeMemoryKey(decodeKey: decodeKey, frameIndex: $0))
        }
        for key in keys { memory.insert(image, for: key) }
        let lease = try XCTUnwrap(memory.pinResidentFrames(for: keys))

        let immediate = memory.removeAll(namespace: SecurityNamespaceID("account-a"))
        XCTAssertEqual(immediate.itemCount, 0)
        XCTAssertEqual(memory.currentCost, 128)
        XCTAssertEqual(memory.pinnedCostForTesting, 128)

        lease.release()
        XCTAssertEqual(memory.pinnedCostForTesting, 0)
        XCTAssertEqual(memory.currentCost, 0)
        XCTAssertEqual(memory.count, 0)
        XCTAssertNil(memory.image(for: keys[0]))
        XCTAssertNil(memory.image(for: keys[1]))
    }

    func testPinnedFramesLeaveOnlyRemainingBudgetForStreamingEntries_W5_PT_165() throws {
        let memory = AnimationFrameMemory(costLimit: 192)
        let image = try makeImage(width: 4, height: 4)
        let decodeKey = try XCTUnwrap(makeDecodeKey())
        let keys = try (0..<4).map {
            try XCTUnwrap(makeMemoryKey(decodeKey: decodeKey, frameIndex: $0))
        }
        memory.insert(image, for: keys[0])
        memory.insert(image, for: keys[1])
        let lease = try XCTUnwrap(memory.pinResidentFrames(for: [keys[0], keys[1]]))

        XCTAssertTrue(memory.insert(image, for: keys[2]).isEmpty)
        XCTAssertEqual(memory.currentCost, 192)
        XCTAssertNotNil(memory.image(for: keys[2]))
        let evicted = memory.insert(image, for: keys[3])
        XCTAssertEqual(evicted, [keys[2]])
        XCTAssertEqual(memory.currentCost, 192)
        XCTAssertNotNil(memory.image(for: keys[0]))
        XCTAssertNotNil(memory.image(for: keys[1]))
        XCTAssertNil(memory.image(for: keys[2]))
        XCTAssertNotNil(memory.image(for: keys[3]))

        lease.release()
        XCTAssertLessThanOrEqual(memory.currentCost, 192)
    }

    func testProviderRetainedReservationsShareResidentBudgetWithPins_W5_PT_188() throws {
        let memory = AnimationFrameMemory(costLimit: 256)
        let image = try makeImage(width: 4, height: 4)
        let decodeKey = try XCTUnwrap(makeDecodeKey())
        let keys = try (0..<3).map {
            try XCTUnwrap(makeMemoryKey(decodeKey: decodeKey, frameIndex: $0))
        }
        for key in keys { memory.insert(image, for: key) }
        let lease = try XCTUnwrap(memory.pinResidentFrames(for: [keys[0]]))
        XCTAssertEqual(memory.currentCost, 192)
        XCTAssertEqual(memory.pinnedCostForTesting, 64)

        let firstReservation = UUID()
        XCTAssertTrue(memory.reserveExternalRetainedCost(96, for: firstReservation))
        XCTAssertTrue(memory.reserveExternalRetainedCost(96, for: firstReservation))
        XCTAssertFalse(memory.reserveExternalRetainedCost(95, for: firstReservation))
        XCTAssertEqual(memory.externalRetainedCostForTesting, 96)
        XCTAssertEqual(memory.currentCost, 128)
        XCTAssertNotNil(memory.image(for: keys[0]))
        XCTAssertEqual(memory.totalBudgetCostForTesting, 224)

        let secondReservation = UUID()
        XCTAssertTrue(memory.reserveExternalRetainedCost(40, for: secondReservation))
        XCTAssertEqual(memory.externalRetainedCostForTesting, 136)
        XCTAssertEqual(memory.currentCost, 64)
        XCTAssertNotNil(memory.image(for: keys[0]))
        XCTAssertEqual(memory.availableWholeTrackAdmissionCost, 56)
        XCTAssertEqual(memory.totalBudgetCostForTesting, 200)

        XCTAssertFalse(memory.reserveExternalRetainedCost(57, for: UUID()))
        XCTAssertEqual(memory.externalRetainedCostForTesting, 136)
        XCTAssertEqual(memory.pinnedCostForTesting, 64)

        memory.releaseExternalRetainedCost(for: firstReservation)
        XCTAssertEqual(memory.externalRetainedCostForTesting, 40)
        memory.releaseExternalRetainedCost(for: secondReservation)
        XCTAssertEqual(memory.externalRetainedCostForTesting, 0)
        XCTAssertEqual(memory.availableWholeTrackAdmissionCost, 192)

        lease.release()
        XCTAssertEqual(memory.pinnedCostForTesting, 0)
        XCTAssertEqual(memory.currentCost, 64)
        XCTAssertEqual(memory.totalBudgetCostForTesting, 64)
    }

    func testWindowPlannerWrapsOnceAndNeverDuplicatesFrames_W5_PT_021() throws {
        let plan = try AnimationFrameWindowPlanner.plan(
            startingAt: 4,
            frameCount: 6,
            maximumWindowSize: 4
        )
        XCTAssertEqual(plan.ranges, [4..<6, 0..<2])
        XCTAssertEqual(plan.frameCount, 4)
        XCTAssertEqual(Array(plan.ranges.joined()), [4, 5, 0, 1])

        let capped = try AnimationFrameWindowPlanner.plan(
            startingAt: 3,
            frameCount: 4,
            maximumWindowSize: 100
        )
        XCTAssertEqual(Array(capped.ranges.joined()), [3, 0, 1, 2])
    }

    func testMissingRangesPreserveContiguousProviderWindows_W5_PT_022() throws {
        let plan = try AnimationFrameWindowPlanner.plan(
            startingAt: 1,
            frameCount: 6,
            maximumWindowSize: 5
        )
        let missing = AnimationFrameWindowPlanner.missingRanges(from: plan) {
            [2, 4].contains($0)
        }

        XCTAssertEqual(missing.ranges, [1..<2, 3..<4, 5..<6])
        XCTAssertEqual(missing.frameCount, 3)
    }

    func testPressurePolicyClampsMonotonically_W5_PT_023() {
        let policy = AnimationFrameWindowPolicy(
            normalFrameCount: 100,
            warningFrameCount: 10,
            criticalFrameCount: 0
        )

        XCTAssertEqual(policy.frameCount(for: .normal), 64)
        XCTAssertEqual(policy.frameCount(for: .warning), 10)
        XCTAssertEqual(policy.frameCount(for: .critical), 1)
    }

    private func makeDecodeKey(
        seed: String = "asset",
        codecFingerprint: String = "codec-v1",
        animationPolicyVersion: UInt16 = 1
    ) -> AnimationDecodeKey? {
        AnimationDecodeKey(
            contentID: ContentID(data: Data(seed.utf8)),
            target: try! TargetPixels(width: 32, height: 32),
            contentMode: .fit,
            colorPolicy: .convertToSRGB,
            codecFingerprint: codecFingerprint,
            animationPolicyVersion: animationPolicyVersion,
            timingPolicyVersion: 1,
            frameStrategy: .boundedFrameCache
        )
    }

    private func makeMemoryKey(
        namespace: SecurityNamespaceID = SecurityNamespaceID("account-a"),
        generation: NamespaceGeneration = NamespaceGeneration(4),
        decodeKey: AnimationDecodeKey,
        frameIndex: Int
    ) -> AnimationFrameMemoryKey? {
        AnimationFrameMemoryKey(
            namespace: namespace,
            generation: generation,
            decodeKey: decodeKey,
            frameIndex: frameIndex
        )
    }

    private func makeImage(width: Int, height: Int) throws -> DecodedImage {
        let bytesPerRow = width * 4
        let data = Data(repeating: 0x7f, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData),
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
            )
        else { throw NSError(domain: "AnimationFrameMemoryTests", code: 1) }
        return DecodedImage(cgImage: image)
    }
}
