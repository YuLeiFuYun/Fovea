import AkashicCore
import CryptoKit
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaStorage
import ImageCraftCore
import XCTest

final class DerivedRasterCreationCoordinatorTests: XCTestCase {
    func testExactIdentityIsSingleFlightAndCanRescheduleAfterCompletion_W11_PT_022() async throws {
        let fixture = try makeFixture(label: "single", namespace: "account-a", generation: 1)
        let gate = AsyncTestGate()
        let creates = AsyncTestCounter()
        let publishes = AsyncTestCounter()
        let coordinator = DerivedRasterCreationCoordinator()
        let initialActivity = await coordinator.activitySnapshot()

        let first = await coordinator.schedule(
            key: fixture.key,
            create: {
                await creates.increment()
                await gate.wait()
                return fixture.product
            },
            publish: { _, _ in await publishes.increment() }
        )
        let duplicate = await coordinator.schedule(
            key: fixture.key,
            create: { fixture.product },
            publish: { _, _ in await publishes.increment() }
        )
        XCTAssertTrue(first)
        XCTAssertFalse(duplicate)
        let activeBeforeOpen = await coordinator.activeCount()
        XCTAssertEqual(activeBeforeOpen, 1)
        await waitUntil { await creates.currentValue() == 1 }
        await gate.open()
        _ = await coordinator.waitUntilQuiescent(after: initialActivity)
        let createCount = await creates.currentValue()
        let publishCount = await publishes.currentValue()
        XCTAssertEqual(createCount, 1)
        XCTAssertEqual(publishCount, 1)

        let rescheduleBaseline = await coordinator.activitySnapshot()
        let rescheduled = await coordinator.schedule(
            key: fixture.key,
            create: { fixture.product },
            publish: { _, _ in await publishes.increment() }
        )
        XCTAssertTrue(rescheduled)
        _ = await coordinator.waitUntilQuiescent(after: rescheduleBaseline)
        let finalPublishCount = await publishes.currentValue()
        XCTAssertEqual(finalPublishCount, 2)
    }

    func testEntryCapacityRejectsDistinctWorkWhileFull_W11_PT_037() async throws {
        let firstFixture = try makeFixture(
            label: "capacity-first",
            namespace: "account-a",
            generation: 1
        )
        let secondFixture = try makeFixture(
            label: "capacity-second",
            namespace: "account-a",
            generation: 1
        )
        let gate = AsyncTestGate()
        let started = AsyncTestCounter()
        let coordinator = DerivedRasterCreationCoordinator(maximumEntryCount: 1)
        let initialActivity = await coordinator.activitySnapshot()

        let first = await coordinator.schedule(
            key: firstFixture.key,
            create: {
                await started.increment()
                await gate.wait()
                return firstFixture.product
            },
            publish: { _, _ in }
        )
        await waitUntil { await started.currentValue() == 1 }
        let second = await coordinator.schedule(
            key: secondFixture.key,
            create: { secondFixture.product },
            publish: { _, _ in }
        )

        XCTAssertTrue(first)
        XCTAssertFalse(second)
        let activeCount = await coordinator.activeCount()
        XCTAssertEqual(activeCount, 1)
        await gate.open()
        _ = await coordinator.waitUntilQuiescent(after: initialActivity)
    }

    func testCancelClosesPublicationBeforeBackgroundCreationReturns_W11_PT_023() async throws {
        let fixture = try makeFixture(label: "cancel", namespace: "account-a", generation: 1)
        let gate = AsyncTestGate()
        let started = AsyncTestCounter()
        let publishes = AsyncTestCounter()
        let coordinator = DerivedRasterCreationCoordinator()

        let scheduled = await coordinator.schedule(
            key: fixture.key,
            create: {
                await started.increment()
                await gate.wait()
                return fixture.product
            },
            publish: { _, _ in await publishes.increment() }
        )
        XCTAssertTrue(scheduled)
        await waitUntil { await started.currentValue() == 1 }
        await coordinator.cancel(key: fixture.key)
        let activeAfterCancel = await coordinator.activeCount()
        XCTAssertEqual(activeAfterCancel, 0)
        await gate.open()
        try await testSleep(.milliseconds(20))
        let publishCount = await publishes.currentValue()
        XCTAssertEqual(publishCount, 0)
    }

