import FoveaCore
import ImageCraftCore
import XCTest

final class PrioritySchedulingTests: XCTestCase {
  func testSharedTaskEffectivePriorityRisesAndFallsWithSubscribers_SCHED_PT_003() async throws {
    let registry = SharedTaskRegistry<String, Int>()
    let gate = AsyncTestGate()
    let low = await registry.subscribe(key: "shared", priority: .low) { _ in
      await gate.wait()
      return 42
    }
    let high = await registry.subscribe(key: "shared", priority: .userInitiated) { _ in 0 }

    let elevatedPriority = await registry.effectivePriority(for: "shared")
    XCTAssertEqual(elevatedPriority, .userInitiated)
    await high.cancel()
    let reducedPriority = await registry.effectivePriority(for: "shared")
    XCTAssertEqual(reducedPriority, .low)

    await gate.open()
    let value = try await low.value()
    XCTAssertEqual(value, 42)
    await low.cancel()
  }

  func testHigherPriorityWaiterOvertakesLowerPriorityWaiter_SCHED_PT_003() async throws {
    let pool = AsyncPermitPool(limit: 1, queueLimit: 8)
    let blocker = try await pool.acquire()
    let order = StringOrderRecorder()
    let low = Task {
      let permit = try await pool.acquire(priority: .low)
      await order.append("low")
      await permit.release()
    }
    await waitForQueuedCount(1, in: pool)
    let high = Task {
      let permit = try await pool.acquire(priority: .high)
      await order.append("high")
      await permit.release()
    }
    await waitForQueuedCount(2, in: pool)

    await blocker.release()
    try await low.value
    try await high.value

    let values = await order.values()
    XCTAssertEqual(values, ["high", "low"])
  }

  func testDynamicSharedPriorityReordersQueuedPermit_SCHED_PT_003() async throws {
    let pool = AsyncPermitPool(limit: 1, queueLimit: 8)
    let blocker = try await pool.acquire()
    let order = StringOrderRecorder()
    let registry = SharedTaskRegistry<String, Void>()
    let shared = await registry.subscribe(key: "shared", priority: .low) { control in
      let permit = try await pool.acquire(
        priority: await control.currentPriority(),
        priorityUpdates: await control.updates()
      )
      await order.append("shared")
      await permit.release()
    }
    await waitForQueuedCount(1, in: pool)
    let normal = Task {
      let permit = try await pool.acquire(priority: .normal)
      await order.append("normal")
      await permit.release()
    }
    await waitForQueuedCount(2, in: pool)
    let high = await registry.subscribe(key: "shared", priority: .userInitiated) { _ in }
    await waitUntil {
      await registry.effectivePriority(for: "shared") == .userInitiated
    }
    await waitUntil {
      await pool.queuedPriorities().contains(.userInitiated)
    }

    await blocker.release()
    _ = try await shared.value()
    _ = try await high.value()
    try await normal.value
    await shared.cancel()
    await high.cancel()

    let values = await order.values()
    XCTAssertEqual(values, ["shared", "normal"])
  }

  func testLowPriorityWaiterCannotStarveBeyondBypassLimit_SCHED_PT_007() async throws {
    let pool = AsyncPermitPool(limit: 1, queueLimit: 16)
    let blocker = try await pool.acquire()
    let order = StringOrderRecorder()
    let low = Task {
      let permit = try await pool.acquire(priority: .background)
      await order.append("low")
      await permit.release()
    }
    await waitForQueuedCount(1, in: pool)

    var highTasks: [Task<Void, Error>] = []
    for index in 0..<9 {
      highTasks.append(
        Task {
          let permit = try await pool.acquire(priority: .userInitiated)
          await order.append("high-\(index)")
          await permit.release()
        })
    }
    await waitForQueuedCount(10, in: pool)
    await blocker.release()
    try await low.value
    for task in highTasks { try await task.value }

    let values = await order.values()
    let lowIndex = try XCTUnwrap(values.firstIndex(of: "low"))
    XCTAssertLessThanOrEqual(lowIndex, 8)
  }

  func testPriorityDoesNotChangeRequestIdentity() throws {
    let url = try XCTUnwrap(URL(string: "https://example.test/priority.png"))
    let low = try ImageRequest.publicImage(
      url: url,
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests",
      priority: .low
    )
    let high = try ImageRequest.publicImage(
      url: url,
      target: try TargetPixels(width: 20, height: 20),
      appID: "tests",
      priority: .userInitiated
    )

    XCTAssertEqual(low.fetchBaseKey, high.fetchBaseKey)
    XCTAssertEqual(low.fetchVariantKey, high.fetchVariantKey)
    XCTAssertEqual(low.fetchExecutionKey, high.fetchExecutionKey)
  }

  private func waitForQueuedCount(_ expected: Int, in pool: AsyncPermitPool) async {
    await waitUntil { await pool.queuedCount() == expected }
  }

  private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
  ) async {
    for _ in 0..<2_000 {
      if await predicate() { return }
      try? await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Condition did not become true")
  }
}

private actor AsyncTestGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}

private actor StringOrderRecorder {
  private var storage: [String] = []
  func append(_ value: String) { storage.append(value) }
  func values() -> [String] { storage }
}
