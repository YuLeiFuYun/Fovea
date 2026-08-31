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
            revision: "3b7f7ef212acfa42a022d7cd0bfad73c0cd2d252"
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
