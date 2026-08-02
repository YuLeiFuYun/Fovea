import Foundation
import FoveaPersistence
import XCTest

final class FoveaDurableFileWriterTests: XCTestCase {
    func testDurableReplacementPublishesCompleteFileAndRemovesTemporaryState_CACHE_PT_013()
        throws
    {
        let root = try makeTemporaryDirectory("durable-file-writer")
        let destination = root.appendingPathComponent("manifest.json")
        try Data("old".utf8).write(to: destination)

        let expected = Data(repeating: 0xA5, count: 128 * 1024)
        try FoveaDurableFileWriter.writeReplacing(expected, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), expected)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names, ["manifest.json"])

        #if os(macOS)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        #endif
    }

    func testDurableReplacementSupportsEmptyPayload_CACHE_PT_013() throws {
        let root = try makeTemporaryDirectory("durable-empty-file")
        let destination = root.appendingPathComponent("empty.json")

        try FoveaDurableFileWriter.writeReplacing(Data(), to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data())
    }

    func testFailedDurableReplacementCleansTemporaryFileAndPreservesTarget_CACHE_PT_013()
        throws
    {
        let root = try makeTemporaryDirectory("durable-failure-cleanup")
        let destination = root.appendingPathComponent("existing-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

        XCTAssertThrowsError(
            try FoveaDurableFileWriter.writeReplacing(Data("replacement".utf8), to: destination)
        )

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names, ["existing-directory"])
    }
}
