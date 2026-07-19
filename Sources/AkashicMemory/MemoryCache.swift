import Foundation

/// 进程内、按成本设限的 LRU 缓存；不感知所存值所属的业务领域。
public actor MemoryCache<Key: Hashable & Sendable, Value: Sendable> {
  private struct Entry {
    var value: Value
    var cost: Int
    var previous: Key?
    var next: Key?
  }

  private let costLimit: Int
  private var totalCost = 0
  private var entries: [Key: Entry] = [:]
  private var leastRecent: Key?
  private var mostRecent: Key?

  public init(costLimit: Int) {
    self.costLimit = max(1, costLimit)
  }

  public func value(for key: Key) -> Value? {
    guard let value = entries[key]?.value else { return nil }
    moveToMostRecent(key)
    return value
  }

  public func insert(_ value: Value, for key: Key, cost: Int) {
    let cost = max(1, cost)
    if let existing = entries[key] {
      totalCost -= existing.cost
      entries[key]?.value = value
      entries[key]?.cost = cost
      totalCost += cost
      moveToMostRecent(key)
    } else {
      entries[key] = Entry(
        value: value,
        cost: cost,
        previous: mostRecent,
        next: nil
      )
      if let mostRecent { entries[mostRecent]?.next = key } else { leastRecent = key }
      mostRecent = key
      totalCost += cost
    }
    trimIfNeeded()
  }

  public func remove(_ key: Key) {
    guard let entry = entries.removeValue(forKey: key) else { return }
    unlink(key: key, entry: entry)
    totalCost -= entry.cost
  }

  public func removeAll(where predicate: @Sendable (Key) -> Bool) {
    let victims = entries.keys.filter(predicate)
    for key in victims { remove(key) }
  }

  public func removeAll() {
    entries.removeAll(keepingCapacity: false)
    leastRecent = nil
    mostRecent = nil
    totalCost = 0
  }

  public var currentCost: Int { totalCost }
  public var count: Int { entries.count }

  private func moveToMostRecent(_ key: Key) {
    guard mostRecent != key, let entry = entries[key] else { return }
    unlink(key: key, entry: entry)
    entries[key]?.previous = mostRecent
    entries[key]?.next = nil
    if let mostRecent { entries[mostRecent]?.next = key } else { leastRecent = key }
    mostRecent = key
  }

  private func unlink(key: Key, entry: Entry) {
    if let previous = entry.previous {
      entries[previous]?.next = entry.next
    } else {
      leastRecent = entry.next
    }
    if let next = entry.next {
      entries[next]?.previous = entry.previous
    } else {
      mostRecent = entry.previous
    }
  }

  private func trimIfNeeded() {
    while totalCost > costLimit, let victim = leastRecent {
      remove(victim)
    }
  }
}
