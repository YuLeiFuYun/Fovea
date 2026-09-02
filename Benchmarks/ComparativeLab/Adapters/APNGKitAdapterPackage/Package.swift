// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FoveaAPNGKitComparator",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "APNGKitComparatorAdapter", targets: ["APNGKitComparatorAdapter"])
    ],
    dependencies: [
        .package(name: "FoveaComparativeLab", path: "../.."),
        .package(name: "APNGKit", path: "../../../../.artifacts/research/animation-libs/APNGKit"),
    ],
    targets: [
        .target(
            name: "APNGKitComparatorAdapter",
            dependencies: [
                .product(name: "ComparativeLabCore", package: "FoveaComparativeLab"),
                .product(name: "APNGKit", package: "APNGKit"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