    func testRevokeCancelsOnlyOlderGenerationInSelectedNamespace_W11_PT_024() async throws {
        let old = try makeFixture(label: "old", namespace: "account-a", generation: 1)
        let current = try makeFixture(label: "current", namespace: "account-a", generation: 2)
        let other = try makeFixture(label: "other", namespace: "account-b", generation: 1)
        let gate = AsyncTestGate()
        let started = AsyncTestCounter()
        let published = AsyncDigestSet()
        let coordinator = DerivedRasterCreationCoordinator()
        let initialActivity = await coordinator.activitySnapshot()

        for fixture in [old, current, other] {
            let scheduled = await coordinator.schedule(
                key: fixture.key,
                create: {
                    await started.increment()
                    await gate.wait()
                    return fixture.product
                },
                publish: { product, _ in
                    await published.insert(product.record.artifactKeyDigest)
                }
            )
            XCTAssertTrue(scheduled)
        }
        await waitUntil { await started.currentValue() == 3 }
        await coordinator.revoke(
            namespaceFingerprint: old.key.namespaceFingerprint,
            before: NamespaceGeneration(2)
        )
        let containsOld = await coordinator.contains(old.key)
        let containsCurrent = await coordinator.contains(current.key)
        let containsOther = await coordinator.contains(other.key)
        XCTAssertFalse(containsOld)
        XCTAssertTrue(containsCurrent)
        XCTAssertTrue(containsOther)
        await gate.open()
        _ = await coordinator.waitUntilQuiescent(after: initialActivity)

        let oldPublished = await published.contains(old.key.digestHex)
        let currentPublished = await published.contains(current.key.digestHex)
        let otherPublished = await published.contains(other.key.digestHex)
        XCTAssertFalse(oldPublished)
        XCTAssertTrue(currentPublished)
        XCTAssertTrue(otherPublished)
    }

    func testAspectFitOutputInsideRequestedTargetCanPublish_W11_PT_027() async throws {
        let fixture = try makeFixture(
            label: "aspect-fit",
            namespace: "account-a",
            generation: 1,
            targetWidth: 1170,
            targetHeight: 780,
            outputWidth: 1040,
            outputHeight: 780
        )
        let publishes = AsyncTestCounter()
        let coordinator = DerivedRasterCreationCoordinator()
        let initialActivity = await coordinator.activitySnapshot()
        let scheduled = await coordinator.schedule(
            key: fixture.key,
            create: { fixture.product },
            publish: { _, _ in await publishes.increment() }
        )
        XCTAssertTrue(scheduled)
        _ = await coordinator.waitUntilQuiescent(after: initialActivity)
        let publishCount = await publishes.currentValue()
        XCTAssertEqual(publishCount, 1)
    }

    func testTamperedContainerWithMatchingRecordIdentityIsNeverPublished_W11_PT_028() async throws {
        let fixture = try makeFixture(label: "tampered", namespace: "account-a", generation: 1)
        var tampered = fixture.product.container
        tampered[tampered.count - 1] ^= 0xFF
        let product = DerivedRasterCreationProduct(
            container: tampered,
            record: fixture.product.record
        )
        let publishes = AsyncTestCounter()
        let coordinator = DerivedRasterCreationCoordinator()
        let initialActivity = await coordinator.activitySnapshot()
        let scheduled = await coordinator.schedule(
            key: fixture.key,
            create: { product },
            publish: { _, _ in await publishes.increment() }
        )
        XCTAssertTrue(scheduled)
        _ = await coordinator.waitUntilQuiescent(after: initialActivity)
        let publishCount = await publishes.currentValue()
        XCTAssertEqual(publishCount, 0)
    }

    func testMismatchedCreationProductIsNeverPublished_W11_PT_025() async throws {
        let requested = try makeFixture(label: "requested", namespace: "account-a", generation: 1)
        let wrong = try makeFixture(label: "wrong", namespace: "account-a", generation: 1)
        let publishes = AsyncTestCounter()
        let coordinator = DerivedRasterCreationCoordinator()
        let initialActivity = await coordinator.activitySnapshot()

        let scheduled = await coordinator.schedule(
            key: requested.key,
            create: { wrong.product },
            publish: { _, _ in await publishes.increment() }
        )
        XCTAssertTrue(scheduled)
        _ = await coordinator.waitUntilQuiescent(after: initialActivity)
        let publishCount = await publishes.currentValue()
        XCTAssertEqual(publishCount, 0)
    }

