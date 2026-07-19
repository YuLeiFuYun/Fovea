import FoveaCore
import XCTest

final class SharedTaskTests: XCTestCase {
  func testCancelledSubscriberReturnsBeforeSharedTaskCompletes() async throws {
    let registry = SharedTaskRegistry<String, Int>()
    let first = await registry.subscribe(key: "prompt-cancel") {
      try await Task.sleep(for: .milliseconds(250))
      return 42
    }
    let survivor = await registry.subscribe(key: "prompt-cancel") { 0 }

    let started = ContinuousClock.now
    let cancelled = Task { try await first.value() }
    try await Task.sleep(for: .milliseconds(20))
    cancelled.cancel()
    await first.cancel()

    do {
      _ = try await cancelled.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // 预期会进入取消分支。
    }
    let elapsed = started.duration(to: .now)
    XCTAssertLessThan(elapsed, .milliseconds(150))
    let survivorValue = try await survivor.value()
    XCTAssertEqual(survivorValue, 42)
    await survivor.cancel()
  }

  func testDetachedSubscriberLeavesTaskAvailableForLateHandoff() async throws {
    let registry = SharedTaskRegistry<String, Int>()
    let gate = HandoffOperationGate()
    let first = await registry.subscribe(key: "refresh-handoff") {
      try await gate.run()
    }
    await gate.waitUntilStarted()

    await first.detach()
    let subscribersDuringHandoff = await registry.subscriberCount(for: "refresh-handoff")
    let cancellationsDuringHandoff = await registry.cancellationCount(for: "refresh-handoff")
    XCTAssertEqual(subscribersDuringHandoff, 0)
    XCTAssertEqual(cancellationsDuringHandoff, 0)

    let second = await registry.subscribe(key: "refresh-handoff") { 99 }
    XCTAssertTrue(second.wasJoined)
    await gate.release()

    let value = try await second.value()
    let operationCount = await gate.operationCount
    let wasCancelled = await gate.wasCancelled
    XCTAssertEqual(value, 42)
    XCTAssertEqual(operationCount, 1)
    XCTAssertFalse(wasCancelled)
    await second.detach()
  }

  func testLastSubscriberCancelsUnderlyingTaskOnce_SCHED_PT_004() async throws {
    let registry = SharedTaskRegistry<FetchExecutionKey, Int>()
    let key = makeKey("https://example.com/a")
    let operation: @Sendable () async throws -> Int = {
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
    let registry = SharedTaskRegistry<FetchExecutionKey, Int>()
    let key = makeKey("https://example.com/b")
    let subscription = await registry.subscribe(key: key) { 42 }
    let value = try await subscription.value()
    XCTAssertEqual(value, 42)
    await subscription.cancel()
    await subscription.cancel()
    let cancellationCount = await registry.cancellationCount(for: key)
    XCTAssertLessThanOrEqual(cancellationCount, 1)
  }

  func testCompletedTaskCannotBeJoinedByNewSubscriber() async throws {
    let registry = SharedTaskRegistry<FetchExecutionKey, Int>()
    let key = makeKey("https://example.com/terminal")
    let counter = OperationCounter()

    let first = await registry.subscribe(key: key) {
      await counter.increment()
      return 1
    }
    _ = try await first.value()

    let second = await registry.subscribe(key: key) {
      await counter.increment()
      return 2
    }
    _ = try await second.value()
    let operationCount = await counter.value()
    XCTAssertEqual(operationCount, 2)
  }

  private func makeKey(_ locator: String) -> FetchExecutionKey {
    let base = FetchBaseKey(
      source: LogicalSourceID(locator),
      namespace: SecurityNamespaceID.publicNamespace(appID: "tests")
    )
    return FetchExecutionKey(
      base: base,
      selectedVariant: FetchVariantKey(base: base),
      resolvedLocator: locator,
      requestHeaderFingerprint: "headers"
    )
  }
}

private actor OperationCounter {
  private var count = 0
  func increment() { count += 1 }
  func value() -> Int { count }
}

private actor HandoffOperationGate {
  private(set) var operationCount = 0
  private(set) var wasCancelled = false
  private var started = false
  private var released = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func run() async throws -> Int {
    operationCount += 1
    started = true
    for waiter in startWaiters { waiter.resume() }
    startWaiters.removeAll()
    await withTaskCancellationHandler {
      if !released {
        await withCheckedContinuation { releaseWaiters.append($0) }
      }
    } onCancel: {
      Task { await self.cancelled() }
    }
    try Task.checkCancellation()
    return 42
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func release() {
    released = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
  }

  private func cancelled() {
    wasCancelled = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
  }
}
