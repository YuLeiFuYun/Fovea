import AkashicCore
import AkashicDisk
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaPersistence
import FoveaStorage
import ImageCraftCore
import ImageCraftImageIO

/// 执行认证画廊的账户隔离、no-store、撤销竞态与重定向场景。
/// 每个场景返回结构化证据，避免测试通过日志文本推断安全结论。
enum AuthGalleryScenarioRunner {
    static func runAccountIsolationCase() async throws -> IsolationResult {
        let bodyA = try AuthGalleryFixtures.makeSolidPNG(red: 230)
        let bodyB = try AuthGalleryFixtures.makeSolidPNG(red: 20)
        let origin = AuthenticatedOrigin(responses: [
            "Bearer account-a": .init(
                body: bodyA,
                headers: ["Content-Type": "image/png", "Cache-Control": "private, max-age=3600"]
            ),
            "Bearer account-b": .init(
                body: bodyB,
                headers: ["Content-Type": "image/png", "Cache-Control": "private, max-age=3600"]
            ),
        ])
        let diagnostics = BoundedDiagnosticsSink(capacity: 256)
        let root = try temporaryDirectory("w3-isolation")
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records"))
        let pipeline = FoveaPipeline(
            transport: origin,
            encodedStore: encoded,
            recordStore: records,
            diagnostics: diagnostics,
            profileAccessPolicy: .unrestricted,
            decoder: ImageIOImageDecoder()
        )
        let url = URL(string: "https://images.example.test/avatar")!
        let target = try TargetPixels(width: 40, height: 40)
        let accountA = try request(
            url: url,
            target: target,
            namespace: "account-a",
            principal: "principal-a",
            token: "Bearer account-a"
        )
        let accountB = try request(
            url: url,
            target: target,
            namespace: "account-b",
            principal: "principal-b",
            token: "Bearer account-b"
        )

        let imageA = try await pipeline.image(for: accountA)
        let imageB = try await pipeline.image(for: accountB)
        let warmA = try await pipeline.image(for: accountA)
        let warmB = try await pipeline.image(for: accountB)
        var pixelLeaks = 0
        if try AuthGalleryFixtures.centerRed(imageA.cgImage) <= 180 { pixelLeaks += 1 }
        if try AuthGalleryFixtures.centerRed(warmA.cgImage) <= 180 { pixelLeaks += 1 }
        if try AuthGalleryFixtures.centerRed(imageB.cgImage) >= 80 { pixelLeaks += 1 }
        if try AuthGalleryFixtures.centerRed(warmB.cgImage) >= 80 { pixelLeaks += 1 }

        let recordA = await records.record(for: accountA.fetchVariantKey.digestHex)
        let recordB = await records.record(for: accountB.fetchVariantKey.digestHex)
        let physicalA = await recordA.flatMapAsync { record in
            await encoded.physicalID(contentID: record.contentID, namespace: "account-a")
        }
        let physicalB = await recordB.flatMapAsync { record in
            await encoded.physicalID(contentID: record.contentID, namespace: "account-b")
        }
        var metadataCoupling = 0
        if recordA?.securityNamespaceFingerprint
            != StorageNamespaceFingerprint(namespace: "account-a")
        {
            metadataCoupling += 1
        }
        if recordB?.securityNamespaceFingerprint
            != StorageNamespaceFingerprint(namespace: "account-b")
        {
            metadataCoupling += 1
        }
        if physicalA == nil || physicalB == nil || physicalA == physicalB { metadataCoupling += 1 }

        try await pipeline.revoke(namespace: accountA.namespace)
        let revokedRecordA = await records.record(for: accountA.fetchVariantKey.digestHex)
        let revokedPhysicalA = await recordA.flatMapAsync { record in
            await encoded.physicalID(contentID: record.contentID, namespace: "account-a")
        }
        let preservedRecordB = await records.record(for: accountB.fetchVariantKey.digestHex)
        let preservedPhysicalB = await recordB.flatMapAsync { record in
            await encoded.physicalID(contentID: record.contentID, namespace: "account-b")
        }
        var logoutResidue = 0
        if revokedRecordA != nil { logoutResidue += 1 }
        if revokedPhysicalA != nil { logoutResidue += 1 }
        if preservedRecordB == nil || preservedPhysicalB == nil { metadataCoupling += 1 }

        let afterLogoutB = try await pipeline.image(for: accountB)
        if try AuthGalleryFixtures.centerRed(afterLogoutB.cgImage) >= 80 { pixelLeaks += 1 }
        let metrics = await origin.metrics()
        if metrics.requestsByCredential["Bearer account-a"] != 1 { metadataCoupling += 1 }
        if metrics.requestsByCredential["Bearer account-b"] != 1 { metadataCoupling += 1 }

        return IsolationResult(
            cases: [
                .init(
                    identifier: "cross-account-pixels",
                    passed: pixelLeaks == 0,
                    detail: "pixel leaks=\(pixelLeaks)"
                ),
                .init(
                    identifier: "cross-account-storage",
                    passed: metadataCoupling == 0,
                    detail: "metadata coupling=\(metadataCoupling)"
                ),
                .init(
                    identifier: "logout-cleanup",
                    passed: logoutResidue == 0,
                    detail: "logout residue=\(logoutResidue)"
                ),
            ],
            diagnostics: await diagnostics.snapshot(),
            pixelLeaks: pixelLeaks,
            metadataCoupling: metadataCoupling,
            logoutResidue: logoutResidue,
            networkRequests: metrics.requestCount
        )
    }

