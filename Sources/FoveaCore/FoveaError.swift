public enum FoveaError: Error, Equatable, Sendable {
  case unsupportedStatus(Int)
  case nonImageResponse
  case namespaceRevoked
  case missingCachedBody
  case missingAuthorizationContext
  case namespaceCleanupFailed
}
