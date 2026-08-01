import AkashicCore
import Foundation
import FoveaHTTP
import FoveaPersistence
import XCTest

final class HTTPMetadataBoundaryTests: XCTestCase {
    func testTransportRequestRejectsInvalidResourceLimits_SEC_CASE_042() throws {
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.test/image.png")))

        XCTAssertThrowsError(try TransportRequest(request: request, maximumBytes: 0)) { error in
            XCTAssertEqual(error as? TransportError, .invalidRequestLimits)
        }
        XCTAssertThrowsError(
            try TransportRequest(request: request, maximumBytes: 1, memoryThreshold: -1)
        ) { error in
            XCTAssertEqual(error as? TransportError, .invalidRequestLimits)
        }
        XCTAssertNoThrow(
            try TransportRequest(request: request, maximumBytes: 1, memoryThreshold: 512 * 1024)
        )
    }

    func testResponseHeadRejectsUnboundedOrUnsafeMetadata_SEC_CASE_042() throws {
        XCTAssertThrowsError(
            try TransportResponseHead(statusCode: 99, headers: [:], url: nil)
        ) { error in
            XCTAssertEqual(error as? TransportError, .invalidResponseStatus)
        }
        XCTAssertThrowsError(
            try TransportResponseHead(
                statusCode: 200,
                headers: ["X-Test": "safe\r\ninjected: value"],
                url: nil
            )
        ) { error in
            XCTAssertEqual(error as? TransportError, .invalidResponseHeader)
        }
        XCTAssertThrowsError(
            try TransportResponseHead(
                statusCode: 200,
                headers: ["X-Oversized": String(repeating: "a", count: 16 * 1024 + 1)],
                url: nil
            )
        ) { error in
            XCTAssertEqual(error as? TransportError, .invalidResponseHeader)
        }
        let tooMany = Dictionary(
            uniqueKeysWithValues: (0...64).map { ("x-header-\($0)", "value") }
        )
        XCTAssertThrowsError(
            try TransportResponseHead(statusCode: 200, headers: tooMany, url: nil)
        ) { error in
            XCTAssertEqual(error as? TransportError, .responseHeadersTooLarge)
        }
    }

    func testHTTPMetadataRejectsUnsafeControlCharacters_SEC_CASE_042() throws {
        for control in ["\u{000B}", "\u{001B}", "\u{007F}"] {
            XCTAssertThrowsError(
                try TransportResponseHead(
                    statusCode: 200,
                    headers: ["X-Test": "safe\(control)unsafe"],
                    url: nil
                )
            ) { error in
                XCTAssertEqual(error as? TransportError, .invalidResponseHeader)
            }
            XCTAssertThrowsError(
                try HTTPVarySelection(
                    fieldNames: ["x-test"],
                    values: ["x-test": .field("safe\(control)unsafe")]
                )
            ) { error in
                XCTAssertEqual(error as? HTTPVarySelectionError, .invalidFieldValue("x-test"))
            }
        }

        XCTAssertNoThrow(
            try TransportResponseHead(
                statusCode: 200,
                headers: ["X-Test": "tab\tseparated"],
                url: nil
            )
        )
    }

    func testVarySelectionRejectsNoncanonicalAndUnboundedMetadata_SEC_CASE_042() throws {
        XCTAssertThrowsError(
            try HTTPVarySelection(fieldNames: ["accept-language"], values: [:])
        ) { error in
            XCTAssertEqual(error as? HTTPVarySelectionError, .valueSetMismatch)
        }
        XCTAssertThrowsError(
            try HTTPVarySelection(
                fieldNames: ["accept-language"],
                values: ["accept-language": .field("en\r\nx-injected: value")]
            )
        ) { error in
            XCTAssertEqual(
                error as? HTTPVarySelectionError,
                .invalidFieldValue("accept-language")
            )
        }

        let names = (0...32).map { "x-vary-\($0)" }
        let values = Dictionary(uniqueKeysWithValues: names.map { ($0, HTTPVaryValue.absent) })
        XCTAssertThrowsError(try HTTPVarySelection(fieldNames: names, values: values)) { error in
            XCTAssertEqual(error as? HTTPVarySelectionError, .tooManyFields)
        }
        XCTAssertEqual(
            HTTPCachePolicy.varyFieldNames(in: ["Vary": names.joined(separator: ",")]),
            .unrepresentable
        )
        XCTAssertEqual(
            HTTPCachePolicy.disposition(
                headers: ["Vary": names.joined(separator: ",")],
                isPrivateNamespace: false
            ),
            .noStore
        )
    }

