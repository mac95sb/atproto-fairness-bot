// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "FairnessBot",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "fairness-bot", targets: ["fairness-bot"]),
    .library(name: "FairnessBot", targets: ["FairnessBot"]),
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
      name: "FairnessBot",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ]
    ),
    .target(
      name: "FairnessBotCLI",
      dependencies: [
        "FairnessBot",
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ]
    ),
    .testTarget(
      name: "FairnessBotTests",
      dependencies: ["FairnessBot", "FairnessBotCLI"],
      path: "Tests/FairnessBotTests",
    ),
  ],
)
