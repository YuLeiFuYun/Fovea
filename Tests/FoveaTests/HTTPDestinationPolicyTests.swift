import Foundation
import FoveaHTTP
import XCTest

final class HTTPDestinationPolicyTests: XCTestCase {
    func testExactOriginAllowlistNormalizesSchemeHostAndDefaultPort_RES_PT_017() throws {
        let origin = try HTTPOrigin(
            url: XCTUnwrap(URL(string: "https://IMAGES.example.test/path"))
        )
        let policy = try HTTPDestinationPolicy.allowOnly([origin])

        XCTAssertTrue(
            policy.permits(
                try XCTUnwrap(URL(string: "https://images.example.test:443/other"))
            )
        )
        XCTAssertFalse(
            policy.permits(
                try XCTUnwrap(URL(string: "https://images.example.test:8443/other"))
            )
        )
        XCTAssertFalse(
            policy.permits(
                try XCTUnwrap(URL(string: "https://cdn.example.test/other"))
            )
        )
    }

    func testDestinationAllowlistRejectsRemoteCleartextEvenWhenOriginMatches_RES_PT_017()
        throws
    {
        let remoteHTTP = try HTTPOrigin(
            url: XCTUnwrap(URL(string: "http://images.example.test/image.png"))
        )
        let policy = try HTTPDestinationPolicy.allowOnly([remoteHTTP])

        XCTAssertFalse(
            policy.permits(
                try XCTUnwrap(URL(string: "http://images.example.test/image.png"))
            )
        )
    }

    func testOriginAndPolicyFingerprintAreBoundedAndDeterministic_RES_PT_017() throws {
        XCTAssertThrowsError(
            try HTTPOrigin(
                url: XCTUnwrap(
                    URL(string: "https://\(String(repeating: "a", count: 254))/image.png")
                )
            )
        ) { error in
            XCTAssertEqual(error as? HTTPOriginError, .invalidHost)
        }

        let first = try HTTPOrigin(
            url: XCTUnwrap(URL(string: "https://a.example.test/image.png"))
        )
        let second = try HTTPOrigin(
            url: XCTUnwrap(URL(string: "https://b.example.test/image.png"))
        )
        let one = try HTTPDestinationPolicy.allowOnly([first, second])
        let two = try HTTPDestinationPolicy.allowOnly([second, first])
        XCTAssertEqual(one, two)
    }

    func testOriginAllowlistHasBoundedCardinality_RES_PT_017() throws {
        let origins = try Set(
            (0...256).map { index in
                try HTTPOrigin(
                    url: XCTUnwrap(URL(string: "https://host-\(index).example.test/image.png"))
                )
            }
        )

        XCTAssertThrowsError(try HTTPDestinationPolicy.allowOnly(origins)) { error in
            XCTAssertEqual(error as? HTTPDestinationPolicyError, .tooManyOrigins)
        }
    }
}
