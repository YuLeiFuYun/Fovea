import Foundation
import Network

struct WorkbenchNetworkSnapshot: Equatable {
    var status = "正在检测"
    var interface = "未知"
    var isExpensive = false
    var isConstrained = false

    var pathTitle: String {
        [status, interface, isExpensive ? "高成本" : nil, isConstrained ? "受限" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var symbol: String {
        status == "可用" ? "network" : "wifi.slash"
    }
}

final class WorkbenchNetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.fovea.workbench.network-monitor")
    private let update: @MainActor (WorkbenchNetworkSnapshot) -> Void

    init(update: @escaping @MainActor (WorkbenchNetworkSnapshot) -> Void) {
        self.update = update
        monitor.pathUpdateHandler = { [update] path in
            let interface: String
            if path.usesInterfaceType(.wifi) {
                interface = "Wi-Fi"
            } else if path.usesInterfaceType(.cellular) {
                interface = "蜂窝网络"
            } else if path.usesInterfaceType(.wiredEthernet) {
                interface = "有线网络"
            } else if path.usesInterfaceType(.loopback) {
                interface = "Loopback"
            } else {
                interface = "其他"
            }
            let snapshot = WorkbenchNetworkSnapshot(
                status: path.status == .satisfied ? "可用" : "不可用",
                interface: interface,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
            Task { @MainActor in update(snapshot) }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
