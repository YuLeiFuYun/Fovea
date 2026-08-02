import FoveaCore
import XCTest

final class SharedTaskTests: XCTestCase {
    func testCancelledSubscriberReturnsBeforeSharedTaskCompletes() async throws {
        let registry = SharedTaskRegistry<String, Int>(recordsCancellationCounts: true)
        let gate = HandoffOperationGate()
        let first = await registry.subscribe(key: "prompt-cancel") {
            try await gate.run()
        }
        let survivor = await registry.subscribe(key: "prompt-cancel") { 0 }
        await gate.waitUntilStarted()

        let cancelled = Task { () -> Bool in
            do {
                _ = try await first.value()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        cancelled.cancel()
        await first.cancel()

        // gate 尚未释放；若取消订阅仍等待共享 operation，这里会永久阻塞并由测试超时捕获。
        let cancellationReturnedBeforeRelease = await cancelled.value
        XCTAssertTrue(cancellationReturnedBeforeRelease)
        let operationCountBeforeRelease = await gate.operationCount
        XCTAssertEqual(operationCountBeforeRelease, 1)

        await gate.release()
        let survivorValue = try await survivor.value()
        XCTAssertEqual(survivorValue, 42)
        await survivor.cancel()
    }

    func testMismatchedCompletionCannotRemoveActiveTask() async throws {
        let registry = SharedTaskRegistry<String, Int>(recordsCancellationCounts: true)
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
        let registry = SharedTaskRegistry<String, Int>(recordsCancellationCounts: true)
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

    func testCompletedTaskCanBeHandedOffOnlyAfterExplicitDetach_SCHED_PT_023()
        async throws
    {
        let registry = SharedTaskRegistry<String, Int>(recordsCancellationCounts: true)
        let operationCounter = OperationCounter()
        let replacementCounter = OperationCounter()
        let first = await registry.subscribe(key: "completed-then-detach") {
            await operationCounter.increment()
            return 42
        }

        let firstValue = try await first.value()
        XCTAssertEqual(firstValue, 42)
        await first.detach(handoffGraceNanoseconds: 100_000_000)

        let late = await registry.subscribe(key: "completed-then-detach") {
            await replacementCounter.increment()
            return 99
        }
        XCTAssertTrue(late.wasJoined)
        let lateValue = try await late.value()
        XCTAssertEqual(lateValue, 42)
        let operationCountAfterHandoff = await operationCounter.value()
        let replacementCountAfterHandoff = await replacementCounter.value()
        XCTAssertEqual(operationCountAfterHandoff, 1)
        XCTAssertEqual(replacementCountAfterHandoff, 0)

        await late.cancel()
        let fresh = await registry.subscribe(key: "completed-then-detach") {
            await replacementCounter.increment()
            return 99
        }
        XCTAssertFalse(fresh.wasJoined)
        let freshValue = try await fresh.value()
        let replacementCountAfterFresh = await replacementCounter.value()
        XCTAssertEqual(freshValue, 99)
        XCTAssertEqual(replacementCountAfterFresh, 1)
        await fresh.cancel()
    }

    func testDetachedTaskCompletionRemainsJoinableUntilLeaseExpiry_SCHED_PT_024()
        async throws
    {
        let registry = SharedTaskRegistry<String, Int>(recordsCancellationCounts: true)
        let gate = HandoffOperationGate()
        let replacementCounter = OperationCounter()
        let first = await registry.subscribe(key: "detach-then-complete") {
            try await gate.run()
        }
        await gate.waitUntilStarted()
        await first.detach(handoffGraceNanoseconds: 100_000_000)
        await gate.release()
        let completedValue = try await first.value()
        XCTAssertEqual(completedValue, 42)

        let late = await registry.subscribe(key: "detach-then-complete") {
            await replacementCounter.increment()
            return 77
        }
        XCTAssertTrue(late.wasJoined)
        let lateValue = try await late.value()
        let replacementCountBeforeExpiry = await replacementCounter.value()
        XCTAssertEqual(lateValue, 42)
        XCTAssertEqual(replacementCountBeforeExpiry, 0)
        await late.cancel()

        let expiring = await registry.subscribe(key: "completed-lease-expiry") { 11 }
        let expiringValue = try await expiring.value()
        XCTAssertEqual(expiringValue, 11)
        await expiring.detach(handoffGraceNanoseconds: 1_000_000)
        try await Task.sleep(nanoseconds: 20_000_000)
        let afterExpiry = await registry.subscribe(key: "completed-lease-expiry") {
            await replacementCounter.increment()
            return 88
        }
        XCTAssertFalse(afterExpiry.wasJoined)
        let afterExpiryValue = try await afterExpiry.value()
        let replacementCountAfterExpiry = await replacementCounter.value()
        XCTAssertEqual(afterExpiryValue, 88)
        XCTAssertEqual(replacementCountAfterExpiry, 1)
        let cancellationCount = await registry.cancellationCount(for: "completed-lease-expiry")
        XCTAssertEqual(cancellationCount, 0)
        await afterExpiry.cancel()
    }

    func testDetachedTaskIsCancelledAfterBoundedHandoffLease_SCHED_PT_016() async throws {
        let registry = SharedTaskRegistry<String, Int>(recordsCancellationCounts: true)
        let gate = HandoffOperationGate()
        let subscription = await registry.subscribe(key: "bounded-handoff") {
            try await gate.run()
        }
        await gate.waitUntilStarted()

        await subscription.detach(handoffGraceNanoseconds: 1_000_000)
        try await waitUntil("handoff lease 到期后共享任务取消") {
            await gate.wasCancelled
        }

        let wasCancelled = await gate.wasCancelled
        let subscriberCount = await registry.subscriberCount(for: "bounded-handoff")
        let cancellationCount = await registry.cancellationCount(for: "bounded-handoff")
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(subscriberCount, 0)
        XCTAssertEqual(cancellationCount, 1)
    }

    func testRegistryDeinitCancelsDetachedOrphanImmediately() async throws {
        let gate = HandoffOperationGate()
        var registry: SharedTaskRegistry<String, Int>? = SharedTaskRegistry()
        var subscription: SharedTaskSubscription<String, Int>? = await registry?.subscribe(
            key: "deinit-orphan"
        ) {
            try await gate.run()
        }
        await gate.waitUntilStarted()

        await subscription?.detach(handoffGraceNanoseconds: 60_000_000_000)
        subscription = nil
        registry = nil

        try await waitUntil("handoff lease 到期后共享任务取消") {
            await gate.wasCancelled
        }
        let wasCancelled = await gate.wasCancelled
        XCTAssertTrue(wasCancelled)
    }

    func testSeededSubscriberExitSoakPreservesRegistryInvariants_SCHED_PT_014() async throws {
        for seed in 1...128 {
            var random = SeededRandomNumberGenerator(seed: UInt64(seed))
            let registry = SharedTaskRegistry<String, Int>(recordsCancellationCounts: true)
            let gate = HandoffOperationGate()
            let subscriberCount = Int.random(in: 2...10, using: &random)
            var subscriptions: [SharedTaskSubscription<String, Int>] = []
            var priorities: [ImageRequestPriority] = []

            for _ in 0..<subscriberCount {
                let priority =
                    ImageRequestPriority.allCases.randomElement(using: &random) ?? .normal
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

            async let cancellationObserved: Void = gate.waitUntilCancelled()
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
            await cancellationObserved
            let wasCancelled = await gate.wasCancelled
            XCTAssertTrue(wasCancelled, "seed=\(seed)")
        }
    }

    func testCancellationTombstonePreventsLateSubscriberFromRestartingOperation_SCHED_PT_021()
        async throws
    {
        let registry = SharedTaskRegistry<String, Int>(recordsCancellationCounts: true)
        let gate = HandoffOperationGate()
        let replacementCounter = OperationCounter()
        let first = await registry.subscribe(key: "cancel-tombstone") {
            try await gate.run()
        }
        await gate.waitUntilStarted()

        await first.cancel(retainingCancelledTaskForNanoseconds: 100_000_000)
        await gate.waitUntilCancelled()

        // 即使旧 task 已经完成取消，租约窗口内的迟到订阅也只能观察同一取消结果，
        // 不能在 entry 被 completion 提前删除后启动第二个底层 operation。
        let late = await registry.subscribe(key: "cancel-tombstone") {
            await replacementCounter.increment()
            return 99
        }
        XCTAssertTrue(late.wasJoined)
        do {
            _ = try await late.value()
            XCTFail("迟到订阅不应复活已取消的共享任务")
        } catch is CancellationError {
            // 预期：复用已取消 task 的终态。
        }
        let operationCountDuringTombstone = await gate.operationCount
        let replacementCountDuringTombstone = await replacementCounter.value()
        XCTAssertEqual(operationCountDuringTombstone, 1)
        XCTAssertEqual(replacementCountDuringTombstone, 0)
        await late.cancel()

        try await Task.sleep(nanoseconds: 150_000_000)
        let fresh = await registry.subscribe(key: "cancel-tombstone") {
            await replacementCounter.increment()
            return 99
        }
        XCTAssertFalse(fresh.wasJoined)
        let freshValue = try await fresh.value()
        let replacementCountAfterExpiry = await replacementCounter.value()
        XCTAssertEqual(freshValue, 99)
        XCTAssertEqual(replacementCountAfterExpiry, 1)
        await fresh.cancel()
    }

    func
        testPreCancellationAdmissionCanJoinReplacementCohortWithoutAllowingFreshRestart_SCHED_PT_022()
        async throws
    {
        let registry = SharedTaskRegistry<String, Int>(recordsCancellationCounts: true)
        let cancelledGate = HandoffOperationGate()
        let replacementCounter = OperationCounter()
        let preCancellationAdmission = SharedTaskAdmission.now()

        let first = await registry.subscribe(
            key: "replacement-cohort",
            admission: preCancellationAdmission
        ) {
            try await cancelledGate.run()
        }
        await cancelledGate.waitUntilStarted()
        await first.cancel(retainingCancelledTaskForNanoseconds: 200_000_000)
        await cancelledGate.waitUntilCancelled()

        let survivor = await registry.subscribe(
            key: "replacement-cohort",
            admission: preCancellationAdmission
        ) {
            await replacementCounter.increment()
            return 77
        }
        XCTAssertFalse(survivor.wasJoined)
        let survivorValue = try await survivor.value()
        XCTAssertEqual(survivorValue, 77)

        // replacement 已完成后，同一取消前 cohort 的更晚到达者仍复用该结果，
        // 不会在 tombstone 窗口内再次启动底层 operation。
        let delayedSurvivor = await registry.subscribe(
            key: "replacement-cohort",
            admission: preCancellationAdmission
        ) {
            await replacementCounter.increment()
            return 88
        }
        XCTAssertTrue(delayedSurvivor.wasJoined)
        let delayedSurvivorValue = try await delayedSurvivor.value()
        XCTAssertEqual(delayedSurvivorValue, 77)
        let replacementCountAfterDelayedSurvivor = await replacementCounter.value()
        XCTAssertEqual(replacementCountAfterDelayedSurvivor, 1)

        let fresh = await registry.subscribe(key: "replacement-cohort") {
            await replacementCounter.increment()
            return 99
        }
        XCTAssertTrue(fresh.wasJoined)
        do {
            _ = try await fresh.value()
            XCTFail("取消后新调用不应加入 replacement cohort")
        } catch is CancellationError {
            // 预期：真正的新调用继续观察 tombstone 的取消终态。
        }
        let replacementCountAfterFreshSubscriber = await replacementCounter.value()
        XCTAssertEqual(replacementCountAfterFreshSubscriber, 1)

        await survivor.cancel()
        await delayedSurvivor.cancel()
        await fresh.cancel()
    }

    func testLastSubscriberCancelsUnderlyingTaskOnce_SCHED_PT_004() async throws {
        let registry = SharedTaskRegistry<FetchExecutionKey, Int>(recordsCancellationCounts: true)
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
        let registry = SharedTaskRegistry<FetchExecutionKey, Int>(recordsCancellationCounts: true)
        let key = makeKey("https://example.com/b")
        let subscription = await registry.subscribe(key: key) { 42 }
        let value = try await subscription.value()
        XCTAssertEqual(value, 42)
        await subscription.cancel()
        await subscription.cancel()
        let cancellationCount = await registry.cancellationCount(for: key)
        XCTAssertLessThanOrEqual(cancellationCount, 1)
    }

    func testCancellationInstrumentationIsDisabledByDefault() async {
        let registry = SharedTaskRegistry<String, Int>()
        for index in 0..<1_000 {
            let subscription = await registry.subscribe(key: "high-cardinality-\(index)") {
                try await Task.sleep(for: .seconds(10))
                return index
            }
            await subscription.cancel()
        }

        let retainedKeyCount = await registry.recordedCancellationKeyCount()
        XCTAssertEqual(retainedKeyCount, 0)
    }

    func testCompletedTaskCannotBeJoinedByNewSubscriber_SCHED_PT_015() async throws {
        let registry = SharedTaskRegistry<FetchExecutionKey, Int>(recordsCancellationCounts: true)
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
        XCTAssertFalse(second.wasJoined)
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
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

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

    func waitUntilCancelled() async {
        if wasCancelled { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    private func cancelled() {
        wasCancelled = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
        for waiter in cancellationWaiters { waiter.resume() }
        cancellationWaiters.removeAll()
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
