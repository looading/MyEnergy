import SwiftUI
import MyEnergyUI

@main
struct MyEnergyApp: App {
  @StateObject private var model: AppModel
  @StateObject private var devices: AppDeviceCoordinator
  @Environment(\.scenePhase) private var scenePhase
  init() {
    let model = AppModel()
    _model = StateObject(wrappedValue: model)
    _devices = StateObject(wrappedValue: AppDeviceCoordinator(model: model))
  }
  var body: some Scene {
    WindowGroup {
      MyEnergyRootView(model: model)
        .task { await devices.start() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { devices.retry() } }
        #if os(macOS)
        .frame(minWidth: 880, minHeight: 640)
        #endif
    }
    #if os(macOS)
    .defaultSize(width: 1160, height: 790)
    #endif
  }
}
