// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ImageIOCodecFixture",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "ImageIOCodecFixture", targets: ["ImageIOCodecFixture"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/YuLeiFuYun/ImageCraft.git",
            revision: "e147b349d4ff440af6f257c3fb8a7cb4788c953b"
        )
    ],
    targets: [
        .target(
            name: "ImageIOCodecFixture",
            dependencies: [
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "ImageCraftImageIO", package: "ImageCraft"),
            ]
        )
    ]
)
