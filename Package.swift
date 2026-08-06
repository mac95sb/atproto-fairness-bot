// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "fairness-bot",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "fairness-bot", targets: ["fairness-bot"]),
    .library(name: "FairnessBotCore", targets: ["FairnessBotCore"]),
    .library(name: "FairnessBotCLI", targets: ["FairnessBotCLI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
  ],
  targets: [
    .executableTarget(
      name: "fairness-bot",
      dependencies: ["FairnessBotCLI"]
    ),
    .target(
      name: "FairnessBotCore",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ]
    ),
    .target(
      name: "FairnessBotCLI",
      dependencies: [
        "FairnessBotCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ]
    ),
    .testTarget(
      name: "FairnessBotTests",
      dependencies: ["FairnessBotCore", "FairnessBotCLI"],
      path: "Tests/FairnessBotTests",
    ),
  ],
)
