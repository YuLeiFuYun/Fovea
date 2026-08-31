// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "W5APNGCompositionOracleLab",
    platforms: [.macOS(.v15)],
    products: [
        .executable(
            name: "W5APNGCompositionOracleLab",
            targets: ["W5APNGCompositionOracleLab"]
        )
    ],
    dependencies: [
        .package(path: "../../../../ImageCraft"),
        .package(path: "../../../.artifacts/research/animation-libs/APNGKit"),
    ],
    targets: [
        .executableTarget(
            name: "W5APNGCompositionOracleLab",
            dependencies: [
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "ImageCraftImageIO", package: "ImageCraft"),
                .product(name: "APNGKit", package: "APNGKit"),
            ]
        )
    ]
)
