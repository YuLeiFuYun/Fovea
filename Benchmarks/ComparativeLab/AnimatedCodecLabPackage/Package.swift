// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "W5AnimatedCodecLabPackage",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .executable(name: "W5AnimatedCodecLab", targets: ["W5AnimatedCodecLab"])
    ],
    dependencies: [
        .package(name: "ImageCraft", path: "../../../../ImageCraft"),
        .package(name: "SDWebImage", path: "../../../.artifacts/comparators/sources/SDWebImage"),
        .package(name: "PINRemoteImage", path: "../../../.artifacts/comparators/sources/PINRemoteImage")
    ],
    targets: [
        .executableTarget(
            name: "W5AnimatedCodecLab",
            dependencies: [
                .product(name: "ImageCraftImageIO", package: "ImageCraft"),
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "SDWebImage", package: "SDWebImage"),
                .product(name: "PINRemoteImage", package: "PINRemoteImage")
            ],
            path: "Sources/W5AnimatedCodecLab"
        )
    ],
    swiftLanguageModes: [.v6]
)
