import AkashicCore
import AkashicDisk
import Foundation
import FoveaCore
import FoveaPersistence
import XCTest

final class StoreGenerationTests: XCTestCase {
  func testEveryGenerationSwitchCrashPointRecoversToCompleteGeneration_CACHE_PT_019() throws {
    for point in StoreGenerationSwitchPoint.allCases {
      let root = try makeTemporaryDirectory()
      let initial = try StoreGenerationDirectory.open(
        root: root,
        compatibilityFingerprint: "schema-v1"
      )
      XCTAssertTrue(FileManager.default.fileExists(atPath: initial.root.path))

      do {
        _ = try StoreGenerationDirectory.open(
          root: root,
          compatibilityFingerprint: "schema-v2"
        ) { reached in
          if reached == point { throw InjectedGenerationCrash() }
        }
        XCTFail("故障注入点必须中断 generation 切换：\(point)")
      } catch is InjectedGenerationCrash {
      }

      let recovered = try StoreGenerationDirectory.open(
        root: root,
        compatibilityFingerprint: "schema-v2"
      )
      let reopened = try StoreGenerationDirectory.open(
        root: root,
        compatibilityFingerprint: "schema-v2"
      )
      XCTAssertEqual(recovered.identifier, reopened.identifier)
      XCTAssertEqual(recovered.compatibilityFingerprint, "schema-v2")
      XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.root.path))
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: recovered.root.appendingPathComponent("generation.json").path
        )
      )
      let temporaryPointers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        .filter { $0.hasPrefix(".current-generation.tmp-") }
      XCTAssertTrue(temporaryPointers.isEmpty)
    }
  }

  func testFutureGenerationPointerFailsClosedWithoutRewrite_CACHE_PT_019() throws {
    let root = try makeTemporaryDirectory()
    let generations = root.appendingPathComponent("generations", isDirectory: true)
    try FileManager.default.createDirectory(
      at: generations,
      withIntermediateDirectories: true
    )
    let identifier = UUID().uuidString.lowercased()
    let futureRoot = generations.appendingPathComponent(identifier, isDirectory: true)
    try FileManager.default.createDirectory(
      at: futureRoot,
      withIntermediateDirectories: true
    )
    let futureDescriptor = Data(
      "{\"schemaVersion\":999,\"identifier\":\"\(identifier)\",\"compatibilityFingerprint\":\"future\",\"createdAt\":0}"
        .utf8
    )
    try futureDescriptor.write(
      to: futureRoot.appendingPathComponent("generation.json"),
      options: [.atomic]
    )
    let pointerURL = root.appendingPathComponent("current-generation.json")
    let futurePointer = Data(
      "{\"schemaVersion\":999,\"identifier\":\"\(identifier)\",\"compatibilityFingerprint\":\"future\"}"
        .utf8
    )
    try futurePointer.write(to: pointerURL, options: [.atomic])

    XCTAssertThrowsError(
      try StoreGenerationDirectory.open(
        root: root,
        compatibilityFingerprint: "schema-v1"
      )
    )
    XCTAssertEqual(try Data(contentsOf: pointerURL), futurePointer)
    XCTAssertTrue(FileManager.default.fileExists(atPath: futureRoot.path))
    XCTAssertEqual(
      try Data(contentsOf: futureRoot.appendingPathComponent("generation.json")),
      futureDescriptor
    )
  }

  func testConcurrentCompatibleOpenUsesSingleProcessGeneration_CACHE_PT_019() async throws {
    let root = try makeTemporaryDirectory()
    let identifiers = try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<16 {
        group.addTask {
          try StoreGenerationDirectory.open(
            root: root,
            compatibilityFingerprint: "schema-v1"
          ).identifier
        }
      }
      var values: [String] = []
      for try await value in group { values.append(value) }
      return values
    }

    XCTAssertEqual(Set(identifiers).count, 1)
  }

  func testPersistentStoreBundleReusesCompatibleGenerationAndIsolatesIncompatibleOne_CACHE_PT_019()
    async throws
  {
    let root = try makeTemporaryDirectory()
    let first = try await FoveaPersistentStores.open(
      root: root,
      compatibilityFingerprint: "schema-v1"
    )
    let data = Data("generation-data".utf8)
    let contentID = ContentID(data: data).description
    _ = try await first.encoded.commit(
      data: data,
      contentID: contentID,
      namespace: "public:tests"
    )

    let same = try await FoveaPersistentStores.open(
      root: root,
      compatibilityFingerprint: "schema-v1"
    )
    XCTAssertEqual(first.generation.identifier, same.generation.identifier)
    XCTAssertTrue(first.encoded === same.encoded)
    XCTAssertTrue(first.records === same.records)
    let reopenedData = try await same.encoded.read(
      contentID: contentID,
      namespace: "public:tests"
    )
    XCTAssertEqual(reopenedData, data)

    let switched = try await FoveaPersistentStores.open(
      root: root,
      compatibilityFingerprint: "schema-v2"
    )
    XCTAssertNotEqual(first.generation.identifier, switched.generation.identifier)
    await assertThrowsErrorAsync {
      _ = try await switched.encoded.read(contentID: contentID, namespace: "public:tests")
    }
  }
  func testActiveGenerationRejectsDivergentStoreConfiguration_CACHE_PT_024() async throws {
    let root = try makeTemporaryDirectory()
    _ = try await FoveaPersistentStores.open(
      root: root,
      compatibilityFingerprint: "schema-v1",
      encodedSoftLimitBytes: 1024
    )

    do {
      _ = try await FoveaPersistentStores.open(
        root: root,
        compatibilityFingerprint: "schema-v1",
        encodedSoftLimitBytes: 2048
      )
      XCTFail("同一活动 generation 不得创建不同预算的第二 store actor")
    } catch let error as FoveaPersistenceError {
      XCTAssertEqual(error, .incompatibleActiveConfiguration)
    }
  }

}

private struct InjectedGenerationCrash: Error {}
