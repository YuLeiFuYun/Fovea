// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FoveaPINRemoteImageComparator",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(
            name: "PINRemoteImageComparatorAdapter",
            targets: ["PINRemoteImageComparatorAdapter"]
        )
    ],
    dependencies: [
        .package(name: "FoveaComparativeLab", path: "../.."),
        .package(
            name: "PINRemoteImage",
            path: "../../../../.artifacts/comparators/sources/PINRemoteImage"
        ),
    ],
    targets: [
        .target(
            name: "PINRemoteImageComparatorAdapter",
            dependencies: [
                .product(name: "ComparativeLabCore", package: "FoveaComparativeLab"),
                .product(name: "PINRemoteImage", package: "PINRemoteImage"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
