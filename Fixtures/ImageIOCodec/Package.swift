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
            revision: "4507da936ef348fa198652c2e4314a1f393b2c90"
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
