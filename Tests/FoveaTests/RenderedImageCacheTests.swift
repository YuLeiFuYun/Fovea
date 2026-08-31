import CoreGraphics
import Foundation
import ImageCraftCore
import XCTest

@testable import FoveaCore

final class RenderedImageCacheTests: XCTestCase {
    func testOneHitScanIsBoundedByProbationWindow_CACHE_PT_055() throws {
        let cache = DefaultRenderedImageCache(costLimit: 100, probationCostLimit: 25)
        let image = try makeImage()

        for index in 0..<100 {
            cache.insert(image, for: makeKey(index), cost: 5)
        }

        XCTAssertLessThanOrEqual(cache.currentCost, 25)
        XCTAssertLessThanOrEqual(cache.count, 5)
    }

    func testDefaultWindowBoundsW1UniqueAssetScan_CACHE_PT_060() throws {
        let cache = DefaultRenderedImageCache(costLimit: 64 * 1024 * 1024)
        let image = try makeImage()

        for index in 0..<128 {
            cache.insert(image, for: makeKey(index), cost: 320 * 240 * 4)
        }

        XCTAssertLessThanOrEqual(cache.currentCost, 16 * 1024 * 1024)
        XCTAssertLessThanOrEqual(cache.count, 16)
        XCTAssertLessThanOrEqual(cache.currentCost, 16 * 320 * 240 * 4)
    }

    func testSecondUsePromotesAcrossSubsequentScan_CACHE_PT_056() throws {
        let cache = DefaultRenderedImageCache(costLimit: 100, probationCostLimit: 25)
        let image = try makeImage()
        let hotKey = makeKey(0)
        cache.insert(image, for: hotKey, cost: 5)

        XCTAssertNotNil(cache.image(for: hotKey))
        for index in 1...100 {
            cache.insert(image, for: makeKey(index), cost: 5)
        }

        XCTAssertNotNil(cache.image(for: hotKey))
        XCTAssertLessThanOrEqual(cache.currentCost, 100)
    }

    func testMainCountGovernorDoesNotEvictFrequentlyHitOldestResident_CACHE_PT_067() throws {
        let cache = DefaultRenderedImageCache(costLimit: 100, probationCostLimit: 25)
        let image = try makeImage()
        let hotKey = makeKey(0)

        for index in 0..<16 {
            let key = makeKey(index)
            cache.insert(image, for: key, cost: 1)
            XCTAssertNotNil(cache.image(for: key), "setup must promote every resident into main")
        }

        for _ in 0..<64 {
            XCTAssertNotNil(cache.image(for: hotKey), "hot resident must remain readable before count pressure")
        }

        let newcomer = makeKey(16)
        cache.insert(image, for: newcomer, cost: 1)
        XCTAssertNotNil(cache.image(for: newcomer), "17th resident must be promoted")
        XCTAssertNotNil(
            cache.image(for: hotKey),
            "count governor must not override main SIEVE reuse by evicting the repeatedly-hit oldest resident"
        )
    }

    func testDefaultProbationRetainsWholeW2WarmMemoryWorkingSet_CACHE_PT_057() throws {
        let cache = DefaultRenderedImageCache(costLimit: 64 * 1024 * 1024)
        let image = try makeImage()
        let costs = [
            358_456,
            1_441_440,
            3_244_800,
            405_600,
            1_622_400,
            3_650_400,
            358_456,
            1_441_440,
            3_244_800,
        ]
        let keys = costs.indices.map { makeKey($0) }

        for (key, cost) in zip(keys, costs) {
            cache.insert(image, for: key, cost: cost)
        }

        XCTAssertEqual(cache.count, costs.count)
        XCTAssertEqual(cache.currentCost, costs.reduce(0, +))
        XCTAssertLessThan(cache.currentCost, 16 * 1024 * 1024)
        for key in keys {
            XCTAssertNotNil(cache.image(for: key))
        }
        XCTAssertEqual(cache.count, costs.count)
        XCTAssertEqual(cache.currentCost, costs.reduce(0, +))
    }

