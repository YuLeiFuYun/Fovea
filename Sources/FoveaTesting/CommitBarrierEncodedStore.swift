import AkashicCore
import AkashicDisk
import Foundation
import FoveaStorage

/// 在底层提交真正发生前设置可控屏障，用于确定性制造并发失效与半提交竞态。
/// 屏障只包裹 commit，其余存储行为原样转发，避免测试替身改变被测语义。
package actor CommitBarrierEncodedStore: OriginalEncodedMaintaining {
    private let base: any OriginalEncodedStoring
    private var commitStarted = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    package init(base: any OriginalEncodedStoring) {
        self.base = base
    }

    package func read(contentID: String, namespace: String) async throws -> Data {
        try await base.read(contentID: contentID, namespace: namespace)
    }

    package func commit(data: Data, contentID: String, namespace: String) async throws -> StoredBlob
    {
        commitStarted = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }

        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }
        return try await base.commit(data: data, contentID: contentID, namespace: namespace)
    }

    package func physicalID(contentID: String, namespace: String) async -> PhysicalBlobID? {
        await base.physicalID(contentID: contentID, namespace: namespace)
    }

    package func remove(contentID: String, namespace: String) async throws {
        try await base.remove(contentID: contentID, namespace: namespace)
    }

    package func removeAll(namespace: String) async throws {
        try await base.removeAll(namespace: namespace)
    }

    package func garbageCollect(
        retaining references: Set<StoredContentReference>
    ) async throws -> GarbageCollectionResult {
        guard let maintenance = base as? any OriginalEncodedMaintaining else {
            throw AkashicError.storageUnavailable
        }
        return try await maintenance.garbageCollect(retaining: references)
    }

    package func waitUntilCommitStarts() async {
        if commitStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    package func releaseCommit() {
        guard !released else { return }
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
