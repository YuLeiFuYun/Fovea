import AkashicCore
import AkashicDisk
import Foundation

public actor CommitBarrierEncodedStore: OriginalEncodedStoring {
  private let base: any OriginalEncodedStoring
  private var commitStarted = false
  private var released = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiter: CheckedContinuation<Void, Never>?

  public init(base: any OriginalEncodedStoring) {
    self.base = base
  }

  public func read(contentID: String, namespace: String) async throws -> Data {
    try await base.read(contentID: contentID, namespace: namespace)
  }

  public func commit(data: Data, contentID: String, namespace: String) async throws -> StoredBlob {
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

  public func physicalID(contentID: String, namespace: String) async -> PhysicalBlobID? {
    await base.physicalID(contentID: contentID, namespace: namespace)
  }

  public func remove(contentID: String, namespace: String) async throws {
    try await base.remove(contentID: contentID, namespace: namespace)
  }

  public func removeAll(namespace: String) async throws {
    try await base.removeAll(namespace: namespace)
  }

  public func waitUntilCommitStarts() async {
    if commitStarted { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  public func releaseCommit() {
    guard !released else { return }
    released = true
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}
