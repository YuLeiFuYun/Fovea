import CoreGraphics
import Foundation
import FoveaCore
import ImageCraftCore
import XCTest

final class T100AnimationPlaybackResidentFramesSnapshotTests: XCTestCase {
    func testSnapshotPreservesTimelineModeAndPinnedFrameOrder_RESIDENT_PT_001() throws {
        let memory = AnimationFrameMemory(costLimit: 256)
        let firstImage = try makeImage(width: 4, height: 4)
        let secondImage = try makeImage(width: 2, height: 2)
        let decodeKey = try XCTUnwrap(makeDecodeKey())
        let keys = [
            try XCTUnwrap(makeMemoryKey(decodeKey: decodeKey, frameIndex: 0)),
            try XCTUnwrap(makeMemoryKey(decodeKey: decodeKey, frameIndex: 1)),
        ]
        XCTAssertTrue(memory.insert(firstImage, for: keys[0]).isEmpty)
        XCTAssertTrue(memory.insert(secondImage, for: keys[1]).isEmpty)
        var lease: AnimationFrameMemoryPinLease? = try XCTUnwrap(memory.pinResidentFrames(for: keys))
        let timeline = try AnimationPlaybackTimeline(
            frameDurationsNanoseconds: [100, 200],
            additionalRepeatCount: 1,
            zeroDurationReplacementNanoseconds: 1,
            timingPolicyVersion: 7
        )

        var snapshot: AnimationPlaybackResidentFramesSnapshot? = AnimationPlaybackResidentFramesSnapshot(
            timeline: timeline,
            mode: .playOnce,
            pinLease: try XCTUnwrap(lease)
        )

        XCTAssertEqual(snapshot?.timeline, timeline)
        XCTAssertEqual(snapshot?.mode, .playOnce)
        XCTAssertEqual(snapshot?.frames.map(\.estimatedByteCost), [64, 16])
        XCTAssertEqual(memory.pinnedCostForTesting, 80)
        lease = nil
        XCTAssertEqual(memory.pinnedCostForTesting, 80)
        snapshot = nil
        XCTAssertEqual(memory.pinnedCostForTesting, 0)
    }

    func testSnapshotRetainsPinLeaseAfterCallerDropsLease_RESIDENT_PT_002() throws {
        let memory = AnimationFrameMemory(costLimit: 128)
        let image = try makeImage(width: 4, height: 4)
        let decodeKey = try XCTUnwrap(makeDecodeKey(seed: "lease-lifetime"))
        let key = try XCTUnwrap(makeMemoryKey(decodeKey: decodeKey, frameIndex: 0))
        XCTAssertTrue(memory.insert(image, for: key).isEmpty)
        var lease: AnimationFrameMemoryPinLease? = try XCTUnwrap(memory.pinResidentFrames(for: [key]))
        XCTAssertEqual(memory.pinnedCostForTesting, 64)
        let timeline = try AnimationPlaybackTimeline(
            frameDurationsNanoseconds: [100],
            additionalRepeatCount: nil,
            zeroDurationReplacementNanoseconds: 1,
            timingPolicyVersion: 7
        )
        var snapshot: AnimationPlaybackResidentFramesSnapshot? = AnimationPlaybackResidentFramesSnapshot(
            timeline: timeline,
            mode: .normal,
            pinLease: try XCTUnwrap(lease)
        )

        lease = nil
        XCTAssertEqual(memory.pinnedCostForTesting, 64)
        XCTAssertEqual(snapshot?.frames.count, 1)
        snapshot = nil
        XCTAssertEqual(memory.pinnedCostForTesting, 0)
    }

    private func makeDecodeKey(seed: String = "snapshot") -> AnimationDecodeKey? {
        AnimationDecodeKey(
            contentID: ContentID(data: Data(seed.utf8)),
            target: try! TargetPixels(width: 32, height: 32),
            contentMode: .fit,
            colorPolicy: .convertToSRGB,
            codecFingerprint: "codec-v1",
            animationPolicyVersion: 1,
            timingPolicyVersion: 1,
            frameStrategy: .boundedFrameCache
        )
    }

    private func makeMemoryKey(
        namespace: SecurityNamespaceID = SecurityNamespaceID("snapshot-account"),
        generation: NamespaceGeneration = NamespaceGeneration(1),
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
        else { throw NSError(domain: "T100AnimationPlaybackResidentFramesSnapshotTests", code: 1) }
        return DecodedImage(cgImage: image)
    }
}
