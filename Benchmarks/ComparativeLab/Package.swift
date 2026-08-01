// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FoveaComparativeLab",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "ComparativeLabCore", targets: ["ComparativeLabCore"])
    ],
    targets: [
        .target(name: "ComparativeLabCore"),
        .testTarget(name: "ComparativeLabCoreTests", dependencies: ["ComparativeLabCore"]),
    ],
    swiftLanguageModes: [.v6]
)
