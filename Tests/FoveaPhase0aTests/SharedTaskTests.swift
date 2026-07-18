import FoveaCore
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class SharedTaskTests: XCTestCase {
  func testLastSubscriberCancelsUnderlyingTaskOnce_SCHED_PT_004() async throws {
    let registry = SharedImageTaskRegistry()
    let variant = FetchVariantKey(
      source: LogicalSourceID("https://example.com/a"),
      namespace: SecurityNamespaceID.publicNamespace(appID: "tests")
    )
    let key = FetchExecutionKey(variant: variant, resolvedLocator: "https://example.com/a")
    let operation: @Sendable () async throws -> DecodedImage = {
      try await Task.sleep(for: .seconds(10))
      throw CancellationError()
    }
    let first = await registry.subscribe(key: key, operation: operation)
    let second = await registry.subscribe(key: key, operation: operation)
    let initialSubscribers = await registry.subscriberCount(for: key)
    XCTAssertEqual(initialSubscribers, 2)

    await first.cancel()
    let remainingSubscribers = await registry.subscriberCount(for: key)
    let earlyCancellationCount = await registry.cancellationCount(for: key)
    XCTAssertEqual(remainingSubscribers, 1)
    XCTAssertEqual(earlyCancellationCount, 0)

    await second.cancel()
    await second.cancel()
    let finalSubscribers = await registry.subscriberCount(for: key)
    let finalCancellationCount = await registry.cancellationCount(for: key)
    XCTAssertEqual(finalSubscribers, 0)
    XCTAssertEqual(finalCancellationCount, 1)
  }

  func testCompletionAndReleaseDoNotDoubleCancel_SCHED_PT_010() async throws {
    let registry = SharedImageTaskRegistry()
    let variant = FetchVariantKey(
      source: LogicalSourceID("https://example.com/b"),
      namespace: SecurityNamespaceID.publicNamespace(appID: "tests")
    )
    let key = FetchExecutionKey(variant: variant, resolvedLocator: "https://example.com/b")
    let data = try makePNG(width: 2, height: 2)
    let image = try ImageIOImageDecoder().decode(
      data: data, target: try TargetPixels(width: 2, height: 2))
    let subscription = await registry.subscribe(key: key) { image }
    _ = try await subscription.value()
    await subscription.cancel()
    await subscription.cancel()
    let cancellationCount = await registry.cancellationCount(for: key)
    XCTAssertLessThanOrEqual(cancellationCount, 1)
  }
  func testCompletedTaskCannotBeJoinedByNewSubscriber() async throws {
    let registry = SharedImageTaskRegistry()
    let variant = FetchVariantKey(
      source: LogicalSourceID("https://example.com/terminal"),
      namespace: SecurityNamespaceID.publicNamespace(appID: "tests")
    )
    let key = FetchExecutionKey(variant: variant, resolvedLocator: "https://example.com/terminal")
    let counter = OperationCounter()
    let image = try ImageIOImageDecoder().decode(
      data: makePNG(width: 2, height: 2),
      target: TargetPixels(width: 2, height: 2)
    )

    let first = await registry.subscribe(key: key) {
      await counter.increment()
      return image
    }
    _ = try await first.value()

    let second = await registry.subscribe(key: key) {
      await counter.increment()
      return image
    }
    _ = try await second.value()
    let operationCount = await counter.value()
    XCTAssertEqual(operationCount, 2)
  }

}

private actor OperationCounter {
  private var count = 0
  func increment() { count += 1 }
  func value() -> Int { count }
}
