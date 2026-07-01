// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Notchy",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "Notchy", targets: ["Notchy"])
  ],
  targets: [
    .executableTarget(name: "Notchy")
  ]
)
