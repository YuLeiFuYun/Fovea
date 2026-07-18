import Foundation

struct ScopedRenderKey: Hashable, Sendable {
  let namespace: SecurityNamespaceID
  let generation: NamespaceGeneration
  let renderKey: RenderKey
}

struct ScopedFetchExecutionKey: Hashable, Sendable {
  let namespace: SecurityNamespaceID
  let execution: FetchExecutionKey
}
