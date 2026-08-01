import Foundation

struct ScopedDecodeKey: Hashable, Sendable {
    let namespace: SecurityNamespaceID
    let generation: NamespaceGeneration
    let decodeKey: DecodeKey
}

struct ScopedRenderKey: Hashable, Sendable {
    let namespace: SecurityNamespaceID
    let generation: NamespaceGeneration
    let renderKey: RenderKey
}

struct ScopedFetchExecutionKey: Hashable, Sendable {
    let namespace: SecurityNamespaceID
    let execution: FetchExecutionKey
}
