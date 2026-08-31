import CryptoKit
import Foundation
import FoveaStorage
import XCTest

final class T100StorageNamespaceFingerprintTests: XCTestCase {
    func testNamespaceFingerprintMatchesIndependentSHAReference_STORAGE_T100_PT_001() {
        let namespaces = [
            "",
            "public:tests",
            "account:alpha",
            "space and punctuation:/?#[]@!$&'()*+,;=",
            "unicode-命名空间-🔒",
            String(repeating: "x", count: 4_096),
        ]

        for namespace in namespaces {
            let material = Data("fovea-storage-namespace-v1\u{0}\(namespace)".utf8)
            let expected = SHA256.hash(data: material)
                .map { String(format: "%02x", $0) }
                .joined()
            let actual = StorageNamespaceFingerprint(namespace: namespace).value

            XCTAssertEqual(actual, expected)
            XCTAssertEqual(actual.utf8.count, 64)
            XCTAssertTrue(
                actual.utf8.allSatisfy { byte in
                    (48...57).contains(byte) || (97...102).contains(byte)
                }
            )
            XCTAssertEqual(StorageNamespaceFingerprint(namespace: namespace).value, actual)
        }
    }
}
