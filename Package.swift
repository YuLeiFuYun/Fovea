// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Fovea",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
    .tvOS(.v15),
    .watchOS(.v8),
  ],
  products: [
    .library(name: "ImageCraftCore", targets: ["ImageCraftCore"]),
    .library(name: "ImageCraftImageIO", targets: ["ImageCraftImageIO"]),
    .library(name: "AkashicCore", targets: ["AkashicCore"]),
    .library(name: "AkashicMemory", targets: ["AkashicMemory"]),
    .library(name: "AkashicDisk", targets: ["AkashicDisk"]),
    .library(name: "FoveaHTTP", targets: ["FoveaHTTP"]),
    .library(name: "FoveaCore", targets: ["FoveaCore"]),
    .library(name: "FoveaSwiftUI", targets: ["FoveaSwiftUI"]),
    .library(name: "FoveaTesting", targets: ["FoveaTesting"]),
  ],
  targets: [
    .target(name: "ImageCraftCore"),
    .target(name: "ImageCraftImageIO", dependencies: ["ImageCraftCore"]),
    .target(name: "AkashicCore"),
    .target(name: "AkashicMemory", dependencies: ["AkashicCore", "ImageCraftCore"]),
    .target(name: "AkashicDisk", dependencies: ["AkashicCore"]),
    .target(name: "FoveaHTTP", dependencies: ["AkashicCore", "AkashicDisk"]),
    .target(
      name: "FoveaCore",
      dependencies: [
        "ImageCraftCore", "ImageCraftImageIO",
        "AkashicCore", "AkashicMemory", "AkashicDisk",
        "FoveaHTTP",
      ]
    ),
    .target(name: "FoveaSwiftUI", dependencies: ["FoveaCore", "ImageCraftCore"]),
    .target(
      name: "FoveaTesting",
      dependencies: [
        "ImageCraftCore", "AkashicCore", "AkashicMemory", "AkashicDisk",
        "FoveaHTTP", "FoveaCore",
      ]
    ),
    .testTarget(
      name: "FoveaPhase0aTests",
      dependencies: [
        "ImageCraftCore", "ImageCraftImageIO",
        "AkashicCore", "AkashicMemory", "AkashicDisk",
        "FoveaHTTP", "FoveaCore", "FoveaSwiftUI", "FoveaTesting",
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
