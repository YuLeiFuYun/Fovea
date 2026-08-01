import Foundation
import OSLog

/// 串行管理 Logger 与 signpost 生命周期；令牌只在本进程内关联，不充当跨系统身份。
/// 消息统一以 private 隐私级别输出，调用方不能通过插值改变该边界。
actor SystemOSLogDiagnosticsEmitter: OSLogDiagnosticsEmitting {
    private let logger: Logger
    private let signpostLog: OSLog
    private var signpostIDs: [UInt64: OSSignpostID] = [:]
    private var nextToken: UInt64 = 1

    init(configuration: OSLogDiagnosticsConfiguration) {
        self.logger = Logger(subsystem: configuration.subsystem, category: configuration.category)
        self.signpostLog = OSLog(
            subsystem: configuration.subsystem,
            category: configuration.category
        )
    }

    func makeSignpostID() -> UInt64 {
        while signpostIDs[nextToken] != nil {
            nextToken = nextToken == UInt64.max ? 1 : nextToken + 1
        }
        let token = nextToken
        nextToken = nextToken == UInt64.max ? 1 : nextToken + 1
        signpostIDs[token] = OSSignpostID(log: signpostLog)
        return token
    }

    func emitLog(level: OSLogDiagnosticsLevel, message: String) {
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .private)")
        case .info:
            logger.info("\(message, privacy: .private)")
        case .notice:
            logger.notice("\(message, privacy: .private)")
        case .error:
            logger.error("\(message, privacy: .private)")
        }
    }

    func emitSignpost(
        operation: OSLogDiagnosticsOperation,
        interval: OSLogDiagnosticsInterval,
        id: UInt64,
        message: String
    ) {
        guard let signpostID = signpostIDs[id] else { return }
        defer {
            if operation != .begin { signpostIDs.removeValue(forKey: id) }
        }
        let object = message as NSString
        switch (operation, interval) {
        case (.begin, .fetch):
            os_signpost(
                .begin, log: signpostLog, name: "FoveaFetch", signpostID: signpostID,
                "%{private}@", object)
        case (.end, .fetch):
            os_signpost(
                .end, log: signpostLog, name: "FoveaFetch", signpostID: signpostID,
                "%{private}@", object)
        case (.event, .fetch):
            os_signpost(
                .event, log: signpostLog, name: "FoveaFetch", signpostID: signpostID,
                "%{private}@", object)
        case (.begin, .decode):
            os_signpost(
                .begin, log: signpostLog, name: "FoveaDecode", signpostID: signpostID,
                "%{private}@", object)
        case (.end, .decode):
            os_signpost(
                .end, log: signpostLog, name: "FoveaDecode", signpostID: signpostID,
                "%{private}@", object)
        case (.event, .decode):
            os_signpost(
                .event, log: signpostLog, name: "FoveaDecode", signpostID: signpostID,
                "%{private}@", object)
        case (.event, .cache):
            os_signpost(
                .event, log: signpostLog, name: "FoveaCache", signpostID: signpostID,
                "%{private}@", object)
        case (.event, .pipeline):
            os_signpost(
                .event, log: signpostLog, name: "FoveaPipeline", signpostID: signpostID,
                "%{private}@", object)
        case (.event, .general):
            os_signpost(
                .event, log: signpostLog, name: "FoveaEvent", signpostID: signpostID,
                "%{private}@", object)
        case (.begin, .cache), (.end, .cache), (.begin, .pipeline), (.end, .pipeline),
            (.begin, .general), (.end, .general):
            os_signpost(
                .event, log: signpostLog, name: "FoveaEvent", signpostID: signpostID,
                "%{private}@", object)
        }
    }
}
