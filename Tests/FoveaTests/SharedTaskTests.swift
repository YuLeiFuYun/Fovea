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

  func testMismatchedCompletionCannotRemoveActiveTask() async throws {
    let registry = SharedTaskRegistry<String, Int>()
    let gate = HandoffOperationGate()
    let first = await registry.subscribe(key: "task-id-guard") {
      try await gate.run()
    }
    await gate.waitUntilStarted()

    await registry.completed(key: "task-id-guard", taskID: UUID())
    let countAfterMismatchedCompletion = await registry.subscriberCount(for: "task-id-guard")
    XCTAssertEqual(countAfterMismatchedCompletion, 1)

    let second = await registry.subscribe(key: "task-id-guard") { 99 }
    XCTAssertTrue(second.wasJoined)
    await gate.release()

    async let firstValue = first.value()
    async let secondValue = second.value()
    let values = try await [firstValue, secondValue]
    XCTAssertEqual(values, [42, 42])
    let operationCount = await gate.operationCount
    XCTAssertEqual(operationCount, 1)
    await first.cancel()
    await second.cancel()
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

  func testSeededSubscriberExitSoakPreservesRegistryInvariants_SCHED_PT_014() async throws {
    for seed in 1...128 {
      var random = SeededRandomNumberGenerator(seed: UInt64(seed))
      let registry = SharedTaskRegistry<String, Int>()
      let gate = HandoffOperationGate()
      let subscriberCount = Int.random(in: 2...10, using: &random)
      var subscriptions: [SharedTaskSubscription<String, Int>] = []
      var priorities: [ImageRequestPriority] = []

      for _ in 0..<subscriberCount {
        let priority = ImageRequestPriority.allCases.randomElement(using: &random) ?? .normal
        priorities.append(priority)
        subscriptions.append(
          await registry.subscribe(key: "seeded-soak", priority: priority) {
            try await gate.run()
          }
        )
      }
      await gate.waitUntilStarted()
      let operationCount = await gate.operationCount
      XCTAssertEqual(operationCount, 1, "seed=\(seed)")
      let initialPriority = await registry.effectivePriority(for: "seeded-soak")
      XCTAssertEqual(initialPriority, priorities.max(), "seed=\(seed)")

      var exitOrder = Array(subscriptions.indices)
      exitOrder.shuffle(using: &random)
      var active = Set(subscriptions.indices)
      for index in exitOrder {
        await subscriptions[index].cancel()
        active.remove(index)
        let count = await registry.subscriberCount(for: "seeded-soak")
        XCTAssertEqual(count, active.count, "seed=\(seed), index=\(index)")
        if !active.isEmpty {
          let expected = active.map { priorities[$0] }.max()
          let effective = await registry.effectivePriority(for: "seeded-soak")
          XCTAssertEqual(effective, expected, "seed=\(seed), index=\(index)")
        }
      }

      let cancellations = await registry.cancellationCount(for: "seeded-soak")
      XCTAssertEqual(cancellations, 1, "seed=\(seed)")
      for _ in 0..<100 {
        if await gate.wasCancelled { break }
        await Task.yield()
      }
      let wasCancelled = await gate.wasCancelled
      XCTAssertTrue(wasCancelled, "seed=\(seed)")
    }
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

private struct SeededRandomNumberGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
  }

  mutating func next() -> UInt64 {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return state
  }
}
