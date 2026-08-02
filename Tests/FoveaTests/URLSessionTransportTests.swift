import AkashicCore
import Foundation
import FoveaCore
import FoveaHTTP
import FoveaStorage
import XCTest

final class URLSessionTransportTests: XCTestCase {
    func testPreCancelledExecutionCreatesNoTaskOrStagingLease() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancellationProbeURLProtocol.self]
        let staging = try makeTemporaryDirectory("pre-cancelled-transport")
        let transport = URLSessionTransport(
            configuration: configuration,
            stagingDirectory: staging
        )
        let marker = staging.deletingLastPathComponent()
            .appendingPathComponent("transport-started-\(UUID().uuidString)")
        var components = URLComponents()
        components.scheme = "https"
        components.host = "cancellation.example.test"
        components.path = "/image.png"
        components.queryItems = [URLQueryItem(name: "marker", value: marker.path)]
        let request = try TransportRequest(
            request: URLRequest(url: try XCTUnwrap(components.url)),
            maximumBytes: 1_024
        )
        let gate = CancellationTestGate()
        let task = Task {
            await gate.wait()
            return try await transport.execute(request)
        }

        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("已取消调用不得启动 transport")
        } catch is CancellationError {
            // 预期在任何文件系统或 URLSession 副作用之前结束。
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testInvalidatedTransportRejectsNewTaskCreation() async throws {
        let root = try makeTemporaryDirectory("invalidated-transport")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = URLSessionTransport(stagingDirectory: root)
        await transport.invalidateAndCancel()

        let request = try TransportRequest(
            request: URLRequest(url: XCTUnwrap(URL(string: "https://example.test/image.png"))),
            maximumBytes: 1_024
        )
        do {
            _ = try await transport.execute(request)
            XCTFail("Invalidated transport unexpectedly created a URLSession task")
        } catch is CancellationError {
            // 符合预期：闭包形成稳定的 Swift 取消边界，而不是 NSException。
        }
    }

    func testPublicTransportResponseDerivesContentIdentityAndByteMetrics() throws {
        let body = Data("fovea-transport-body".utf8)
        let response = TransportResponse(
            head: try TransportResponseHead(statusCode: 200, headers: [:], url: nil),
            body: body,
            metrics: TransportMetrics(receivedBytes: Int.max, spilledToDisk: false)
        )

        XCTAssertEqual(response.digestHex, ContentID(data: body).digestHex)
        XCTAssertEqual(response.metrics.receivedBytes, body.count)
    }

    func testDecodedNetworkMetricsReapplyBoundsAndProtocolSanitization() throws {
        let json = """
            {
              "taskDurationNanoseconds": 1,
              "transactionCount": -1,
              "negotiatedProtocolNames": ["H2", "bad protocol", "h2", "http/1.1", "xxxxxxxxxxxxxxxxx"],
              "reusedConnectionCount": -2,
              "proxyConnectionCount": -3,
              "cellularTransactionCount": -4,
              "expensiveTransactionCount": -5,
              "constrainedTransactionCount": -6,
              "redirectCount": -7
            }
            """
        let metrics = try JSONDecoder().decode(
            TransportNetworkMetrics.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(metrics.transactionCount, 0)
        XCTAssertEqual(metrics.negotiatedProtocolNames, ["h2", "http/1.1"])
        XCTAssertEqual(metrics.reusedConnectionCount, 0)
        XCTAssertEqual(metrics.proxyConnectionCount, 0)
        XCTAssertEqual(metrics.redirectCount, 0)
    }

    func testDecodedNetworkMetricsClampHostilePositiveValues() throws {
        let json = """
            {
              "taskDurationNanoseconds": 18446744073709551615,
              "transactionCount": 9223372036854775807,
              "negotiatedProtocolNames": ["H3", "h3", "bad protocol"],
              "reusedConnectionCount": 9223372036854775807,
              "proxyConnectionCount": 9223372036854775807,
              "cellularTransactionCount": 9223372036854775807,
              "expensiveTransactionCount": 9223372036854775807,
              "constrainedTransactionCount": 9223372036854775807,
              "redirectCount": 9223372036854775807,
              "domainLookupDurationNanoseconds": 18446744073709551615,
              "connectionDurationNanoseconds": 18446744073709551615,
              "secureConnectionDurationNanoseconds": 18446744073709551615,
              "requestDurationNanoseconds": 18446744073709551615,
              "timeToFirstByteNanoseconds": 18446744073709551615,
              "responseDurationNanoseconds": 18446744073709551615
            }
            """
        let metrics = try JSONDecoder().decode(
            TransportNetworkMetrics.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(metrics.taskDurationNanoseconds, 86_400_000_000_000)
        XCTAssertEqual(metrics.transactionCount, 4_096)
        XCTAssertEqual(metrics.negotiatedProtocolNames, ["h3"])
        XCTAssertEqual(metrics.reusedConnectionCount, 4_096)
        XCTAssertEqual(metrics.proxyConnectionCount, 4_096)
        XCTAssertEqual(metrics.cellularTransactionCount, 4_096)
        XCTAssertEqual(metrics.expensiveTransactionCount, 4_096)
        XCTAssertEqual(metrics.constrainedTransactionCount, 4_096)
        XCTAssertEqual(metrics.redirectCount, 4_096)
        XCTAssertEqual(metrics.domainLookupDurationNanoseconds, 86_400_000_000_000)
        XCTAssertEqual(metrics.connectionDurationNanoseconds, 86_400_000_000_000)
        XCTAssertEqual(metrics.secureConnectionDurationNanoseconds, 86_400_000_000_000)
        XCTAssertEqual(metrics.requestDurationNanoseconds, 86_400_000_000_000)
        XCTAssertEqual(metrics.timeToFirstByteNanoseconds, 86_400_000_000_000)
        XCTAssertEqual(metrics.responseDurationNanoseconds, 86_400_000_000_000)
    }

    func testDecodedNetworkMetricsRejectExcessiveProtocolCandidates() throws {
        let protocols = Array(repeating: "h2", count: 65)
        let object: [String: Any] = [
            "taskDurationNanoseconds": 1,
            "transactionCount": 1,
            "negotiatedProtocolNames": protocols,
            "reusedConnectionCount": 0,
            "proxyConnectionCount": 0,
            "cellularTransactionCount": 0,
            "expensiveTransactionCount": 0,
            "constrainedTransactionCount": 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(TransportNetworkMetrics.self, from: data)
        )
    }

    func testStagingDirectoryLeaseRemovesAbandonedButNotActiveSessions() async throws {
        let root = try makeTemporaryDirectory("staging-directory-lease")
        let abandoned = root.appendingPathComponent("session-abandoned", isDirectory: true)
        try FoveaManagedFileSecurity.prepareDirectory(abandoned)
        let abandonedOwner = abandoned.appendingPathComponent(".owner.lock")
        XCTAssertTrue(FileManager.default.createFile(atPath: abandonedOwner.path, contents: Data()))
        try FoveaManagedFileSecurity.securePublishedFile(abandonedOwner)
        try Data("private-response".utf8).write(
            to: abandoned.appendingPathComponent("stage-orphan")
        )
        let legacy = root.appendingPathComponent("stage-legacy")
        try Data("legacy-private-response".utf8).write(to: legacy)
        try FoveaManagedFileSecurity.securePublishedFile(legacy)

        var first: StagingDirectoryLease? = try await StagingDirectoryLease.acquire(root: root)
        let firstDirectory = try XCTUnwrap(first?.directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))

        var second: StagingDirectoryLease? = try await StagingDirectoryLease.acquire(root: root)
        let secondDirectory = try XCTUnwrap(second?.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondDirectory.path))

        first = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondDirectory.path))
        second = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondDirectory.path))
    }

    #if os(macOS)
        func testStagingMaintenanceLockTimesOutInsteadOfBlockingForever_RES_PT_020()
            async throws
        {
            let root = try makeTemporaryDirectory("staging-maintenance-timeout")
            try FoveaManagedFileSecurity.prepareDirectory(root)
            let lockURL = root.appendingPathComponent(".fovea-staging-maintenance.lock")
            XCTAssertTrue(FileManager.default.createFile(atPath: lockURL.path, contents: Data()))
            try FoveaManagedFileSecurity.securePublishedFile(lockURL)
            let ready = root.appendingPathComponent("holder-ready")

            let holder = Process()
            holder.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            holder.arguments = [
                "python3",
                "-c",
                """
                import fcntl, pathlib, sys, time
                handle = open(sys.argv[1], "r+")
                fcntl.lockf(handle, fcntl.LOCK_EX)
                pathlib.Path(sys.argv[2]).write_text("ready")
                time.sleep(10)
                """,
                lockURL.path,
                ready.path,
            ]
            try holder.run()
            defer {
                if holder.isRunning { holder.terminate() }
                holder.waitUntilExit()
            }

            for _ in 0..<200 where !FileManager.default.fileExists(atPath: ready.path) {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))

            do {
                _ = try await StagingDirectoryLease.acquire(
                    root: root,
                    maintenanceLockTimeoutNanoseconds: 75_000_000
                )
                XCTFail("A foreign maintenance lock must reach the bounded timeout")
            } catch let error as POSIXError {
                XCTAssertEqual(error.code, .ETIMEDOUT)
            }
        }
    #endif

    func testTransportReusePolicyBoundsAndHashesCallerContext() {
        let reusable = TransportReusePolicy.reusable(contextIdentifier: "  shared-session-v1  ")
        let same = TransportReusePolicy.reusable(contextIdentifier: "shared-session-v1")
        let oversized = TransportReusePolicy.reusable(
            contextIdentifier: String(repeating: "x", count: 1_025)
        )
        let controlled = TransportReusePolicy.reusable(contextIdentifier: "shared\nsecret")

        XCTAssertTrue(reusable.allowsCrossRequestReuse)
        XCTAssertEqual(reusable.executionFingerprint, same.executionFingerprint)
        XCTAssertFalse(oversized.allowsCrossRequestReuse)
        XCTAssertFalse(controlled.allowsCrossRequestReuse)
        XCTAssertFalse(reusable.executionFingerprint.contains("shared-session-v1"))
    }

    func testTransportRequestCanonicalizesAndBoundsCredentialHeaderNames() throws {
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.test/image.png")))
        let normalized = try TransportRequest(
            request: request,
            maximumBytes: 1_024,
            credentialHeaderNames: ["X-Tenant-Credential"]
        )
        XCTAssertEqual(normalized.credentialHeaderNames, ["x-tenant-credential"])

        XCTAssertThrowsError(
            try TransportRequest(
                request: request,
                maximumBytes: 1_024,
                credentialHeaderNames: ["x-valid", "X-Valid"]
            )
        ) { error in
            XCTAssertEqual(error as? TransportError, .invalidCredentialHeaderMetadata)
        }
        XCTAssertThrowsError(
            try TransportRequest(
                request: request,
                maximumBytes: 1_024,
                credentialHeaderNames: ["bad header"]
            )
        ) { error in
            XCTAssertEqual(error as? TransportError, .invalidCredentialHeaderMetadata)
        }
    }

    func testResponseHeadRejectsUnsafeFinalURLAndMetricsClampNegativeBytes() throws {
        XCTAssertThrowsError(
            try TransportResponseHead(
                statusCode: 200,
                headers: [:],
                url: URL(string: "file:///tmp/image.png")
            )
        ) { error in
            XCTAssertEqual(error as? TransportError, .invalidResponseURL)
        }
        XCTAssertThrowsError(
            try TransportResponseHead(
                statusCode: 200,
                headers: [:],
                url: URL(string: "https://user:secret@example.test/image.png")
            )
        ) { error in
            XCTAssertEqual(error as? TransportError, .invalidResponseURL)
        }

        let metrics = TransportMetrics(receivedBytes: -1, spilledToDisk: false)
        XCTAssertEqual(metrics.receivedBytes, 0)
    }

    func testTransportRequestAllowsHighMemoryThresholdButRejectsExtremeHardLimit() throws {
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.test/image.png")))

        XCTAssertNoThrow(
            try TransportRequest(
                request: request,
                maximumBytes: 1_024,
                memoryThreshold: 2_048
            )
        )
        XCTAssertThrowsError(
            try TransportRequest(
                request: request,
                maximumBytes: Int.max,
                memoryThreshold: 0
            )
        )
    }

    func testCustomConfigurationDefaultsToTaskLocalReuse_AUTH_PT_008() {
        let custom = URLSessionTransport(configuration: .ephemeral)
        let builtIn = URLSessionTransport()
        let explicitlyScoped = URLSessionTransport(
            configuration: .ephemeral,
            reusePolicy: .reusable(contextIdentifier: "tests-explicit-session-context-v1")
        )

        XCTAssertFalse(custom.reusePolicy.allowsCrossRequestReuse)
        XCTAssertTrue(builtIn.reusePolicy.allowsCrossRequestReuse)
        XCTAssertTrue(explicitlyScoped.reusePolicy.allowsCrossRequestReuse)
    }

    func testURLSessionPolicyClampsHostileControlPlaneValues() {
        let policy = URLSessionTransportPolicy(
            requestTimeoutSeconds: Int.max,
            resourceTimeoutSeconds: Int.max,
            maximumConnectionsPerHost: Int.max
        )

        XCTAssertEqual(policy.requestTimeoutSeconds, 3_600)
        XCTAssertEqual(policy.resourceTimeoutSeconds, 86_400)
        XCTAssertEqual(policy.maximumConnectionsPerHost, 64)
    }

    func testBuiltInSessionPolicyChangesReusableTransportIdentity_RES_PT_012() {
        let first = URLSessionTransport(
            policy: URLSessionTransportPolicy(
                waitsForConnectivity: true,
                requestTimeoutSeconds: 10,
                resourceTimeoutSeconds: 20,
                maximumConnectionsPerHost: 2
            )
        )
        let second = URLSessionTransport(
            policy: URLSessionTransportPolicy(
                waitsForConnectivity: false,
                requestTimeoutSeconds: 10,
                resourceTimeoutSeconds: 20,
                maximumConnectionsPerHost: 2
            )
        )

        XCTAssertNotEqual(
            first.reusePolicy.executionFingerprint, second.reusePolicy.executionFingerprint)

        let origin = try? HTTPOrigin(
            url: URL(string: "https://images.example.test/image.png")!
        )
        let restrictedPolicy = try? origin.map {
            try HTTPDestinationPolicy.allowOnly([$0])
        }
        let defaultDestination = URLSessionTransport(
            policy: URLSessionTransportPolicy()
        )
        let restricted = restrictedPolicy.map {
            URLSessionTransport(
                policy: URLSessionTransportPolicy(destinationPolicy: $0)
            )
        }
        XCTAssertNotNil(restricted)
        XCTAssertNotEqual(
            defaultDestination.reusePolicy.executionFingerprint,
            restricted?.reusePolicy.executionFingerprint
        )
    }

    func testConfigurationIsSanitizedBeforeSessionCreation_AUTH_PT_008() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConfigurationProbeURLProtocol.self]
        let cookieStorage = HTTPCookieStorage.sharedCookieStorage(
            forGroupContainerIdentifier: UUID().uuidString)
        configuration.httpCookieStorage = cookieStorage
        configuration.httpShouldSetCookies = true
        configuration.urlCredentialStorage = .shared
        configuration.httpAdditionalHeaders = [
            "Authorization": "Bearer ambient-secret",
            "X-Ambient-Variant": "must-not-leak",
        ]
        let url = try XCTUnwrap(URL(string: "https://configuration.example.test/probe"))
        let cookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .domain: "configuration.example.test",
                .path: "/",
                .name: "session",
                .value: "must-not-leak",
                .secure: "TRUE",
            ])
        )
        cookieStorage.setCookie(cookie)

        let sanitized = URLSessionTransport.sanitizedConfiguration(configuration, policy: nil)
        XCTAssertNil(sanitized.urlCache)
        XCTAssertNil(sanitized.httpCookieStorage)
        XCTAssertFalse(sanitized.httpShouldSetCookies)
        XCTAssertNil(sanitized.urlCredentialStorage)
        XCTAssertTrue(sanitized.httpAdditionalHeaders?.isEmpty ?? true)

        let response = try await URLSessionTransport(configuration: configuration).execute(
            try TransportRequest(
                request: {
                    var request = URLRequest(url: url)
                    request.allowsCellularAccess = false
                    request.allowsConstrainedNetworkAccess = false
                    request.allowsExpensiveNetworkAccess = false
                    return request
                }(),
                maximumBytes: 1024,
                memoryThreshold: 1024
            )
        )
        let probe = try JSONDecoder().decode(ConfigurationProbe.self, from: try response.body)

        XCTAssertNil(probe.cookie)
        XCTAssertNil(probe.authorization)
        XCTAssertNil(probe.ambientVariant)
        XCTAssertEqual(
            probe.cachePolicy, URLRequest.CachePolicy.reloadIgnoringLocalCacheData.rawValue)
        XCTAssertFalse(probe.allowsCellularAccess)
        XCTAssertFalse(probe.allowsConstrainedNetworkAccess)
        XCTAssertFalse(probe.allowsExpensiveNetworkAccess)
    }

    func testDestinationPolicyRejectsInitialRequestAndCrossOriginRedirect_RES_PT_017() async throws
    {
        let allowedOrigin = try HTTPOrigin(
            url: XCTUnwrap(URL(string: "https://allowed.example.test/image.png"))
        )
        let destinationPolicy = try HTTPDestinationPolicy.allowOnly([allowedOrigin])
        let transport = URLSessionTransport(
            policy: URLSessionTransportPolicy(destinationPolicy: destinationPolicy)
        )
        let deniedRequest = URLRequest(
            url: try XCTUnwrap(URL(string: "https://denied.example.test/image.png"))
        )

        do {
            _ = try await transport.execute(
                try TransportRequest(request: deniedRequest, maximumBytes: 1024)
            )
            XCTFail("Initial destination outside the allowlist must fail before URLSession")
        } catch let error as TransportError {
            XCTAssertEqual(error, .destinationDisallowed)
        }

        let original = URLRequest(
            url: try XCTUnwrap(URL(string: "https://allowed.example.test/start.png"))
        )
        let redirected = URLRequest(
            url: try XCTUnwrap(URL(string: "https://denied.example.test/final.png"))
        )
        XCTAssertThrowsError(
            try HTTPRedirectPolicy.request(
                original: original,
                proposed: redirected,
                additionalSensitiveNames: [],
                destinationPolicy: destinationPolicy
            )
        ) { error in
            XCTAssertEqual(error as? TransportError, .destinationDisallowed)
        }
    }

    func testProxyTrustPolicyIsExplicitAndFailsClosedWhenVerificationIsRequired_RES_PT_015()
        throws
    {
        let strict = URLSessionTransportPolicy(proxyPolicy: .requireNoProxyInTaskMetrics)
        let system = URLSessionTransportPolicy(proxyPolicy: .system)
        XCTAssertNotEqual(strict.fingerprint, system.fingerprint)

        XCTAssertThrowsError(
            try URLSessionProxyPolicy.requireNoProxyInTaskMetrics.validate(nil)
        ) { error in
            XCTAssertEqual(error as? TransportError, .proxyMetricsUnavailable)
        }

        let direct = TransportNetworkMetrics(
            taskDurationNanoseconds: 1,
            transactionCount: 1,
            negotiatedProtocolNames: ["h2"],
            reusedConnectionCount: 0,
            proxyConnectionCount: 0,
            cellularTransactionCount: 0,
            expensiveTransactionCount: 0,
            constrainedTransactionCount: 0
        )
        XCTAssertNoThrow(
            try URLSessionProxyPolicy.requireNoProxyInTaskMetrics.validate(direct)
        )

        let proxied = TransportNetworkMetrics(
            taskDurationNanoseconds: 1,
            transactionCount: 1,
            negotiatedProtocolNames: ["h2"],
            reusedConnectionCount: 0,
            proxyConnectionCount: 1,
            cellularTransactionCount: 0,
            expensiveTransactionCount: 0,
            constrainedTransactionCount: 0
        )
        XCTAssertThrowsError(
            try URLSessionProxyPolicy.requireNoProxyInTaskMetrics.validate(proxied)
        ) { error in
            XCTAssertEqual(error as? TransportError, .proxyConnectionDisallowed)
        }
    }

    func testMalformedOrConflictingContentLengthFailsClosed_HTTP_CONF_CONTENT_LENGTH_001()
        async throws
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContentLengthURLProtocol.self]
        let transport = URLSessionTransport(
            configuration: configuration,
            stagingDirectory: try makeTemporaryDirectory("content-length-invalid")
        )

        for path in ["malformed", "conflicting"] {
            let url = try XCTUnwrap(URL(string: "https://content-length.example.test/\(path)"))
            do {
                _ = try await transport.execute(
                    try TransportRequest(
                        request: URLRequest(url: url),
                        maximumBytes: 1024,
                        memoryThreshold: 1024
                    )
                )
                XCTFail("畸形或冲突 Content-Length 必须失败关闭: \(path)")
            } catch let error as TransportError {
                XCTAssertEqual(error, .invalidContentLength)
            }
        }
    }

    func testMatchingDuplicateContentLengthIsAccepted_HTTP_CONF_CONTENT_LENGTH_001() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContentLengthURLProtocol.self]
        let transport = URLSessionTransport(
            configuration: configuration,
            stagingDirectory: try makeTemporaryDirectory("content-length-duplicate")
        )
        let url = try XCTUnwrap(URL(string: "https://content-length.example.test/matching"))

        let response = try await transport.execute(
            try TransportRequest(
                request: URLRequest(url: url),
                maximumBytes: 1024,
                memoryThreshold: 1024
            )
        )

        XCTAssertEqual(try response.body, ContentLengthURLProtocol.body)
    }

    func testDelegateTransportCollectsSanitizedTaskMetrics_DIAG_PT_011() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedURLProtocol.self]
        let transport = URLSessionTransport(
            configuration: configuration,
            stagingDirectory: try makeTemporaryDirectory("url-session-metrics")
        )
        let url = try XCTUnwrap(URL(string: "https://transport.example.test/metrics"))

        let response = try await transport.execute(
            try TransportRequest(
                request: URLRequest(url: url),
                maximumBytes: 256 * 1024,
                memoryThreshold: 256 * 1024
            )
        )

        let metrics = try XCTUnwrap(response.metrics.network)
        XCTAssertGreaterThanOrEqual(metrics.transactionCount, 1)
        XCTAssertGreaterThan(metrics.taskDurationNanoseconds, 0)
        XCTAssertGreaterThanOrEqual(metrics.reusedConnectionCount, 0)
        XCTAssertGreaterThanOrEqual(metrics.proxyConnectionCount, 0)
    }

    func testDelegateTransportConsumesChunksWithoutPerByteIteration() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedURLProtocol.self]
        let staging = try makeTemporaryDirectory("url-session-staging")
        let transport = URLSessionTransport(
            configuration: configuration,
            stagingDirectory: staging
        )
        let url = try XCTUnwrap(URL(string: "https://transport.example.test/large"))
        let expected = ChunkedURLProtocol.body(for: url)

        let response = try await transport.execute(
            try TransportRequest(
                request: URLRequest(url: url),
                maximumBytes: expected.count + 1,
                memoryThreshold: 1024
            )
        )

        XCTAssertEqual(response.head.statusCode, 200)
        XCTAssertEqual(try response.body, expected)
        XCTAssertEqual(response.digestHex, ContentID(data: expected).digestHex)
        XCTAssertTrue(response.metrics.spilledToDisk)
        XCTAssertEqual(response.head.headers["content-type"], "application/octet-stream")
        XCTAssertNil(response.head.headers["Content-Type"])
    }

    func testRedirectPolicyRejectsRemoteCleartextAndAllowsLoopback_SEC_CASE_033() throws {
        var original = URLRequest(
            url: try XCTUnwrap(URL(string: "https://secure.example.test/image.png"))
        )
        original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        var downgrade = URLRequest(
            url: try XCTUnwrap(URL(string: "http://remote.example.test/image.png"))
        )
        downgrade.allHTTPHeaderFields = original.allHTTPHeaderFields

        XCTAssertThrowsError(
            try HTTPRedirectPolicy.request(
                original: original,
                proposed: downgrade,
                additionalSensitiveNames: []
            )
        ) { error in
            XCTAssertEqual(error as? TransportError, .insecureRedirect)
        }

        var loopback = URLRequest(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/image.png"))
        )
        loopback.allHTTPHeaderFields = original.allHTTPHeaderFields
        let accepted = try HTTPRedirectPolicy.request(
            original: original,
            proposed: loopback,
            additionalSensitiveNames: []
        )
        XCTAssertNil(accepted.value(forHTTPHeaderField: "Authorization"))
    }

    func testEventRouterDeinitFinishesRegisteredStreams() async throws {
        var router: URLSessionEventRouter? = URLSessionEventRouter()
        let stream = await router?.events(
            for: 99,
            credentialHeaderNames: [],
            destinationPolicy: .secureDefault
        )
        router = nil

        do {
            guard let stream else { return XCTFail("Expected an event stream") }
            for try await _ in stream {}
            XCTFail("Router destruction must cancel active streams")
        } catch is CancellationError {
            // 符合预期：已注册流不得比其路由所有者存活更久。
        }
    }

    func testEventRouterScopesCustomCredentialHeadersToTask() async throws {
        let router = URLSessionEventRouter()
        let destinationPolicy = try HTTPDestinationPolicy.allowOnly([
            HTTPOrigin(url: XCTUnwrap(URL(string: "https://example.test/image.png")))
        ])
        let events = await router.events(
            for: 42,
            credentialHeaderNames: ["x-tenant-credential"],
            destinationPolicy: destinationPolicy
        )
        _ = events
        let registeredContext = await router.redirectContext(for: 42)
        let context = try XCTUnwrap(registeredContext)
        XCTAssertEqual(context.credentialHeaderNames, ["x-tenant-credential"])
        XCTAssertTrue(
            context.destinationPolicy.permits(
                try XCTUnwrap(URL(string: "https://example.test/redirect.png"))
            )
        )

        router.unregister(taskID: 42)
        try? await Task.sleep(for: .milliseconds(10))
        let removed = await router.redirectContext(for: 42)
        XCTAssertNil(removed, "A missing route must not widen an exact destination policy")
    }

    func testDelegateTransportEnforcesHardLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedURLProtocol.self]
        let transport = URLSessionTransport(
            configuration: configuration,
            stagingDirectory: try makeTemporaryDirectory("url-session-limit")
        )
        let url = try XCTUnwrap(URL(string: "https://transport.example.test/large"))

        do {
            _ = try await transport.execute(
                try TransportRequest(
                    request: URLRequest(url: url),
                    maximumBytes: 1024,
                    memoryThreshold: 512
                )
            )
            XCTFail("Expected body limit failure")
        } catch let error as TransportError {
            XCTAssertEqual(error, .bodyTooLarge)
        }
    }
}

