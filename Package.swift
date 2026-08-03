// swift-tools-version: 6.4
import PackageDescription

let concurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "Fovea",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "Fovea",
            targets: [
                "FoveaSystem", "FoveaObservability", "FoveaUIKit", "FoveaAppKit", "FoveaSwiftUI",
                "FoveaCore", "FoveaHTTP", "FoveaStorage",
            ]
        ),
        .library(
            name: "FoveaAdvanced",
            targets: [
                "FoveaAdvancedSystem", "FoveaSystem", "FoveaCore", "FoveaHTTP",
                "FoveaPersistence", "FoveaStorage",
            ]
        ),
        .executable(name: "FoveaNetworkLab", targets: ["FoveaNetworkLab"]),
        .executable(name: "FoveaGalleryDemo", targets: ["FoveaGalleryDemo"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/YuLeiFuYun/ImageCraft.git",
            revision: "e147b349d4ff440af6f257c3fb8a7cb4788c953b"
        ),
        .package(
            url: "https://github.com/YuLeiFuYun/Akashic.git",
            revision: "2715f23d50b5a17b7328be41608eaf1b1c99b0d6"
        ),
    ],
    targets: [
        .target(
            name: "FoveaStorage",
            dependencies: [.product(name: "AkashicCore", package: "Akashic")],
            resources: [.process("PrivacyInfo.xcprivacy")],
            swiftSettings: concurrencySettings
        ),
        .target(
            name: "FoveaHTTP",
            dependencies: [
                .product(name: "AkashicCore", package: "Akashic"),
                "FoveaStorage",
            ],
            swiftSettings: concurrencySettings
        ),
        .target(
            name: "FoveaCore",
            dependencies: [
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "AkashicCore", package: "Akashic"),
                .product(name: "AkashicMemory", package: "Akashic"),
                "FoveaHTTP", "FoveaStorage",
            ],
            swiftSettings: concurrencySettings
        ),
        .target(
            name: "FoveaPersistence",
            dependencies: [
                .product(name: "AkashicCore", package: "Akashic"),
                .product(name: "AkashicDisk", package: "Akashic"),
                "FoveaHTTP", "FoveaStorage",
            ],
            resources: [.process("PrivacyInfo.xcprivacy")],
            swiftSettings: concurrencySettings
        ),
        .target(
            name: "FoveaSystem",
            dependencies: [
                "FoveaCore", "FoveaHTTP", "FoveaPersistence",
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "ImageCraftImageIO", package: "ImageCraft"),
            ],
            swiftSettings: concurrencySettings
        ),
        .target(
            name: "FoveaAdvancedSystem",
            dependencies: [
                "FoveaCore", "FoveaHTTP", "FoveaPersistence", "FoveaStorage", "FoveaSystem",
                .product(name: "AkashicCore", package: "Akashic"),
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "ImageCraftImageIO", package: "ImageCraft"),
            ],
            swiftSettings: concurrencySettings
        ),
        .target(
            name: "FoveaObservability",
            dependencies: ["FoveaCore"],
            swiftSettings: concurrencySettings
        ),
        .target(
            name: "FoveaUIKit",
            dependencies: [
                "FoveaCore",
                .product(name: "ImageCraftCore", package: "ImageCraft"),
            ],
            swiftSettings: concurrencySettings
        ),
        .target(
            name: "FoveaAppKit",
            dependencies: [
                "FoveaCore",
                .product(name: "ImageCraftCore", package: "ImageCraft"),
            ],
            swiftSettings: concurrencySettings
        ),
        .target(
            name: "FoveaSwiftUI",
            dependencies: [
                "FoveaCore",
                .product(name: "ImageCraftCore", package: "ImageCraft"),
            ],
            swiftSettings: concurrencySettings
        ),
        .executableTarget(
            name: "FoveaGalleryDemo",
            dependencies: [
                "FoveaCore", "FoveaHTTP", "FoveaSwiftUI", "FoveaSystem",
                .product(name: "ImageCraftCore", package: "ImageCraft"),
            ],
            path: "Examples/FoveaGalleryDemo",
            swiftSettings: concurrencySettings
        ),
        .executableTarget(
            name: "FoveaNetworkLab",
            dependencies: [
                "FoveaCore", "FoveaHTTP", "FoveaSystem",
                .product(name: "ImageCraftCore", package: "ImageCraft"),
            ],
            path: "Tools/FoveaNetworkLab",
            swiftSettings: concurrencySettings
        ),
        .executableTarget(
            name: "FoveaStoreProbe",
            dependencies: ["FoveaPersistence"],
            path: "Tools/FoveaStoreProbe",
            swiftSettings: concurrencySettings
        ),
        .target(
            name: "FoveaTesting",
            dependencies: [
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "ImageCraftImageIO", package: "ImageCraft"),
                .product(name: "AkashicCore", package: "Akashic"),
                .product(name: "AkashicDisk", package: "Akashic"),
                "FoveaStorage", "FoveaHTTP", "FoveaCore", "FoveaPersistence",
            ],
            resources: [.process("Fixtures")],
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "FoveaTests",
            dependencies: [
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "ImageCraftImageIO", package: "ImageCraft"),
                .product(name: "AkashicCore", package: "Akashic"),
                .product(name: "AkashicMemory", package: "Akashic"),
                .product(name: "AkashicDisk", package: "Akashic"),
                "FoveaStorage", "FoveaHTTP", "FoveaCore", "FoveaPersistence",
                "FoveaSystem", "FoveaAdvancedSystem", "FoveaObservability", "FoveaUIKit",
                "FoveaAppKit",
                "FoveaSwiftUI", "FoveaTesting",
            ],
            resources: [.copy("Conformance")],
            swiftSettings: concurrencySettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