    func testReplacementCanCrossSegmentsAndOversizedBorrowIsBounded_CACHE_PT_058() throws {
        let cache = DefaultRenderedImageCache(costLimit: 100, probationCostLimit: 25)
        let image = try makeImage()
        let key = makeKey(0)

        cache.insert(image, for: key, cost: 10)
        cache.insert(image, for: key, cost: 40)
        XCTAssertNotNil(cache.image(for: key))
        XCTAssertEqual(cache.currentCost, 40)

        cache.insert(image, for: key, cost: 90)
        XCTAssertNotNil(cache.image(for: key))
        XCTAssertEqual(cache.currentCost, 90)

        let next = makeKey(1)
        cache.insert(image, for: next, cost: 10)
        XCTAssertNil(cache.image(for: key))
        XCTAssertNotNil(cache.image(for: next))
        XCTAssertLessThanOrEqual(cache.currentCost, 100)
    }

    func testLargeOneHitScanUsesSingleProbationSlotAndPreservesProvenMain_CACHE_PT_065() throws {
        let cache = DefaultRenderedImageCache(costLimit: 100, probationCostLimit: 25)
        let image = try makeImage()
        let hot = makeKey(0)
        let lowValue = makeKey(1)

        cache.insert(image, for: hot, cost: 20)
        XCTAssertNotNil(cache.image(for: hot))
        cache.insert(image, for: hot, cost: 60)
        cache.insert(image, for: lowValue, cost: 20)
        XCTAssertEqual(cache.currentCost, 80)

        cache.insert(image, for: makeKey(2), cost: 40)
        XCTAssertEqual(cache.currentCost, 100, "first large-probation admit must preserve hot main")
        XCTAssertEqual(cache.count, 2, "first large-probation admit must replace ordinary probation only")
        for index in 3..<102 {
            cache.insert(image, for: makeKey(index), cost: 40)
        }

        // Large first-hit identities replace one another in a dedicated probation slot. They
        // reclaim ordinary probation before forcing proven main eviction, so a long hero-image
        // scan cannot masquerade as 100 independently proven main-cache residents.
        XCTAssertNotNil(cache.image(for: hot))
        XCTAssertNil(cache.image(for: lowValue))
        XCTAssertNil(cache.image(for: makeKey(2)))
        XCTAssertEqual(cache.currentCost, 100)
        XCTAssertEqual(cache.count, 2)
        // Do not read the latest large identity: warning reclaim must still classify it as a
        // first-hit owner and discard it before the proven main resident.
        let summary = cache.reclaimLowValueAndReport()
        XCTAssertEqual(summary.itemCount, 1)
        XCTAssertEqual(summary.costBytes, 40)
        XCTAssertNotNil(cache.image(for: hot))
        XCTAssertEqual(cache.currentCost, 60)
        XCTAssertEqual(cache.count, 1)
    }

