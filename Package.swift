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
  dependencies: [
    .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.33.1"),
    .package(
      url: "https://github.com/swiftlang/swift-testing.git",
      revision: "1d1f7e489c9c606ae6c2caa10385372736ef4a39"
    ),
  ],
  targets: [
    .executableTarget(
      name: "Solnari",
      dependencies: [
        .product(name: "PostgresNIO", package: "postgres-nio")
      ],
      path: "Sources/Solnari",
      resources: [
        .process("Resources")
      ]
    ),
    .testTarget(
      name: "SolnariTests",
      dependencies: [
        "Solnari",
        .product(name: "Testing", package: "swift-testing"),
      ]
    ),
  ]
)
