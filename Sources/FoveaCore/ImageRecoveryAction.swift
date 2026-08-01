/// 由管线失败派生的稳定 UI 恢复建议。
public enum FoveaImageRecoveryAction: String, Codable, Hashable, Sendable {
    case retry
    case reauthenticate
    case none
}

extension PipelineFailure {
    public var imageRecoveryAction: FoveaImageRecoveryAction {
        if category == .namespaceRevoked || category == .authorization {
            return .reauthenticate
        }
        if category == .securityLimit || disposition == .terminal {
            return .none
        }
        if disposition == .retryable || disposition == .cacheDegraded {
            return .retry
        }
        return .none
    }
}