    func testRepresentationIndexesStayConsistentAcrossReplacementAndReopen_CACHE_PT_040()
        async throws
    {
        let root = try makeTemporaryDirectory("representation-index-replacement")
        let store = try await RepresentationRecordStore.open(root: root)
        let variant = String(repeating: "b", count: 64)
        let first = makeRepresentationRecord(
            namespace: "public:tests",
            baseKeyDigest: String(repeating: "a", count: 64),
            variantKeyDigest: variant,
            contentID: "first",
            payloadLength: 1
        )
        let replacement = makeRepresentationRecord(
            namespace: "public:tests",
            baseKeyDigest: String(repeating: "c", count: 64),
            variantKeyDigest: variant,
            contentID: "second",
            payloadLength: 2
        )

        try await store.put(first)
        let firstRecords = await store.records(
            for: first.baseKeyDigest,
            namespace: "public:tests",
            namespaceGeneration: 0
        )
        let hasFirstReference = await store.containsReference(
            to: first.contentID,
            namespace: "public:tests",
            excludingVariantDigest: nil
        )
        XCTAssertEqual(firstRecords, [first])
        XCTAssertTrue(hasFirstReference)

        try await store.put(replacement)
        let removedBaseRecords = await store.records(
            for: first.baseKeyDigest,
            namespace: "public:tests",
            namespaceGeneration: 0
        )
        let replacementRecords = await store.records(
            for: replacement.baseKeyDigest,
            namespace: "public:tests",
            namespaceGeneration: 0
        )
        let hasOldReference = await store.containsReference(
            to: first.contentID,
            namespace: "public:tests",
            excludingVariantDigest: nil
        )
        let hasReplacementReference = await store.containsReference(
            to: replacement.contentID,
            namespace: "public:tests",
            excludingVariantDigest: nil
        )
        XCTAssertTrue(removedBaseRecords.isEmpty)
        XCTAssertEqual(replacementRecords, [replacement])
        XCTAssertFalse(hasOldReference)
        XCTAssertTrue(hasReplacementReference)

        let reopened = try await RepresentationRecordStore.open(root: root)
        let reopenedRecords = await reopened.records(
            for: replacement.baseKeyDigest,
            namespace: "public:tests",
            namespaceGeneration: 0
        )
        XCTAssertEqual(reopenedRecords, [replacement])
    }

    func testOversizedRecordMetadataIsRejectedWithoutMutatingPublishedIndex_SEC_CASE_042()
        async throws
    {
        let root = try makeTemporaryDirectory("representation-metadata-limit")
        let store = try await RepresentationRecordStore.open(root: root)
        let base = String(repeating: "d", count: 64)
        let variant = String(repeating: "e", count: 64)
        let original = makeRepresentationRecord(
            namespace: "public:tests",
            baseKeyDigest: base,
            variantKeyDigest: variant,
            etag: "valid-etag"
        )
        try await store.put(original)

        let oversized = makeRepresentationRecord(
            namespace: "public:tests",
            baseKeyDigest: base,
            variantKeyDigest: variant,
            etag: String(repeating: "x", count: 16 * 1024 + 1)
        )
        do {
            try await store.put(oversized)
            XCTFail("Oversized persistent HTTP metadata must fail closed")
        } catch let error as AkashicError {
            XCTAssertEqual(error, .invalidManifest)
        }

        let retainedRecords = await store.records(
            for: base,
            namespace: "public:tests",
            namespaceGeneration: 0
        )
        XCTAssertEqual(retainedRecords, [original])

        let reopened = try await RepresentationRecordStore.open(root: root)
        let reopenedRecords = await reopened.records(
            for: base,
            namespace: "public:tests",
            namespaceGeneration: 0
        )
        XCTAssertEqual(reopenedRecords, [original])
    }

}