private final class ChunkedURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "transport.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.body(for: url)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/octet-stream",
                "Content-Length": String(body.count),
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for start in stride(from: 0, to: body.count, by: 4096) {
            let end = min(body.count, start + 4096)
            client?.urlProtocol(self, didLoad: body.subdata(in: start..<end))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(for url: URL) -> Data {
        Data((0..<(128 * 1024)).map { UInt8($0 % 251) })
    }
}

private struct ConfigurationProbe: Codable {
    let cookie: String?
    let authorization: String?
    let ambientVariant: String?
    let cachePolicy: UInt
    let allowsCellularAccess: Bool
    let allowsConstrainedNetworkAccess: Bool
    let allowsExpensiveNetworkAccess: Bool
}

private final class ConfigurationProbeURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "configuration.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body: Data
        do {
            body = try JSONEncoder().encode(
                ConfigurationProbe(
                    cookie: request.value(forHTTPHeaderField: "Cookie"),
                    authorization: request.value(forHTTPHeaderField: "Authorization"),
                    ambientVariant: request.value(forHTTPHeaderField: "X-Ambient-Variant"),
                    cachePolicy: request.cachePolicy.rawValue,
                    allowsCellularAccess: request.allowsCellularAccess,
                    allowsConstrainedNetworkAccess: request.allowsConstrainedNetworkAccess,
                    allowsExpensiveNetworkAccess: request.allowsExpensiveNetworkAccess
                )
            )
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "Content-Length": String(body.count),
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ContentLengthURLProtocol: URLProtocol {
    static let body = Data("fovea-content-length".utf8)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "content-length.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let value: String
        switch url.lastPathComponent {
        case "malformed":
            value = "not-a-length"
        case "conflicting":
            value = "\(Self.body.count), \(Self.body.count + 1)"
        default:
            value = "\(Self.body.count), \(Self.body.count)"
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/octet-stream",
                "Content-Length": value,
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor CancellationTestGate {
    private var entered = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll(keepingCapacity: false)
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        for waiter in openWaiters { waiter.resume() }
        openWaiters.removeAll(keepingCapacity: false)
    }
}

private final class CancellationProbeURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cancellation.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let markerPath = components.queryItems?.first(where: { $0.name == "marker" })?.value
        {
            FileManager.default.createFile(atPath: markerPath, contents: Data())
        }
        client?.urlProtocol(self, didFailWithError: CancellationError())
    }

    override func stopLoading() {}
}