    static func runNoStoreCase() async throws -> NoStoreResult {
        let body = try AuthGalleryFixtures.makeSolidPNG(red: 170)
        let origin = AuthenticatedOrigin(responses: [
            "Bearer no-store": .init(
                body: body,
                headers: ["Content-Type": "image/png", "Cache-Control": "private, no-store"]
            )
        ])
        let diagnostics = BoundedDiagnosticsSink(capacity: 128)
        let root = try temporaryDirectory("w3-no-store")
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records"))
        let pipeline = FoveaPipeline(
            transport: origin,
            encodedStore: encoded,
            recordStore: records,
            diagnostics: diagnostics,
            profileAccessPolicy: .unrestricted,
            decoder: ImageIOImageDecoder()
        )
        let imageRequest = try request(
            url: URL(string: "https://images.example.test/no-store")!,
            target: try TargetPixels(width: 40, height: 40),
            namespace: "account-no-store",
            principal: "principal-no-store",
            token: "Bearer no-store"
        )
        _ = try await pipeline.image(for: imageRequest)
        _ = try await pipeline.image(for: imageRequest)

        let metrics = await origin.metrics()
        let record = await records.record(for: imageRequest.fetchVariantKey.digestHex)
        let physicalID = await encoded.physicalID(
            contentID: ContentID(data: body).description,
            namespace: imageRequest.namespace.value
        )
        var reusableWrites = 0
        if record != nil { reusableWrites += 1 }
        if physicalID != nil { reusableWrites += 1 }
        if metrics.requestCount != 2 { reusableWrites += 1 }

        return NoStoreResult(
            cases: [
                .init(
                    identifier: "private-no-store",
                    passed: reusableWrites == 0,
                    detail: "reusable writes=\(reusableWrites), requests=\(metrics.requestCount)"
                )
            ],
            diagnostics: await diagnostics.snapshot(),
            reusableWrites: reusableWrites,
            networkRequests: metrics.requestCount
        )
    }

