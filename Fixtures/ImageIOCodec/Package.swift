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
            revision: "eaa981c779a71838babb3c99905bdab5dfbd17ab"
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
