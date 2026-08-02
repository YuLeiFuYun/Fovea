import CryptoKit
import Foundation

/// 带有固定尺寸、字节数和摘要的基准输入；加载时再次校验，防止基准悄然漂移。
package struct BenchmarkFixture: Sendable {
    package let metadata: BenchmarkSourceDescriptor
    package let data: Data

    package init(metadata: BenchmarkSourceDescriptor, data: Data) {
        self.metadata = metadata
        self.data = data
    }
}

package enum BenchmarkFixtureError: Error, Equatable, Sendable {
    case missingManifest
    case missingFixture(String)
    case checksumMismatch(String)
    case byteCountMismatch(String)
}

package enum BenchmarkFixtureCatalog {
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let fixtures: [Entry]
    }

    private struct Entry: Decodable {
        let name: String
        let pixelWidth: Int
        let pixelHeight: Int
        let byteCount: Int
        let sha256: String
    }

    package static func load(named name: String) throws -> BenchmarkFixture {
        guard let manifestURL = Bundle.module.url(forResource: "manifest", withExtension: "json")
        else {
            throw BenchmarkFixtureError.missingManifest
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion == 1,
            let entry = manifest.fixtures.first(where: { $0.name == name })
        else {
            throw BenchmarkFixtureError.missingFixture(name)
        }
        guard let fixtureURL = Bundle.module.url(forResource: name, withExtension: nil) else {
            throw BenchmarkFixtureError.missingFixture(name)
        }
        let data = try Data(contentsOf: fixtureURL)
        guard data.count == entry.byteCount else {
            throw BenchmarkFixtureError.byteCountMismatch(name)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256 else {
            throw BenchmarkFixtureError.checksumMismatch(name)
        }
        return BenchmarkFixture(
            metadata: BenchmarkSourceDescriptor(
                resourceID: name,
                pixelWidth: entry.pixelWidth,
                pixelHeight: entry.pixelHeight,
                byteCount: entry.byteCount,
                sha256: entry.sha256
            ),
            data: data
        )
    }
}
