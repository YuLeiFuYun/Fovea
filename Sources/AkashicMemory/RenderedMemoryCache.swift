import Foundation
import ImageCraftCore

public actor RenderedMemoryCache<Key: Hashable & Sendable> {
  private struct Entry: @unchecked Sendable {
    let image: DecodedImage
    let cost: Int
    var access: UInt64
  }

  private let costLimit: Int
  private var totalCost = 0
  private var clock: UInt64 = 0
  private var entries: [Key: Entry] = [:]

  public init(costLimit: Int = 64 * 1024 * 1024) {
    self.costLimit = max(1, costLimit)
  }

  public func image(for key: Key) -> DecodedImage? {
    guard var entry = entries[key] else { return nil }
    clock &+= 1
    entry.access = clock
    entries[key] = entry
    return entry.image
  }

  public func insert(_ image: DecodedImage, for key: Key) {
    clock &+= 1
    let cost = max(1, image.estimatedByteCost)
    if let old = entries.updateValue(Entry(image: image, cost: cost, access: clock), forKey: key) {
      totalCost -= old.cost
    }
    totalCost += cost
    trimIfNeeded()
  }

  public func removeAll() {
    entries.removeAll(keepingCapacity: false)
    totalCost = 0
  }

  public var currentCost: Int { totalCost }

  private func trimIfNeeded() {
    while totalCost > costLimit, let victim = entries.min(by: { $0.value.access < $1.value.access })
    {
      totalCost -= victim.value.cost
      entries.removeValue(forKey: victim.key)
    }
  }
}
