import Foundation
import FoveaCore
import FoveaHTTP
import XCTest

final class URLSessionTransportTests: XCTestCase {
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

  func testConfigurationIsSanitizedBeforeSessionCreation_AUTH_PT_008() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ConfigurationProbeURLProtocol.self]
    let cookieStorage = HTTPCookieStorage.sharedCookieStorage(
      forGroupContainerIdentifier: UUID().uuidString)
    configuration.httpCookieStorage = cookieStorage
    configuration.httpShouldSetCookies = true
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

    let response = try await URLSessionTransport(configuration: configuration).execute(
      TransportRequest(
        request: URLRequest(url: url),
        maximumBytes: 1024,
        memoryThreshold: 1024
      )
    )
    let probe = try JSONDecoder().decode(ConfigurationProbe.self, from: response.body)

    XCTAssertNil(probe.cookie)
    XCTAssertEqual(probe.cachePolicy, URLRequest.CachePolicy.reloadIgnoringLocalCacheData.rawValue)
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
          TransportRequest(
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
      TransportRequest(
        request: URLRequest(url: url),
        maximumBytes: 1024,
        memoryThreshold: 1024
      )
    )

    XCTAssertEqual(response.body, ContentLengthURLProtocol.body)
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
      TransportRequest(
        request: URLRequest(url: url),
        maximumBytes: expected.count + 1,
        memoryThreshold: 1024
      )
    )

    XCTAssertEqual(response.head.statusCode, 200)
    XCTAssertEqual(response.body, expected)
    XCTAssertEqual(response.digestHex, ContentID(data: expected).digestHex)
    XCTAssertTrue(response.metrics.spilledToDisk)
    XCTAssertEqual(response.head.headers["content-type"], "application/octet-stream")
    XCTAssertNil(response.head.headers["Content-Type"])
  }

  func testEventRouterScopesCustomCredentialHeadersToTask() async {
    let router = URLSessionEventRouter()
    let events = await router.events(
      for: 42,
      credentialHeaderNames: ["x-tenant-credential"]
    )
    _ = events
    let registered = await router.credentialHeaderNames(for: 42)
    XCTAssertEqual(registered, ["x-tenant-credential"])

    router.unregister(taskID: 42)
    try? await Task.sleep(for: .milliseconds(10))
    let removed = await router.credentialHeaderNames(for: 42)
    XCTAssertTrue(removed.isEmpty)
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
        TransportRequest(
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
  let cachePolicy: UInt
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
          cachePolicy: request.cachePolicy.rawValue
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
