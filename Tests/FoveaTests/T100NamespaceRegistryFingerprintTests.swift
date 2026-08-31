import AkashicCore
import FoveaCore
import FoveaStorage
import XCTest

final class T100NamespaceRegistryFingerprintTests: XCTestCase {
    func testFingerprintOverloadsMatchNamespaceGenerationAndActivity_NAMESPACE_FP_PT_001() async throws {
        let namespace = SecurityNamespaceID("fingerprint-equivalence")
        let fingerprint = StorageNamespaceFingerprint(namespace: namespace.value)
        let registry = NamespaceRegistry()

        let byNamespace = try await registry.generation(for: namespace)
        let byFingerprint = try await registry.generation(for: fingerprint)
        let namespaceActive = await registry.isActive(byNamespace, for: namespace)
        let fingerprintActive = await registry.isActive(byNamespace, for: fingerprint)

        XCTAssertEqual(byNamespace, NamespaceGeneration(0))
        XCTAssertEqual(byFingerprint, byNamespace)
        XCTAssertTrue(namespaceActive)
        XCTAssertEqual(fingerprintActive, namespaceActive)
    }

    func testFingerprintGenerationRemainsClosedDuringNamespaceRevocation_NAMESPACE_FP_PT_002()
        async throws
    {
        let namespace = SecurityNamespaceID("fingerprint-revocation")
        let fingerprint = StorageNamespaceFingerprint(namespace: namespace.value)
        let registry = NamespaceRegistry()
        let original = try await registry.generation(for: fingerprint)

        let revokedGeneration = try await registry.beginRevocation(namespace)
        XCTAssertEqual(revokedGeneration, NamespaceGeneration(1))
        let originalActiveDuringRevocation = await registry.isActive(original, for: fingerprint)
        let revokedActiveDuringRevocation = await registry.isActive(revokedGeneration, for: fingerprint)
        XCTAssertFalse(originalActiveDuringRevocation)
        XCTAssertFalse(revokedActiveDuringRevocation)

        do {
            _ = try await registry.generation(for: fingerprint)
            XCTFail("fingerprint lookup must remain closed while namespace cleanup is active")
        } catch let failure as PipelineFailure {
            XCTAssertEqual(failure.category, .namespaceRevoked)
        }

        await registry.finishRevocation(namespace, generation: revokedGeneration)
        let reopened = try await registry.generation(for: fingerprint)
        let reopenedActive = await registry.isActive(reopened, for: fingerprint)
        XCTAssertEqual(reopened, revokedGeneration)
        XCTAssertTrue(reopenedActive)
    }
}
