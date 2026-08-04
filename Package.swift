// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "fairness-bot",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
  ],
  targets: [
    .executableTarget(
      name: "fairness-bot",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ],
      path: "Sources/FairnessBot",
    ),
    .testTarget(
      name: "FairnessBotTests",
      dependencies: ["fairness-bot"],
      path: "Tests/FairnessBotTests",
    ),
  ],
)
