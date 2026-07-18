import Foundation
import ImageCraftCore

public actor RenderedMemoryCache<Key: Hashable & Sendable> {
  private struct Entry {
    var image: DecodedImage
    var cost: Int
    var previous: Key?
    var next: Key?
  }

  private let costLimit: Int
  private var totalCost = 0
  private var entries: [Key: Entry] = [:]
  private var leastRecent: Key?
  private var mostRecent: Key?

  public init(costLimit: Int = 64 * 1024 * 1024) {
    self.costLimit = max(1, costLimit)
  }

  public func image(for key: Key) -> DecodedImage? {
    guard let image = entries[key]?.image else { return nil }
    moveToMostRecent(key)
    return image
  }

  public func insert(_ image: DecodedImage, for key: Key) {
    let cost = max(1, image.estimatedByteCost)
    if let existing = entries[key] {
      totalCost -= existing.cost
      entries[key]?.image = image
      entries[key]?.cost = cost
      totalCost += cost
      moveToMostRecent(key)
    } else {
      entries[key] = Entry(
        image: image,
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

  public func removeAll(where predicate: (Key) -> Bool) {
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
