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
    .library(name: "FoveaPersistence", targets: ["FoveaPersistence"]),
    .library(name: "FoveaSystem", targets: ["FoveaSystem"]),
    .library(name: "FoveaUIKit", targets: ["FoveaUIKit"]),
    .library(name: "FoveaAppKit", targets: ["FoveaAppKit"]),
    .library(name: "FoveaSwiftUI", targets: ["FoveaSwiftUI"]),
    .library(name: "FoveaTesting", targets: ["FoveaTesting"]),
    .executable(name: "FoveaNetworkLab", targets: ["FoveaNetworkLab"]),
    .executable(name: "FoveaGalleryDemo", targets: ["FoveaGalleryDemo"]),
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
      name: "FoveaPersistence",
      dependencies: ["AkashicCore", "AkashicDisk", "FoveaHTTP"],
      swiftSettings: concurrencySettings
    ),
    .target(
      name: "FoveaSystem",
      dependencies: ["FoveaCore", "FoveaHTTP", "FoveaPersistence", "ImageCraftImageIO"],
      swiftSettings: concurrencySettings
    ),
    .target(
      name: "FoveaUIKit",
      dependencies: ["FoveaCore", "ImageCraftCore"],
      swiftSettings: concurrencySettings
    ),
    .target(
      name: "FoveaAppKit",
      dependencies: ["FoveaCore", "ImageCraftCore"],
      swiftSettings: concurrencySettings
    ),
    .target(
      name: "FoveaSwiftUI",
      dependencies: ["FoveaCore", "ImageCraftCore"],
      swiftSettings: concurrencySettings
    ),
    .executableTarget(
      name: "FoveaGalleryDemo",
      dependencies: [
        "FoveaCore", "FoveaHTTP", "FoveaSwiftUI", "FoveaSystem", "ImageCraftCore",
      ],
      path: "Examples/FoveaGalleryDemo",
      swiftSettings: concurrencySettings
    ),
    .executableTarget(
      name: "FoveaNetworkLab",
      dependencies: ["FoveaCore", "FoveaHTTP", "FoveaSystem", "ImageCraftCore"],
      path: "Tools/FoveaNetworkLab",
      swiftSettings: concurrencySettings
    ),
    .executableTarget(
      name: "FoveaStoreProbe",
      dependencies: ["AkashicDisk", "FoveaPersistence"],
      path: "Tools/FoveaStoreProbe",
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
      name: "FoveaTests",
      dependencies: [
        "ImageCraftCore", "ImageCraftImageIO",
        "AkashicCore", "AkashicMemory", "AkashicDisk",
        "FoveaHTTP", "FoveaCore", "FoveaPersistence", "FoveaSystem", "FoveaUIKit", "FoveaAppKit",
        "FoveaSwiftUI",
        "FoveaTesting",
      ],
      resources: [.copy("Conformance")],
      swiftSettings: concurrencySettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
