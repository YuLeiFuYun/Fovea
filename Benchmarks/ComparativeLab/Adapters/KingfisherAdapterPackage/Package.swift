// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FoveaKingfisherComparator",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "KingfisherComparatorAdapter", targets: ["KingfisherComparatorAdapter"])
    ],
    dependencies: [
        .package(name: "FoveaComparativeLab", path: "../.."),
        .package(name: "Kingfisher", path: "../../../../.artifacts/comparators/sources/Kingfisher"),
    ],
    targets: [
        .target(
            name: "KingfisherComparatorAdapter",
            dependencies: [
                .product(name: "ComparativeLabCore", package: "FoveaComparativeLab"),
                .product(name: "Kingfisher", package: "Kingfisher"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
