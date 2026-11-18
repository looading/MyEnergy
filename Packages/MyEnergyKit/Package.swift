// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MyEnergyKit",
  platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
  products: [
    .library(name: "MyEnergyCore", targets: ["MyEnergyCore"]),
    .library(name: "MyEnergyPlatform", targets: ["MyEnergyPlatform"]),
    .library(name: "MyEnergyUI", targets: ["MyEnergyUI"])
  ],
  targets: [
    .target(name: "MyEnergyCore"),
    .target(name: "MyEnergyPlatform", dependencies: ["MyEnergyCore"]),
    .target(name: "MyEnergyUI", dependencies: ["MyEnergyCore", "MyEnergyPlatform"]),
    .testTarget(name: "MyEnergyCoreTests", dependencies: ["MyEnergyCore", "MyEnergyPlatform", "MyEnergyUI"])
  ],
  swiftLanguageModes: [.v6]
)
