import Foundation
import MyEnergyCore
import MyEnergyPlatform
#if os(iOS)
import UIKit
#endif

public enum NativeLocalAI {
  @MainActor private static var installed = false

  /// 由 iPhone／Mac 入口注入；Kit 与 Watch 不反向依赖模型 package。
  @MainActor
  public static func install() {
    guard !installed else { return }
    let role: LocalAIDeviceRole
    #if os(macOS)
    role = .mac
    #elseif os(iOS)
    role = UIDevice.current.userInterfaceIdiom == .phone ? .iPhone : .iPad
    #else
    role = .watch
    #endif
    register(role: role, deviceID: UUID().uuidString, registry: .shared)
    installed = true
  }

  @MainActor
  static func register(role: LocalAIDeviceRole, deviceID: String, registry: LocalAIRegistry) {
    guard role == .iPhone || role == .mac else {
      registry.register(runners: [], modelAssets: nil)
      return
    }
    let assets = QwenModelAssetStore()
    let gate = LocalAIExecutionGate()
    let runners: [any LocalAIRunner] = [
      AppleSystemReflectionRunner(role: role, deviceID: deviceID),
      MLXReflectionRunner(role: role, deviceID: deviceID, assets: assets)
    ]
    registry.register(runners: runners.map { LeasedLocalAIRunner(base: $0, gate: gate) }, modelAssets: assets)
  }
}
