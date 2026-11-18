import SwiftUI
import MyEnergyUI

@main
struct MyEnergyWatchApp: App {
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
      MyEnergyWatchView(model: model).task { await devices.start() }
        .onChange(of: scenePhase) { _, phase in
          if phase == .active {
            devices.retry()
            Task { await model.refreshHealthIfNeeded() }
          }
        }
    }
  }
}
