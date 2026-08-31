import Foundation
import FoveaHTTP

enum NetworkLabExpectation: Hashable, Sendable {
    case success
    case failure(reasonCode: String)
}

enum NetworkLabOriginDisclosure: Hashable, Sendable {
    case publicHost
    case redacted
}

struct NetworkLabInput: Hashable, Sendable {
    let caseID: String
    let url: URL
    let expectation: NetworkLabExpectation
    let originDisclosure: NetworkLabOriginDisclosure
}

struct NetworkLabOptions {
    private static let maximumCaseCount = 64
    private static let maximumAdditionalOriginCount = 64

    var live = false
    var mjpegMechanism = false
    var sharedTaskRelayMechanism = false
    var progressiveResourceMechanism = false
    var progressiveHeldOut12MP = false
    var progressiveTargetPixels = 512
    var progressiveConcurrency = 1
    var progressiveTransportThreshold = 1024 * 1024
    var keepCache = false
    var cacheRoot: URL?
    var inputs: [NetworkLabInput] = []
    var additionalAllowedOrigins: Set<HTTPOrigin> = []
    var maximumTransportBytes = 16 * 1024 * 1024

    static func parse(_ arguments: [String]) throws -> NetworkLabOptions {
        var options = NetworkLabOptions()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--live":
                options.live = true
            case "--mjpeg-mechanism":
                options.mjpegMechanism = true
            case "--shared-task-relay-mechanism":
                options.sharedTaskRelayMechanism = true
            case "--progressive-resource-mechanism":
                options.progressiveResourceMechanism = true
            case "--progressive-heldout-12mp":
                options.progressiveHeldOut12MP = true
            case "--progressive-target-pixels":
                index += 1
                guard index < arguments.count,
                    let value = Int(arguments[index]), value > 0
                else {
                    throw NetworkLabError.invalidPositiveInteger("--progressive-target-pixels")
                }
                options.progressiveTargetPixels = value
            case "--progressive-concurrency":
                index += 1
                guard index < arguments.count,
                    let value = Int(arguments[index]), value > 0
                else {
                    throw NetworkLabError.invalidPositiveInteger("--progressive-concurrency")
                }
                options.progressiveConcurrency = value
            case "--progressive-transport-threshold":
                index += 1
                guard index < arguments.count,
                    let value = Int(arguments[index]), value > 0
                else {
                    throw NetworkLabError.invalidPositiveInteger(
                        "--progressive-transport-threshold"
                    )
                }
                options.progressiveTransportThreshold = value
            case "--keep-cache":
                options.keepCache = true
            case "--cache-root":
                index += 1
                guard index < arguments.count else {
                    throw NetworkLabError.missingValue("--cache-root")
                }
                options.cacheRoot = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--maximum-transport-bytes":
                index += 1
                guard index < arguments.count,
                    let value = Int(arguments[index]), value > 0
                else {
                    throw NetworkLabError.invalidPositiveInteger("--maximum-transport-bytes")
                }
                options.maximumTransportBytes = value
            case "--url":
                index += 1
                guard index < arguments.count else { throw NetworkLabError.missingValue("--url") }
                guard options.inputs.count < maximumCaseCount else {
                    throw NetworkLabError.tooManyCases
                }
                options.inputs.append(
                    NetworkLabInput(
                        caseID: customCaseID(options.inputs.count),
                        url: try validatedURL(arguments[index]),
                        expectation: .success,
                        originDisclosure: .redacted
                    )
                )
            case "--expect-failure":
                index += 1
                guard index < arguments.count else {
                    throw NetworkLabError.missingValue("--expect-failure <reason-code>")
                }
                let reasonCode = arguments[index]
                guard isValidReasonCode(reasonCode) else {
                    throw NetworkLabError.invalidReasonCode
                }
                index += 1
                guard index < arguments.count else {
                    throw NetworkLabError.missingValue("--expect-failure <reason-code> <url>")
                }
                guard options.inputs.count < maximumCaseCount else {
                    throw NetworkLabError.tooManyCases
                }
                options.inputs.append(
                    NetworkLabInput(
                        caseID: customCaseID(options.inputs.count),
                        url: try validatedURL(arguments[index]),
                        expectation: .failure(reasonCode: reasonCode),
                        originDisclosure: .redacted
                    )
                )
            case "--allow-origin":
                index += 1
                guard index < arguments.count else {
                    throw NetworkLabError.missingValue("--allow-origin")
                }
                guard options.additionalAllowedOrigins.count < maximumAdditionalOriginCount else {
                    throw NetworkLabError.tooManyAllowedOrigins
                }
                let url = try validatedURL(arguments[index])
                options.additionalAllowedOrigins.insert(try HTTPOrigin(url: url))
            case "--help", "-h":
                throw NetworkLabError.helpRequested
            default:
                throw NetworkLabError.unknownArgument
            }
            index += 1
        }
        return options
    }

    private static func customCaseID(_ currentCount: Int) -> String {
        String(format: "custom-%03d", currentCount + 1)
    }

    private static func validatedURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), HTTPURLSecurityPolicy.permits(url) else {
            throw NetworkLabError.invalidURL
        }
        return url
    }

    private static func isValidReasonCode(_ value: String) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= 96
            && bytes.allSatisfy { byte in
                (48...57).contains(byte) || (97...122).contains(byte) || byte == 45
            }
    }
}

