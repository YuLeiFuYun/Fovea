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
            revision: "2846d4715cc5917711ffa2f100ee310c2290de40"
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