    static func runRevokeRaceCase() async throws -> RevokeRaceResult {
        let body = try AuthGalleryFixtures.makeSolidPNG(red: 100)
        let origin = AuthenticatedOrigin(responses: [
            "Bearer delayed": .init(
                body: body,
                headers: ["Content-Type": "image/png", "Cache-Control": "private, max-age=3600"]
            )
        ])
        let diagnostics = BoundedDiagnosticsSink(capacity: 128)
        let root = try temporaryDirectory("w3-revoke-race")
        let encoded = try await AkashicOriginalEncodedStore.open(
            root: root.appendingPathComponent("encoded"))
        let barrierStore = CommitBarrierEncodedStore(base: encoded)
        let records = try await RepresentationRecordStore.open(
            root: root.appendingPathComponent("records"))
        let pipeline = FoveaPipeline(
            transport: origin,
            encodedStore: barrierStore,
            recordStore: records,
            diagnostics: diagnostics,
            profileAccessPolicy: .unrestricted,
            decoder: ImageIOImageDecoder()
        )
        let imageRequest = try request(
            url: URL(string: "https://images.example.test/delayed")!,
            target: try TargetPixels(width: 40, height: 40),
            namespace: "account-delayed",
            principal: "principal-delayed",
            token: "Bearer delayed"
        )

        let task = Task { try await pipeline.image(for: imageRequest) }
        await barrierStore.waitUntilCommitStarts()
        try await pipeline.revoke(namespace: imageRequest.namespace)
        await barrierStore.releaseCommit()
        var deliveredAfterRevoke = false
        do {
            _ = try await task.value
            deliveredAfterRevoke = true
        } catch {
            // 撤销后失败符合预期。
        }
        let record = await records.record(for: imageRequest.fetchVariantKey.digestHex)
        let physicalID = await encoded.physicalID(
            contentID: ContentID(data: body).description,
            namespace: imageRequest.namespace.value
        )
        var residue = 0
        if deliveredAfterRevoke { residue += 1 }
        if record != nil { residue += 1 }
        if physicalID != nil { residue += 1 }
        let metrics = await origin.metrics()

        return RevokeRaceResult(
            cases: [
                .init(
                    identifier: "revoke-commit-race",
                    passed: residue == 0,
                    detail: "revoked commit residue=\(residue)"
                )
            ],
            diagnostics: await diagnostics.snapshot(),
            commitResidue: residue,
            networkRequests: metrics.requestCount
        )
    }

    static func runRedirectCase() throws -> RedirectResult {
        var original = URLRequest(url: URL(string: "https://a.example.test/private")!)
        original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        original.setValue("session=secret", forHTTPHeaderField: "Cookie")
        original.setValue("api-secret", forHTTPHeaderField: "X-API-Key")
        original.setValue("image/avif", forHTTPHeaderField: "Accept")
        var proposed = URLRequest(url: URL(string: "https://b.example.test/redirected")!)
        proposed.allHTTPHeaderFields = original.allHTTPHeaderFields
        let sanitized = CredentialHeaderPolicy.sanitizedRedirectRequest(
            original: original,
            proposed: proposed
        )
        let leaks = CredentialHeaderPolicy.sensitiveHeaderNames.filter {
            sanitized.value(forHTTPHeaderField: $0) != nil
        }.count
        let acceptPreserved = sanitized.value(forHTTPHeaderField: "Accept") == "image/avif"
        let violations = leaks + (acceptPreserved ? 0 : 1)
        return RedirectResult(
            cases: [
                .init(
                    identifier: "cross-origin-redirect",
                    passed: violations == 0,
                    detail: "credential leaks=\(leaks), accept preserved=\(acceptPreserved)"
                )
            ],
            authorizationLeaks: violations
        )
    }

    private static func request(
        url: URL,
        target: TargetPixels,
        namespace: String,
        principal: String,
        token: String
    ) throws -> ImageRequest {
        try ImageRequest(
            url: url,
            target: target,
            namespace: SecurityNamespaceID(namespace),
            authorizationContext: AuthorizationContextID(principal),
            credentialGeneration: CredentialGeneration(1),
            headers: ["Authorization": token]
        )
    }

    private static func temporaryDirectory(_ suffix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoveaAuthGallery", isDirectory: true)
            .appendingPathComponent("\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

}

struct IsolationResult {
    let cases: [AuthGalleryCaseResult]
    let diagnostics: [RecordedDiagnosticEvent]
    let pixelLeaks: Int
    let metadataCoupling: Int
    let logoutResidue: Int
    let networkRequests: Int
}

struct NoStoreResult {
    let cases: [AuthGalleryCaseResult]
    let diagnostics: [RecordedDiagnosticEvent]
    let reusableWrites: Int
    let networkRequests: Int
}

struct RevokeRaceResult {
    let cases: [AuthGalleryCaseResult]
    let diagnostics: [RecordedDiagnosticEvent]
    let commitResidue: Int
    let networkRequests: Int
}

struct RedirectResult {
    let cases: [AuthGalleryCaseResult]
    let authorizationLeaks: Int
}