    private struct Fixture: Sendable {
        let key: DerivedRasterArtifactKey
        let product: DerivedRasterCreationProduct
    }

    private func makeFixture(
        label: String,
        namespace: String,
        generation: UInt64,
        targetWidth: Int = 31,
        targetHeight: Int = 19,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil
    ) throws -> Fixture {
        let width = outputWidth ?? targetWidth
        let height = outputHeight ?? targetHeight
        let request = try ImageRequest(
            url: XCTUnwrap(URL(string: "https://example.test/\(label).jpg")),
            logicalSource: LogicalSourceID("asset:\(label)"),
            target: TargetPixels(width: targetWidth, height: targetHeight),
            colorPolicy: .convertToSRGB,
            namespace: SecurityNamespaceID(namespace)
        )
        let namespaceGeneration = NamespaceGeneration(generation)
        let originalContent = ContentID(data: Data("original:\(label)".utf8))
        let representation = RepresentationRecord(
            securityNamespace: namespace,
            namespaceGeneration: generation,
            baseKeyDigest: request.fetchBaseKey.digestHex,
            variantKeyDigest: request.fetchVariantKey.digestHex,
            statusCode: 200,
            requestTime: Date(timeIntervalSinceReferenceDate: 1000),
            responseTime: Date(timeIntervalSinceReferenceDate: 1001),
            responseDate: Date(timeIntervalSinceReferenceDate: 1001),
            expiresAt: Date(timeIntervalSinceReferenceDate: 20000),
            etag: nil,
            lastModified: nil,
            disposition: .reusable,
            contentID: originalContent.description,
            payloadLength: originalContent.byteCount,
            contentType: "image/jpeg"
        )
        let decodeKey = DecodeKey(
            contentID: originalContent,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            contentMode: request.contentMode,
            geometryPolicyFingerprint: request.geometryPolicyFingerprint,
            colorPolicy: request.colorPolicy,
            codecContractVersion: 1,
            codecFingerprint: "imagecraft-imageio-v1"
        )
        let renderKey = RenderKey(decodeKey: decodeKey, renderVersion: 1)
        let key = try XCTUnwrap(
            DerivedRasterArtifactKey(
                request: request,
                representation: representation,
                namespaceGeneration: namespaceGeneration,
                renderKey: renderKey,
                format: DerivedRasterContainer.formatIdentity
            )
        )

        var pixels = Data(count: width * height * 3)
        for pixel in 0..<(width * height) {
            let offset = pixel * 3
            pixels[offset] = UInt8(truncatingIfNeeded: pixel * 13 + label.utf8.count)
            pixels[offset + 1] = UInt8(truncatingIfNeeded: pixel * 29 + 3)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: pixel * 47 + 7)
        }
        let container = try DerivedRasterContainer.encode(
            pixelData: pixels,
            width: width,
            height: height
        )
        let format = DerivedRasterContainer.formatIdentity
        let record = try DerivedRasterRecord(
            artifactKeyDigest: key.digestHex,
            baseKeyDigest: key.baseKeyDigest,
            variantKeyDigest: key.variantKeyDigest,
            namespaceFingerprint: key.namespaceFingerprint,
            namespaceGeneration: key.namespaceGeneration.value,
            containerContentID: BlobDigest.sha256(of: container).canonicalString,
            containerByteCount: container.count,
            formatIdentifier: format.identifier,
            formatSemanticVersion: format.semanticVersion,
            pixelLayoutFingerprint: format.pixelLayoutFingerprint,
            pixelDigestHex: sha256(pixels),
            pixelWidth: width,
            pixelHeight: height,
            createdAt: Date(timeIntervalSinceReferenceDate: 2000)
        )
        return Fixture(
            key: key,
            product: DerivedRasterCreationProduct(container: container, record: record)
        )
    }

    private func waitUntil(
        timeout: TestDuration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let deadline = testDeadline(after: timeout)
        while testUptimeNanoseconds() < deadline {
            if await condition() {
                return
            }
            try? await testSleep(.milliseconds(2))
        }
        XCTFail("condition did not become true before timeout")
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private actor AsyncTestCounter {
    private var value = 0
    func increment() {
        value += 1
    }

    func currentValue() -> Int {
        value
    }
}

private actor AsyncDigestSet {
    private var values: Set<String> = []
    func insert(_ value: String) {
        values.insert(value)
    }

    func contains(_ value: String) -> Bool {
        values.contains(value)
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
