// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FoveaComparatorAdapterPackage",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "FoveaComparatorAdapter", targets: ["FoveaComparatorAdapter"])
    ],
    dependencies: [
        .package(name: "FoveaComparativeLab", path: "../.."),
        .package(name: "Fovea", path: "../../../.."),
    ],
    targets: [
        .target(
            name: "FoveaComparatorAdapter",
            dependencies: [
                .product(name: "ComparativeLabCore", package: "FoveaComparativeLab"),
                .product(name: "Fovea", package: "Fovea"),
            ]
        ),
        .testTarget(
            name: "FoveaComparatorAdapterTests",
            dependencies: [
                "FoveaComparatorAdapter",
                .product(name: "ComparativeLabCore", package: "FoveaComparativeLab"),
                .product(name: "Fovea", package: "Fovea"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
