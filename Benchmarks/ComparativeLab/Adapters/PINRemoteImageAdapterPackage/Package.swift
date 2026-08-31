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
        .package(
            url: "https://github.com/pinterest/PINCache.git",
            exact: "3.0.4"
        ),
    ],
    targets: [
        .target(
            name: "PINRemoteImageComparatorAdapter",
            dependencies: [
                .product(name: "ComparativeLabCore", package: "FoveaComparativeLab"),
                .product(name: "PINRemoteImage", package: "PINRemoteImage"),
                .product(name: "PINCache", package: "PINCache"),
            ]
        ),
        .testTarget(
            name: "PINRemoteImageComparatorAdapterTests",
            dependencies: ["PINRemoteImageComparatorAdapter"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
