// swift-tools-version: 6.2
import PackageDescription

let concurrencySettings: [SwiftSetting] = [
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
  name: "Fovea",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
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
    .target(name: "ImageCraftCore", swiftSettings: concurrencySettings),
    .target(
      name: "ImageCraftImageIO",
      dependencies: ["ImageCraftCore"],
      swiftSettings: concurrencySettings
    ),
    .target(name: "AkashicCore", swiftSettings: concurrencySettings),
    .target(name: "AkashicMemory", swiftSettings: concurrencySettings),
    .target(
      name: "AkashicDisk",
      dependencies: ["AkashicCore"],
      swiftSettings: concurrencySettings
    ),
    .target(
      name: "FoveaHTTP",
      dependencies: ["AkashicCore"],
      swiftSettings: concurrencySettings
    ),
    .target(
      name: "FoveaCore",
      dependencies: [
        "ImageCraftCore", "AkashicCore", "AkashicMemory", "FoveaHTTP",
      ],
      swiftSettings: concurrencySettings
    ),
    .target(
      name: "FoveaSwiftUI",
      dependencies: ["FoveaCore", "ImageCraftCore"],
      swiftSettings: concurrencySettings
    ),
    .target(
      name: "FoveaTesting",
      dependencies: [
        "ImageCraftCore", "ImageCraftImageIO", "AkashicCore", "AkashicMemory", "AkashicDisk",
        "FoveaHTTP", "FoveaCore",
      ],
      resources: [.process("Fixtures")],
      swiftSettings: concurrencySettings
    ),
    .testTarget(
      name: "FoveaPhase0aTests",
      dependencies: [
        "ImageCraftCore", "ImageCraftImageIO",
        "AkashicCore", "AkashicMemory", "AkashicDisk",
        "FoveaHTTP", "FoveaCore", "FoveaSwiftUI", "FoveaTesting",
      ],
      swiftSettings: concurrencySettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
