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
        try await waitForQueuedCount(1, in: pool)
        let high = Task {
            let permit = try await pool.acquire(priority: .high)
            await order.append("high")
            await permit.release()
        }
        try await waitForQueuedCount(2, in: pool)

        await blocker.release()
        try await low.value
        try await high.value

        let values = await order.values()
        XCTAssertEqual(values, ["high", "low"])
    }

    func testEqualPriorityPrefersSmallerEstimatedWork_SCHED_PT_018() async throws {
        let pool = AsyncPermitPool(limit: 1, queueLimit: 8)
        let blocker = try await pool.acquire()
        let order = StringOrderRecorder()
        let large = Task {
            let permit = try await pool.acquire(
                priority: .normal,
                workEstimate: 1_000
            )
            await order.append("large")
            await permit.release()
        }
        try await waitForQueuedCount(1, in: pool)
        let small = Task {
            let permit = try await pool.acquire(
                priority: .normal,
                workEstimate: 10
            )
            await order.append("small")
            await permit.release()
        }
        try await waitForQueuedCount(2, in: pool)

        await blocker.release()
        try await large.value
        try await small.value

        let values = await order.values()
        XCTAssertEqual(values, ["small", "large"])
    }

    func testEqualPriorityEqualEstimatePreservesFIFO_SCHED_PT_018() async throws {
        let pool = AsyncPermitPool(limit: 1, queueLimit: 8)
        let blocker = try await pool.acquire()
        let order = StringOrderRecorder()
        let first = Task {
            let permit = try await pool.acquire(
                priority: .normal,
                workEstimate: 50
            )
            await order.append("first")
            await permit.release()
        }
        try await waitForQueuedCount(1, in: pool)
        let second = Task {
            let permit = try await pool.acquire(
                priority: .normal,
                workEstimate: 50
            )
            await order.append("second")
            await permit.release()
        }
        try await waitForQueuedCount(2, in: pool)

        await blocker.release()
        try await first.value
        try await second.value

        let values = await order.values()
        XCTAssertEqual(values, ["first", "second"])
    }

    func testLargeEqualPriorityWorkCannotStarveBeyondBypassLimit_SCHED_PT_019() async throws {
        let pool = AsyncPermitPool(limit: 1, queueLimit: 16)
        let blocker = try await pool.acquire()
        let order = StringOrderRecorder()
        let large = Task {
            let permit = try await pool.acquire(
                priority: .normal,
                workEstimate: 10_000
            )
            await order.append("large")
            await permit.release()
        }
        try await waitForQueuedCount(1, in: pool)

        var smallTasks: [Task<Void, Error>] = []
        for index in 0..<9 {
            smallTasks.append(
                Task {
                    let permit = try await pool.acquire(
                        priority: .normal,
                        workEstimate: 1
                    )
                    await order.append("small-\(index)")
                    await permit.release()
                }
            )
        }
        try await waitForQueuedCount(10, in: pool)

        await blocker.release()
        try await large.value
        for task in smallTasks {
            try await task.value
        }

        let values = await order.values()
        let largeIndex = try XCTUnwrap(values.firstIndex(of: "large"))
        XCTAssertLessThanOrEqual(largeIndex, AsyncPermitPool.maximumPriorityBypasses)
    }

    func testWeightedStarvedWaiterReservesCapacityAndDrainsFragments_SCHED_PT_020()
        async throws
    {
        let pool = AsyncPermitPool(limit: 4, queueLimit: 16)
        let longRunningAnchor = try await pool.acquire(units: 3)
        let fragment = try await pool.acquire(units: 1)
        let order = StringOrderRecorder()

        let wholeCapacity = Task {
            let permit = try await pool.acquire(
                units: 4,
                priority: .normal,
                workEstimate: 10_000
            )
            await order.append("whole-capacity")
            await permit.release()
        }
        try await waitForQueuedCount(1, in: pool)

        var smallTasks: [Task<Void, Error>] = []
        for index in 0..<9 {
            smallTasks.append(
                Task {
                    let permit = try await pool.acquire(
                        units: 1,
                        priority: .normal,
                        workEstimate: 1
                    )
                    await order.append("small-\(index)")
                    await permit.release()
                }
            )
        }
        try await waitForQueuedCount(10, in: pool)

        let bypassLimit = AsyncPermitPool.maximumPriorityBypasses
        await fragment.release()
        try await waitUntil("带权饥饿请求触发容量保留") {
            await order.values().count == bypassLimit
        }
        let beforeDrain = await order.values()
        XCTAssertEqual(beforeDrain.count, bypassLimit)
        XCTAssertTrue(beforeDrain.allSatisfy { $0.hasPrefix("small-") })

        // 保留建立后再到达的请求也不能走立即获取快路径穿透 drain 模式。
        let lateArrival = Task {
            let permit = try await pool.acquire(
                units: 1,
                priority: .userInitiated,
                workEstimate: 1
            )
            await order.append("late-arrival")
            await permit.release()
        }
        try await waitForQueuedCount(11 - bypassLimit, in: pool)
        let afterLateArrival = await order.values()
        XCTAssertEqual(afterLateArrival, beforeDrain)

        // 旧实现会继续把唯一空闲单位发给剩余小请求，使需要全部容量的请求无限等待。
        // 新状态机停止发放碎片容量，等待长期持有的三个单位释放后优先满足保留者。
        await longRunningAnchor.release()
        try await wholeCapacity.value
        for task in smallTasks { try await task.value }
        try await lateArrival.value

        let values = await order.values()
        let wholeIndex = try XCTUnwrap(values.firstIndex(of: "whole-capacity"))
        XCTAssertEqual(wholeIndex, bypassLimit)
        XCTAssertEqual(Set(values.prefix(wholeIndex)), Set(beforeDrain))
        XCTAssertEqual(values.count, 11)
        XCTAssertEqual(values.filter { $0.hasPrefix("small-") }.count, 9)
        let lateArrivalIndex = try XCTUnwrap(values.firstIndex(of: "late-arrival"))
        XCTAssertGreaterThan(lateArrivalIndex, wholeIndex)
    }

    func testStarvedCohortIsFIFOAndBlocksNonstarvedShortWork_SCHED_PT_019() async throws {
        let pool = AsyncPermitPool(limit: 1, queueLimit: 20)
        let blocker = try await pool.acquire()
        let order = StringOrderRecorder()

        let firstLarge = Task {
            let permit = try await pool.acquire(priority: .normal, workEstimate: 10_000)
            await order.append("large-1")
            await permit.release()
        }
        try await waitForQueuedCount(1, in: pool)
        let secondLarge = Task {
            let permit = try await pool.acquire(priority: .normal, workEstimate: 9_000)
            await order.append("large-2")
            await permit.release()
        }
        try await waitForQueuedCount(2, in: pool)

        var smallTasks: [Task<Void, Error>] = []
        for index in 0..<9 {
            smallTasks.append(
                Task {
                    let permit = try await pool.acquire(priority: .normal, workEstimate: 1)
                    await order.append("small-\(index)")
                    await permit.release()
                }
            )
            try await waitForQueuedCount(index + 3, in: pool)
        }

        await blocker.release()
        try await firstLarge.value
        try await secondLarge.value
        for task in smallTasks { try await task.value }

        let values = await order.values()
        let bypassLimit = AsyncPermitPool.maximumPriorityBypasses
        XCTAssertEqual(values.firstIndex(of: "large-1"), bypassLimit)
        XCTAssertEqual(values.firstIndex(of: "large-2"), bypassLimit + 1)
        XCTAssertEqual(values.last, "small-8")
    }

    func testPermitSequenceOverflowRebasesWithoutReorderingEqualPriorityWaiters() async throws {
        let pool = AsyncPermitPool(
            limit: 1,
            queueLimit: 4,
            initialSequence: UInt64.max - 1
        )
        let blocker = try await pool.acquire()
        let order = StringOrderRecorder()
        let first = Task {
            let permit = try await pool.acquire(priority: .normal)
            await order.append("first")
            await permit.release()
        }
        try await waitForQueuedCount(1, in: pool)
        let second = Task {
            let permit = try await pool.acquire(priority: .normal)
            await order.append("second")
            await permit.release()
        }
        try await waitForQueuedCount(2, in: pool)

        await blocker.release()
        try await first.value
        try await second.value

        let values = await order.values()
        XCTAssertEqual(values, ["first", "second"])
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
        try await waitForQueuedCount(1, in: pool)
        let normal = Task {
            let permit = try await pool.acquire(priority: .normal)
            await order.append("normal")
            await permit.release()
        }
        try await waitForQueuedCount(2, in: pool)
        let high = await registry.subscribe(key: "shared", priority: .userInitiated) { _ in }
        try await waitUntil("共享任务有效优先级提升") {
            await registry.effectivePriority(for: "shared") == .userInitiated
        }
        try await waitUntil("排队许可接收动态高优先级") {
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

    func testPriorityRemainsEffectiveAfterOldestWaiterReachesBypassLimit_SCHED_PT_007()
        async throws
    {
        let pool = AsyncPermitPool(limit: 1, queueLimit: 64)
        let blocker = try await pool.acquire()
        let order = StringOrderRecorder()
        var tasks: [Task<Void, Error>] = []

        for index in 0..<12 {
            tasks.append(
                Task {
                    let permit = try await pool.acquire(priority: .background)
                    await order.append("low-\(index)")
                    await permit.release()
                }
            )
            try await waitForQueuedCount(index * 2 + 1, in: pool)
            tasks.append(
                Task {
                    let permit = try await pool.acquire(priority: .userInitiated)
                    await order.append("high-\(index)")
                    await permit.release()
                }
            )
            try await waitForQueuedCount(index * 2 + 2, in: pool)
        }

        await blocker.release()
        for task in tasks { try await task.value }

        let values = await order.values()
        let bypassLimit = AsyncPermitPool.maximumPriorityBypasses
        XCTAssertEqual(
            Array(values.prefix(bypassLimit)),
            (0..<bypassLimit).map { "high-\($0)" }
        )
        XCTAssertEqual(values[bypassLimit], "low-0")
        // 旧实现会把所有等待者同时推到绕过上限，随后连续执行 low-1、low-2…；
        // 精确绕过计数只老化比获准任务更早的请求，因此下一项仍是高优先级任务。
        XCTAssertEqual(values[bypassLimit + 1], "high-\(bypassLimit)")
        XCTAssertEqual(values[bypassLimit + 2], "low-1")
        XCTAssertEqual(Set(values), Set((0..<12).flatMap { ["low-\($0)", "high-\($0)"] }))
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
        try await waitForQueuedCount(1, in: pool)

        var highTasks: [Task<Void, Error>] = []
        for index in 0..<9 {
            highTasks.append(
                Task {
                    let permit = try await pool.acquire(priority: .userInitiated)
                    await order.append("high-\(index)")
                    await permit.release()
                })
        }
        try await waitForQueuedCount(10, in: pool)
        await blocker.release()
        try await low.value
        for task in highTasks { try await task.value }

        let values = await order.values()
        let lowIndex = try XCTUnwrap(values.firstIndex(of: "low"))
        XCTAssertLessThanOrEqual(lowIndex, AsyncPermitPool.maximumPriorityBypasses)
    }

    func testWeightedPermitsNeverExceedCapacityAndRejectOversizedRequests_RES_PT_013()
        async throws
    {
        let pool = AsyncPermitPool(limit: 4, queueLimit: 8)
        let first = try await pool.acquire(units: 3)
        let second = try await pool.acquire(units: 1)
        let usedAtCapacity = await pool.usedUnits
        XCTAssertEqual(usedAtCapacity, 4)

        do {
            _ = try await pool.acquire(units: 5)
            XCTFail("单次 reservation 超过容量时必须立即拒绝")
        } catch PermitPoolError.requestExceedsLimit {
            // 预期结果。
        }

        await first.release()
        let usedAfterFirstRelease = await pool.usedUnits
        XCTAssertEqual(usedAfterFirstRelease, 1)
        await second.release()
        let usedAfterAllReleased = await pool.usedUnits
        XCTAssertEqual(usedAfterAllReleased, 0)
    }

    func testWeightedPermitOnlyGrantsWaitersThatFitAvailableCapacity_RES_PT_013()
        async throws
    {
        let pool = AsyncPermitPool(limit: 4, queueLimit: 8)
        let blocker = try await pool.acquire(units: 4)
        let order = StringOrderRecorder()
        let large = Task {
            let permit = try await pool.acquire(units: 3, priority: .high)
            await order.append("large")
            try await Task.sleep(for: .milliseconds(20))
            await permit.release()
        }
        try await waitForQueuedCount(1, in: pool)
        let medium = Task {
            let permit = try await pool.acquire(units: 2, priority: .normal)
            await order.append("medium")
            await permit.release()
        }
        try await waitForQueuedCount(2, in: pool)

        await blocker.release()
        try await large.value
        try await medium.value

        let values = await order.values()
        XCTAssertEqual(values, ["large", "medium"])
        let used = await pool.usedUnits
        XCTAssertEqual(used, 0)
    }

    func testPermitScopeReleasesCapacityAfterSuccessFailureAndCancellation() async throws {
        let pool = AsyncPermitPool(limit: 1, queueLimit: 1)

        let successful = try await pool.acquire()
        let value = await successful.withPermit { 42 }
        XCTAssertEqual(value, 42)
        let usedAfterSuccess = await pool.usedUnits
        XCTAssertEqual(usedAfterSuccess, 0)

        enum ExpectedFailure: Error { case failed }
        let failing = try await pool.acquire()
        do {
            _ = try await failing.withPermit { () async throws -> Int in
                throw ExpectedFailure.failed
            }
            XCTFail("Expected failure")
        } catch ExpectedFailure.failed {
            // 符合预期。
        }
        let usedAfterFailure = await pool.usedUnits
        XCTAssertEqual(usedAfterFailure, 0)

        // 取消路径使用独立池，失败释放回归不会把后续断言变成永久等待。
        let cancellationPool = AsyncPermitPool(limit: 1, queueLimit: 1)
        let task = Task {
            let cancelled = try await cancellationPool.acquire()
            try await cancelled.withPermit { () async throws -> Void in
                try await Task.sleep(for: .seconds(10))
            }
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // 符合预期。
        }
        let usedAfterCancellation = await cancellationPool.usedUnits
        XCTAssertEqual(usedAfterCancellation, 0)
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

    private func waitForQueuedCount(_ expected: Int, in pool: AsyncPermitPool) async throws {
        try await waitUntil("permit 队列数量达到 \(expected)") {
            await pool.queuedCount() == expected
        }
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
