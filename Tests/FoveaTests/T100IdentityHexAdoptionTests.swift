import CryptoKit
import Foundation
@testable import FoveaCore
import XCTest

final class T100IdentityHexAdoptionTests: XCTestCase {
    func testLowercaseHexMatchesLegacyFormatterAcrossEntireByteDomain_T100_AUTH_PT_008() {
        for value in UInt16(0)...UInt16(255) {
            let byte = UInt8(value)
            let expected = String(format: "%02x", byte)
            let actual = lowercaseHexString([byte])
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(actual.utf8.count, 2)
            XCTAssertTrue(
                actual.utf8.allSatisfy {
                    ($0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!)
                        || ($0 >= Character("a").asciiValue! && $0 <= Character("f").asciiValue!)
                }
            )
        }

        let allBytes = (0...255).map(UInt8.init)
        XCTAssertEqual(lowercaseHexString(allBytes), legacyLowercaseHex_T100(allBytes))
        XCTAssertEqual(lowercaseHexString(allBytes).utf8.count, 512)
    }

    func testLowercaseHexCompositionAndSHAIntegrationMatchLegacyReference_T100_AUTH_PT_009() {
        for length in [0, 1, 2, 3, 7, 15, 16, 31, 32, 33, 63, 64, 65, 127, 128, 255] {
            let bytes = (0..<length).map {
                UInt8(truncatingIfNeeded: ($0 &* 131) ^ ($0 >> 1) ^ 0xA5)
            }
            XCTAssertEqual(lowercaseHexString(bytes), legacyLowercaseHex_T100(bytes))

            let data = Data(bytes)
            let expectedDigest = legacyLowercaseHex_T100(SHA256.hash(data: data))
            XCTAssertEqual(data.sha256Hex, expectedDigest)
            XCTAssertEqual(data.sha256Hex.utf8.count, 64)
        }
    }
}

private func legacyLowercaseHex_T100<Bytes: Sequence>(_ bytes: Bytes) -> String
where Bytes.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}
