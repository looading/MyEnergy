import SwiftUI

/// 长说明与设备操作单独呈现，避免挤占手表首页。
struct WatchSettingsView: View {
    @Environment(\.energyTheme) private var theme
    @ObservedObject var model: AppModel
    @AppStorage("myenergy.hapticsEnabled") private var hapticsEnabled = true

    var body: some View {
        List {
            Section("本机记录") {
                Text(model.localStatus).font(.callout)
                Text("记录先保存在手表。配对传输和设备确认状态可在 iPhone 查看。")
                    .font(.caption).foregroundStyle(theme.secondary)
                if model.hasLoadFailure {
                    Button { Task { await model.load() } } label: {
                        Text("重试读取本机记录").frame(minHeight: 44)
                    }.disabled(model.isSaving)
                }
                if let error = model.errorMessage { InlineError(message: error) }
            }.listRowBackground(theme.surface)
            if let devices = AppDeviceCoordinator.current {
                Section("配对 iPhone") {
                    WatchTransportSettingsView(coordinator: devices)
                        .fixedSize(horizontal: false, vertical: true)
                        .buttonStyle(.bordered)
                }.listRowBackground(theme.surface)
            }
            Section("操作反馈") {
                Toggle("触觉反馈", isOn: $hapticsEnabled).frame(minHeight: 44)
                Text("用于数码表冠调整和保存成功时的反馈。")
                    .font(.caption).foregroundStyle(theme.secondary)
            }.listRowBackground(theme.surface)
            Section("独立示例") {
                Text("示例只在内存中体验，不保存、不传输，也不读取或共享健康数据。")
                    .font(.caption).foregroundStyle(theme.secondary)
                Button {
                    if model.isDemo { model.exitDemo() }
                    else { model.startDemo() }
                } label: {
                    Text(model.isDemo ? "退出示例" : "体验独立示例").frame(minHeight: 44)
                }.disabled(!model.canEdit)
            }.listRowBackground(theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .foregroundStyle(theme.ink)
        .navigationTitle("设备与设置")
        .tint(theme.accent)
    }
}
