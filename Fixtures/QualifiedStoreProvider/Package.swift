// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "QualifiedStoreProviderFixture",
    platforms: [.macOS(.v12)],
    products: [
        .library(
            name: "QualifiedStoreProviderFixture",
            targets: ["QualifiedStoreProviderFixture"]
        )
    ],
    dependencies: [
        .package(path: "../.."),
        .package(
            url: "https://github.com/YuLeiFuYun/Akashic.git",
            revision: "2715f23d50b5a17b7328be41608eaf1b1c99b0d6"
        ),
    ],
    targets: [
        .target(
            name: "QualifiedStoreProviderFixture",
            dependencies: [
                .product(name: "FoveaAdvanced", package: "Fovea"),
                .product(name: "AkashicCore", package: "Akashic"),
            ]
        )
    ]
)
