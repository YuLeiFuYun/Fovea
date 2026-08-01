// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FoveaCacheLab",
    platforms: [.iOS(.v15), .macOS(.v14)],
    products: [
        .library(name: "CacheLabCore", targets: ["CacheLabCore"]),
        .executable(name: "CacheLabRunner", targets: ["CacheLabRunner"]),
    ],
    dependencies: [
        .package(name: "Fovea", path: "../.."),
        .package(name: "LRUCache", path: "../../.artifacts/cache-comparators/sources/LRUCache"),
        .package(name: "PINCache", path: "../../.artifacts/cache-comparators/sources/PINCache"),
    ],
    targets: [
        .target(
            name: "PINCacheBridge",
            dependencies: [.product(name: "PINCache", package: "PINCache")],
            path: "Sources/PINCacheBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CacheLabCore",
            dependencies: [
                .product(name: "FoveaAdvanced", package: "Fovea"),
                .product(name: "LRUCache", package: "LRUCache"),
                "PINCacheBridge",
            ]
        ),
        .executableTarget(name: "CacheLabRunner", dependencies: ["CacheLabCore"]),
        .testTarget(name: "CacheLabTests", dependencies: ["CacheLabCore"]),
    ],
    swiftLanguageModes: [.v6]
)
