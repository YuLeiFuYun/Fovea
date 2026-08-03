// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FoveaSDWebImageComparator",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "SDWebImageComparatorAdapter", targets: ["SDWebImageComparatorAdapter"])
    ],
    dependencies: [
        .package(name: "FoveaComparativeLab", path: "../.."),
        .package(name: "SDWebImage", path: "../../../../.artifacts/comparators/sources/SDWebImage"),
    ],
    targets: [
        .target(
            name: "SDWebImageComparatorAdapter",
            dependencies: [
                .product(name: "ComparativeLabCore", package: "FoveaComparativeLab"),
                .product(name: "SDWebImage", package: "SDWebImage"),
            ]
        ),
        .testTarget(
            name: "SDWebImageComparatorAdapterTests",
            dependencies: [
                "SDWebImageComparatorAdapter",
                .product(name: "ComparativeLabCore", package: "FoveaComparativeLab"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
