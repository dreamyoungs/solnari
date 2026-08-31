// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "Solnari",
  defaultLocalization: "en",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "Solnari", targets: ["Solnari"])
  ],
  targets: [
    .executableTarget(
      name: "Solnari",
      path: "Sources/Solnari",
      resources: [
        .process("Resources")
      ]
    )
  ]
)
