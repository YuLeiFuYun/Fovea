import AkashicCore
import FoveaStorage
import XCTest

final class FoveaBlockingIOExecutorTests: XCTestCase {
    func testRunExecutesOnOwnedSerialQueue() async throws {
        let executor = FoveaBlockingIOExecutor(label: "dev.fovea.tests.blocking-io-run")

        let value = try await executor.run {
            executor.checkIsolated()
            return 42
        }

        XCTAssertEqual(value, 42)
    }

    func testActorJobsExecuteOnConfiguredFoveaBlockingIOExecutor() async {
        let probe = FoveaBlockingIOExecutorProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    await probe.increment()
                }
            }
        }

        let value = await probe.value
        XCTAssertEqual(value, 64)
    }
}

private actor FoveaBlockingIOExecutorProbe {
    private nonisolated let executor = FoveaBlockingIOExecutor(
        label: "dev.fovea.tests.blocking-io-actor"
    )
    private var count = 0

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    func increment() {
        executor.checkIsolated()
        count += 1
    }

    var value: Int {
        executor.checkIsolated()
        return count
    }
}
