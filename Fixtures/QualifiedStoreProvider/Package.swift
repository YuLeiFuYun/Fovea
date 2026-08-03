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
            revision: "50e7032b155187b993b5a82f613c3a0410d32976"
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
