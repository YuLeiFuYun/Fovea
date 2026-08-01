// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FoveaAlamofireImageComparator",
    platforms: [.iOS(.v15), .macOS(.v14)],
    products: [
        .library(
            name: "AlamofireImageComparatorAdapter",
            targets: ["AlamofireImageComparatorAdapter"]
        )
    ],
    dependencies: [
        .package(name: "FoveaComparativeLab", path: "../.."),
        .package(
            name: "AlamofireImage",
            path: "../../../../.artifacts/comparators/sources/AlamofireImage"
        ),
    ],
    targets: [
        .target(
            name: "AlamofireImageComparatorAdapter",
            dependencies: [
                .product(name: "ComparativeLabCore", package: "FoveaComparativeLab"),
                .product(name: "AlamofireImage", package: "AlamofireImage"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
