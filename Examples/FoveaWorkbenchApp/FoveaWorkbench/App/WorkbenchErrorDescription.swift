import FoveaCore

/// 将内部错误收敛为有限、脱敏且适合界面展示的说明。
enum WorkbenchErrorDescription {
    nonisolated static func make(_ error: Error) -> String {
        if let failure = error as? PipelineFailure {
            return "管线失败：\(failure.reasonCode)"
        }
        if let requestError = error as? WorkbenchRequestFactoryError {
            return requestError.errorDescription ?? "请求配置无效。"
        }
        return "操作失败。请检查配置与脱敏诊断事件。"
    }
}
