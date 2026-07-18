import Foundation
import FoveaCore
import FoveaHTTP
import XCTest

final class URLSessionTransportTests: XCTestCase {
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
