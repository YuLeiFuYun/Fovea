// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FoveaGifuComparator",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "GifuComparatorAdapter", targets: ["GifuComparatorAdapter"])
    ],
    dependencies: [
        .package(name: "FoveaComparativeLab", path: "../.."),
        .package(name: "Gifu", path: "../../../../.artifacts/research/animation-libs/Gifu"),
    ],
    targets: [
        .target(
            name: "GifuComparatorAdapter",
            dependencies: [
                .product(name: "ComparativeLabCore", package: "FoveaComparativeLab"),
                .product(name: "Gifu", package: "Gifu"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
