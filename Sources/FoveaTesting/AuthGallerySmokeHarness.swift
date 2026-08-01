import Foundation
import FoveaCore

/// 鉴权画廊冒烟验收的可序列化单用例证据；只保存摘要和断言，不保存凭据。
package struct AuthGalleryCaseResult: Codable, Hashable, Sendable {
    package let identifier: String
    package let passed: Bool
    package let detail: String

    package init(identifier: String, passed: Bool, detail: String) {
        self.identifier = identifier
        self.passed = passed
        self.detail = detail
    }
}

package struct AuthGallerySummary: Codable, Hashable, Sendable {
    package let crossAccountPixelLeakCount: Int
    package let crossAccountMetadataCouplingCount: Int
    package let noStoreReusableWriteCount: Int
    package let logoutResidueCount: Int
    package let crossOriginAuthorizationLeakCount: Int
    package let revokedCommitResidueCount: Int
    package let sensitiveDiagnosticLeakCount: Int
    package let networkRequestCount: Int

    package var totalViolationCount: Int {
        crossAccountPixelLeakCount
            + crossAccountMetadataCouplingCount
            + noStoreReusableWriteCount
            + logoutResidueCount
            + crossOriginAuthorizationLeakCount
            + revokedCommitResidueCount
            + sensitiveDiagnosticLeakCount
    }
}

package struct AuthGallerySmokeArtifact: Codable, Hashable, Sendable {
    package let schemaVersion: Int
    package let workloadID: String
    package let profileID: String
    package let generatedAt: String
    package let platform: String
    package let architecture: String
    package let operatingSystem: String
    package let verifiedCommit: String
    package let cases: [AuthGalleryCaseResult]
    package let diagnostics: [RecordedDiagnosticEvent]
    package let summary: AuthGallerySummary

    package init(
        cases: [AuthGalleryCaseResult],
        diagnostics: [RecordedDiagnosticEvent],
        summary: AuthGallerySummary
    ) {
        self.schemaVersion = 1
        self.workloadID = "W3-Auth-Gallery-Smoke"
        self.profileID = "W3-AUTH-GALLERY-SMOKE-V1"
        self.generatedAt = ISO8601DateFormatter().string(from: Date())
        self.platform = AuthGalleryEnvironment.platform
        self.architecture = AuthGalleryEnvironment.architecture
        self.operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        self.verifiedCommit =
            ProcessInfo.processInfo.environment["FOVEA_VERIFIED_COMMIT"]
            ?? ProcessInfo.processInfo.environment["GITHUB_SHA"]
            ?? "unverified-local"
        self.cases = cases
        self.diagnostics = diagnostics
        self.summary = summary
    }
}

package enum AuthGallerySmokeHarness {
    @discardableResult
    package static func run(outputDirectory: URL) async throws -> AuthGallerySmokeArtifact {
        let isolation = try await AuthGalleryScenarioRunner.runAccountIsolationCase()
        let noStore = try await AuthGalleryScenarioRunner.runNoStoreCase()
        let revokeRace = try await AuthGalleryScenarioRunner.runRevokeRaceCase()
        let redirect = try AuthGalleryScenarioRunner.runRedirectCase()

        let diagnostics = isolation.diagnostics + noStore.diagnostics + revokeRace.diagnostics
        let diagnosticsData = try JSONEncoder().encode(diagnostics)
        let diagnosticString = String(decoding: diagnosticsData, as: UTF8.self)
        let sensitiveDiagnosticLeakCount = [
            "Bearer account-a",
            "Bearer account-b",
            "Bearer no-store",
            "Bearer delayed",
        ].filter { diagnosticString.contains($0) }.count

        let cases =
            isolation.cases + noStore.cases + revokeRace.cases + redirect.cases + [
                AuthGalleryCaseResult(
                    identifier: "diagnostics-sensitive-data",
                    passed: sensitiveDiagnosticLeakCount == 0,
                    detail: "sensitive diagnostic matches=\(sensitiveDiagnosticLeakCount)"
                )
            ]
        let summary = AuthGallerySummary(
            crossAccountPixelLeakCount: isolation.pixelLeaks,
            crossAccountMetadataCouplingCount: isolation.metadataCoupling,
            noStoreReusableWriteCount: noStore.reusableWrites,
            logoutResidueCount: isolation.logoutResidue,
            crossOriginAuthorizationLeakCount: redirect.authorizationLeaks,
            revokedCommitResidueCount: revokeRace.commitResidue,
            sensitiveDiagnosticLeakCount: sensitiveDiagnosticLeakCount,
            networkRequestCount: isolation.networkRequests + noStore.networkRequests
                + revokeRace.networkRequests
        )
        let artifact = AuthGallerySmokeArtifact(
            cases: cases,
            diagnostics: diagnostics,
            summary: summary
        )
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        let destination = outputDirectory.appendingPathComponent(
            "w3-auth-gallery-smoke-\(artifact.platform.lowercased()).json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(artifact).write(to: destination, options: [.atomic])
        return artifact
    }
}
