import Foundation

/// Fovea 官方 HTTP transport 与请求模型共享的 URL 安全策略。
///
/// 远程图片只允许 HTTPS。明文 HTTP 仅限精确 loopback host，用于本地开发和
/// 不依赖公网的协议实验；该例外不扩展到私网地址、`.local` 名称或任意 IP。
public enum HTTPURLSecurityPolicy {
    public static func permits(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
            let host = url.host?.lowercased()
        else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && isLoopbackHost(host)
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host == "[::1]"
    }
}
