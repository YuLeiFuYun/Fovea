// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FoveaAnimatedImageComparator",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(
            name: "AnimatedImageComparatorAdapter",
            targets: ["AnimatedImageComparatorAdapter"]
        )
    ],
    dependencies: [
        .package(name: "FoveaComparativeLab", path: "../.."),
        .package(
            name: "AnimatedImage",
            path: "../../../../.artifacts/research/animation-libs/AnimatedImage"
        ),
    ],
    targets: [
        .target(
            name: "AnimatedImageComparatorAdapter",
            dependencies: [
                .product(name: "ComparativeLabCore", package: "FoveaComparativeLab"),
                .product(name: "AnimatedImage", package: "AnimatedImage"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
