// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FoveaNukeComparator",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "NukeComparatorAdapter", targets: ["NukeComparatorAdapter"])
    ],
    dependencies: [
        .package(name: "FoveaComparativeLab", path: "../.."),
        .package(name: "Nuke", path: "../../../../.artifacts/comparators/sources/Nuke"),
    ],
    targets: [
        .target(
            name: "NukeComparatorAdapter",
            dependencies: [
                .product(name: "ComparativeLabCore", package: "FoveaComparativeLab"),
                .product(name: "Nuke", package: "Nuke"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
