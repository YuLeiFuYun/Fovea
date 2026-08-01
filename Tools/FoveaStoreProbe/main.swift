import Darwin
import Foundation
import FoveaPersistence

private func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code)
}

let arguments = CommandLine.arguments
guard arguments.count == 4, arguments[1] == "writer",
    let holdMilliseconds = UInt32(arguments[3])
else {
    fail("usage: FoveaStoreProbe writer <root> <hold-ms>", code: 64)
}

let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
do {
    let stores = try await FoveaPersistentStores.open(root: root)
    print("acquired")
    fflush(stdout)
    if holdMilliseconds > 0 { usleep(holdMilliseconds * 1_000) }
    withExtendedLifetime(stores) {}
} catch {
    fail("store writer probe failed: \(String(describing: error))")
}
