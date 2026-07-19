import Foundation
import FoveaHTTP

struct NetworkLabOptions {
  var live = false
  var keepCache = false
  var cacheRoot: URL?
  var urls: [URL] = []

  static func parse(_ arguments: [String]) throws -> NetworkLabOptions {
    var options = NetworkLabOptions()
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--live":
        options.live = true
      case "--keep-cache":
        options.keepCache = true
      case "--cache-root":
        index += 1
        guard index < arguments.count else { throw NetworkLabError.missingValue("--cache-root") }
        options.cacheRoot = URL(fileURLWithPath: arguments[index], isDirectory: true)
      case "--url":
        index += 1
        guard index < arguments.count else { throw NetworkLabError.missingValue("--url") }
        guard let url = URL(string: arguments[index]), HTTPURLSecurityPolicy.permits(url) else {
          throw NetworkLabError.invalidURL(arguments[index])
        }
        options.urls.append(url)
      case "--help", "-h":
        throw NetworkLabError.helpRequested
      default:
        throw NetworkLabError.unknownArgument(arguments[index])
      }
      index += 1
    }
    return options
  }
}

enum NetworkLabError: Error, CustomStringConvertible {
  case helpRequested
  case liveModeRequired
  case missingValue(String)
  case invalidURL(String)
  case unknownArgument(String)
  case inconsistentConcurrentResult

  var description: String {
    switch self {
    case .helpRequested:
      return Self.usage
    case .liveModeRequired:
      return "真实网络实验必须显式传入 --live。\n\(Self.usage)"
    case .missingValue(let option):
      return "参数 \(option) 缺少值。\n\(Self.usage)"
    case .invalidURL(let value):
      return "仅接受有效 HTTPS URL 或 loopback HTTP URL：\(value)"
    case .unknownArgument(let value):
      return "未知参数：\(value)\n\(Self.usage)"
    case .inconsistentConcurrentResult:
      return "同一请求的并发订阅返回了不一致的像素尺寸。"
    }
  }

  static let usage = """
    用法：swift run FoveaNetworkLab --live [选项]
      --url <https-url>       增加测试图片；可重复
      --cache-root <path>     使用指定缓存目录
      --keep-cache            不清理临时缓存目录
      --help                  显示帮助
    """
}
