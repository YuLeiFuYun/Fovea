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
            revision: "0376b960ec8abe54f2d4a9d7d66e97f395215eaf"
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
