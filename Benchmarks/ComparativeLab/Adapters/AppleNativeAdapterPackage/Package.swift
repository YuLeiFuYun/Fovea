// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FoveaAppleNativeComparator",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(
            name: "AppleNativeComparatorAdapter",
            targets: ["AppleNativeComparatorAdapter"]
        )
    ],
    dependencies: [
        .package(name: "FoveaComparativeLab", path: "../..")
    ],
    targets: [
        .target(
            name: "AppleNativeComparatorAdapter",
            dependencies: [
                .product(name: "ComparativeLabCore", package: "FoveaComparativeLab")
            ]
        ),
        .testTarget(
            name: "AppleNativeComparatorAdapterTests",
            dependencies: [
                "AppleNativeComparatorAdapter",
                .product(name: "ComparativeLabCore", package: "FoveaComparativeLab"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
