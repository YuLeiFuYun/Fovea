import AkashicDisk
import Darwin
import Foundation
import FoveaPersistence

private func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("\(message)\n".utf8))
  exit(code)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
  fail(
    "usage: FoveaStoreProbe generation <root> <compatibility-fingerprint> <delay-ms> | writer <root> <hold-ms>",
    code: 64
  )
}

switch arguments[1] {
case "generation":
  guard arguments.count == 5, let delayMilliseconds = UInt32(arguments[4]) else {
    fail(
      "usage: FoveaStoreProbe generation <root> <compatibility-fingerprint> <delay-ms>", code: 64)
  }
  let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
  let fingerprint = arguments[3]
  do {
    let handle = try StoreGenerationDirectory.open(
      root: root,
      compatibilityFingerprint: fingerprint
    ) { point in
      if point == .afterGenerationDirectoryCreated, delayMilliseconds > 0 {
        usleep(delayMilliseconds * 1_000)
      }
    }
    print(handle.identifier)
  } catch {
    fail("store generation probe failed: \(String(describing: error))")
  }

case "writer":
  guard arguments.count == 4, let holdMilliseconds = UInt32(arguments[3]) else {
    fail("usage: FoveaStoreProbe writer <root> <hold-ms>", code: 64)
  }
  let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
  do {
    let stores = try await FoveaPersistentStores.open(root: root)
    print("acquired:\(stores.generation.identifier)")
    fflush(stdout)
    if holdMilliseconds > 0 { usleep(holdMilliseconds * 1_000) }
    withExtendedLifetime(stores) {}
  } catch {
    fail("store writer probe failed: \(String(describing: error))")
  }

default:
  fail("unknown probe mode: \(arguments[1])", code: 64)
}
