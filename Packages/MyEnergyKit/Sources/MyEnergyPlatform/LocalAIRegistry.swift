import Combine
import Foundation
import MyEnergyCore

/// 原生入口注入模型实现；记录和界面包不直接链接 MLX 或加载权重。
@MainActor
public final class LocalAIRegistry: ObservableObject {
  public static let shared = LocalAIRegistry()
  @Published public private(set) var revision = 0
  public private(set) var runners: [any LocalAIRunner] = []
  public private(set) var modelAssets: (any LocalAIModelAssetsManaging)?

  public init() {}

  public func register(runners: [any LocalAIRunner], modelAssets: (any LocalAIModelAssetsManaging)?) {
    self.runners = runners
    self.modelAssets = modelAssets
    revision += 1
  }
}
