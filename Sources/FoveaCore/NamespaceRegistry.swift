import Foundation

public actor NamespaceRegistry {
  private var generations: [SecurityNamespaceID: NamespaceGeneration] = [:]

  public init() {}

  public func generation(for namespace: SecurityNamespaceID) -> NamespaceGeneration {
    if let existing = generations[namespace] { return existing }
    let initial = NamespaceGeneration(0)
    generations[namespace] = initial
    return initial
  }

  @discardableResult
  public func revoke(_ namespace: SecurityNamespaceID) -> NamespaceGeneration {
    let next = NamespaceGeneration((generations[namespace]?.value ?? 0) &+ 1)
    generations[namespace] = next
    return next
  }

  public func isActive(_ generation: NamespaceGeneration, for namespace: SecurityNamespaceID)
    -> Bool
  {
    (generations[namespace] ?? NamespaceGeneration(0)) == generation
  }
}
