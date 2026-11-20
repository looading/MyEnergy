// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MyEnergyLocalAI",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "MyEnergyLocalAI", targets: ["MyEnergyLocalAI"]),
    .executable(name: "MyEnergyAIProbe", targets: ["MyEnergyAIProbe"])
  ],
  dependencies: [
    .package(path: "../MyEnergyKit"),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.29.3"),
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.29.1"),
    .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.1.6")
  ],
  targets: [
    .target(name: "MyEnergyLocalAI", dependencies: [
      .product(name: "MyEnergyCore", package: "MyEnergyKit"),
      .product(name: "MyEnergyPlatform", package: "MyEnergyKit"),
      .product(name: "MLX", package: "mlx-swift"),
      .product(name: "MLXLLM", package: "mlx-swift-lm"),
      .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
      .product(name: "Tokenizers", package: "swift-transformers")
    ]),
    .executableTarget(name: "MyEnergyAIProbe", dependencies: [
      "MyEnergyLocalAI", .product(name: "MyEnergyCore", package: "MyEnergyKit")
    ]),
    .testTarget(name: "MyEnergyLocalAITests", dependencies: [
      "MyEnergyLocalAI",
      .product(name: "MyEnergyCore", package: "MyEnergyKit"),
      .product(name: "MyEnergyPlatform", package: "MyEnergyKit")
    ])
  ],
  swiftLanguageModes: [.v6]
)