enum NetworkLabError: Error, CustomStringConvertible {
    case helpRequested
    case liveModeRequired
    case conflictingModes
    case missingValue(String)
    case invalidPositiveInteger(String)
    case invalidReasonCode
    case invalidURL
    case unknownArgument
    case tooManyCases
    case tooManyAllowedOrigins
    case inconsistentConcurrentResult

    var description: String {
        switch self {
        case .helpRequested:
            return Self.usage
        case .liveModeRequired:
            return "真实网络实验必须显式传入 --live。\n\(Self.usage)"
        case .conflictingModes:
            return "--live 与各离线 mechanism 模式只能选择一种。\n\(Self.usage)"
        case .missingValue(let option):
            return "参数 \(option) 缺少值。\n\(Self.usage)"
        case .invalidPositiveInteger(let option):
            return "参数 \(option) 必须是正整数。\n\(Self.usage)"
        case .invalidReasonCode:
            return "预期失败 reason code 非法。"
        case .invalidURL:
            return "仅接受有效 HTTPS URL 或 loopback HTTP URL；输入值不会写入错误日志。"
        case .unknownArgument:
            return "存在未知参数；参数值不会写入错误日志。\n\(Self.usage)"
        case .tooManyCases:
            return "单次实验最多允许 64 个网络 case。"
        case .tooManyAllowedOrigins:
            return "单次实验最多允许 64 个额外 redirect origin。"
        case .inconsistentConcurrentResult:
            return "同一请求的并发订阅返回了不一致的像素尺寸。"
        }
    }

    static let usage = """
        用法：FoveaNetworkLab (--live [选项] | --mjpeg-mechanism | --shared-task-relay-mechanism | --progressive-resource-mechanism)
          --mjpeg-mechanism                    运行离线 MJPEG latest-only 机制实验
          --shared-task-relay-mechanism        运行离线 shared-task result relay 控制面实验
          --progressive-resource-mechanism     运行 H013 progressive 联合资源机制实验
          --progressive-heldout-12mp            H013 使用冻结的 12MP held-out progressive fixture
          --progressive-target-pixels <n>      H013 正方形目标像素边长
          --progressive-concurrency <n>        H013 并发 progressive 请求数
          --progressive-transport-threshold <bytes> H013 transport 内存暂存阈值
          --url <https-url>                    增加预期成功的测试图片；可重复
          --expect-failure <reason> <url>      增加预期结构化失败；可重复
          --allow-origin <https-url>           显式允许跨 origin 重定向目的地；可重复
          --maximum-transport-bytes <bytes>    设置单响应硬上限
          --cache-root <path>                  使用指定缓存目录
          --keep-cache                         不清理临时缓存目录
          --help                               显示帮助
        """
}