    func testPurgeReportsResidentTiersWithoutDoubleCounting_CACHE_PT_059() throws {
        let cache = DefaultRenderedImageCache(costLimit: 100, probationCostLimit: 25)
        let image = try makeImage()
        let promoted = makeKey(0)
        let probation = makeKey(1)
        cache.insert(image, for: promoted, cost: 5)
        cache.insert(image, for: probation, cost: 7)
        XCTAssertNotNil(cache.image(for: promoted))

        let summary = cache.removeAllAndReport()

        XCTAssertEqual(summary.itemCount, 2)
        XCTAssertEqual(summary.costBytes, 12)
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.currentCost, 0)
    }

    func testWarningReclaimDropsProbationButPreservesPromotedMain_CACHE_PT_063() throws {
        let cache = DefaultRenderedImageCache(costLimit: 100, probationCostLimit: 25)
        let image = try makeImage()
        let promoted = makeKey(0)
        let probation = makeKey(1)
        cache.insert(image, for: promoted, cost: 5)
        cache.insert(image, for: probation, cost: 7)
        XCTAssertNotNil(cache.image(for: promoted))

        let summary = cache.reclaimLowValueAndReport()

        XCTAssertEqual(summary.itemCount, 1)
        XCTAssertEqual(summary.costBytes, 7)
        XCTAssertNotNil(cache.image(for: promoted))
        XCTAssertNil(cache.image(for: probation))
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.currentCost, 5)
    }

    func testWarningReclaimDropsUnprovenLargeProbation_CACHE_PT_064() throws {
        let cache = DefaultRenderedImageCache(costLimit: 100, probationCostLimit: 25)
        let image = try makeImage()
        let oversized = makeKey(0)
        cache.insert(image, for: oversized, cost: 90)
        XCTAssertEqual(cache.currentCost, 90)

        let summary = cache.reclaimLowValueAndReport()

        XCTAssertEqual(summary.itemCount, 1)
        XCTAssertEqual(summary.costBytes, 90)
        XCTAssertNil(cache.image(for: oversized))
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.currentCost, 0)
    }

    func testDefaultMainCountGovernorBoundsProvenThumbnailSet_CACHE_PT_066() throws {
        let cache = DefaultRenderedImageCache(costLimit: 64 * 1024 * 1024)
        let image = try makeImage()
        let keys = (0..<17).map { makeKey($0) }

        for key in keys.prefix(16) {
            cache.insert(image, for: key, cost: 320 * 240 * 4)
            XCTAssertNotNil(cache.image(for: key))
        }
        XCTAssertEqual(cache.count, 16)

        // Reuse must participate in the identity-only governor. Count pressure may evict one
        // cold proven resident, but it must not override the main SIEVE by forcing out a hot key.
        XCTAssertNotNil(cache.image(for: keys[0]))
        cache.insert(image, for: keys[16], cost: 320 * 240 * 4)
        XCTAssertNotNil(cache.image(for: keys[16]))

        XCTAssertEqual(cache.count, 16)
        XCTAssertNotNil(cache.image(for: keys[0]))
        XCTAssertNotNil(cache.image(for: keys[16]))
        let coldVictimCount = keys[1..<16].reduce(into: 0) { count, key in
            if cache.image(for: key) == nil { count += 1 }
        }
        XCTAssertEqual(coldVictimCount, 1)
    }

    func testConcurrentPromotionAndRemovalCannotSurviveFinalRemove_CACHE_PT_061() throws {
        let cache = DefaultRenderedImageCache(costLimit: 100, probationCostLimit: 25)
        let image = try makeImage()
        let key = makeKey(0)
        cache.insert(image, for: key, cost: 5)

        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if index.isMultiple(of: 3) {
                cache.remove(key)
                cache.insert(image, for: key, cost: 5)
            } else {
                _ = cache.image(for: key)
            }
        }
        cache.remove(key)

        XCTAssertNil(cache.image(for: key))
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.currentCost, 0)
    }

    func testNamespacePredicateRemovalClearsResidentTiers_CACHE_PT_062() throws {
        let cache = DefaultRenderedImageCache(costLimit: 100, probationCostLimit: 25)
        let image = try makeImage()
        let accountAHot = makeKey(0, appID: "account-a")
        let accountAProbation = makeKey(1, appID: "account-a")
        let accountB = makeKey(2, appID: "account-b")
        cache.insert(image, for: accountAHot, cost: 5)
        cache.insert(image, for: accountAProbation, cost: 5)
        cache.insert(image, for: accountB, cost: 5)
        XCTAssertNotNil(cache.image(for: accountAHot))

        cache.removeAll { $0.namespace == accountAHot.namespace }

        XCTAssertNil(cache.image(for: accountAHot))
        XCTAssertNil(cache.image(for: accountAProbation))
        XCTAssertNotNil(cache.image(for: accountB))
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.currentCost, 5)
    }

    private func makeImage() throws -> DecodedImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        return DecodedImage(cgImage: try XCTUnwrap(context.makeImage()))
    }

    private func makeKey(
        _ index: Int,
        appID: String = "rendered-cache-tests"
    ) -> RenderedImageCacheKey {
        let contentID = ContentID(data: Data("rendered-cache-\(index)".utf8))
        let decodeKey = DecodeKey(
            contentID: contentID,
            targetWidth: 1,
            targetHeight: 1,
            contentMode: .fit,
            geometryPolicyFingerprint: "rendered-cache-tests-v1",
            colorPolicy: .convertToSRGB,
            codecContractVersion: 1,
            codecFingerprint: "rendered-cache-tests-v1"
        )
        return RenderedImageCacheKey(
            namespace: SecurityNamespaceID.publicNamespace(appID: appID),
            generation: NamespaceGeneration(1),
            renderKey: RenderKey(decodeKey: decodeKey, renderVersion: 1)
        )
    }
}
