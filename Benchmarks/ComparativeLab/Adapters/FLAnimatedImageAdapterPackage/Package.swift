// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FoveaFLAnimatedImageComparator",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(
            name: "FLAnimatedImageComparatorAdapter",
            targets: ["FLAnimatedImageComparatorAdapter"]
        )
    ],
    dependencies: [
        .package(name: "FoveaComparativeLab", path: "../.."),
        .package(
            name: "FLAnimatedImage",
            path: "../../../../.artifacts/research/animation-libs/FLAnimatedImage"
        ),
    ],
    targets: [
        .target(
            name: "FLAnimatedImageBenchmarkShim",
            dependencies: [
                .product(name: "FLAnimatedImage", package: "FLAnimatedImage")
            ],
            publicHeadersPath: "include"
        ),
        .target(
            name: "FLAnimatedImageComparatorAdapter",
            dependencies: [
                .product(name: "ComparativeLabCore", package: "FoveaComparativeLab"),
                .product(name: "FLAnimatedImage", package: "FLAnimatedImage"),
                "FLAnimatedImageBenchmarkShim",
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
