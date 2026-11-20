#if !os(watchOS)
import SwiftUI
import UniformTypeIdentifiers
import MyEnergyCore

struct EnergySettingsView: View {
    @Environment(\.energyTheme) private var theme
    @ObservedObject var model: AppModel
    @State private var showsHealth = false
    @State private var showsLocalAI = false
    @State private var showsExport = false
    @State private var exportDocument: EnergyExportDocument?
    @State private var exportResult: String?
    @State private var showsClear = false
    @AppStorage("myenergy.hapticsEnabled") private var hapticsEnabled = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionHeading(title: "留给自己的空间", subtitle: "数据由你掌握，连接由你决定。")
                EnergyCard {
                    HStack(spacing: 18) {
                        Image(systemName: "leaf").font(.system(size: 32, weight: .light))
                            .foregroundStyle(theme.accent).frame(width: 74, height: 74)
                            .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 25))
                        VStack(alignment: .leading, spacing: 8) {
                            Text("MyEnergy").font(.title2.weight(.semibold)).foregroundStyle(theme.ink)
                            Text(model.localStatus).font(.callout).foregroundStyle(theme.secondary)
                            Text("\(model.snapshot.entries.count) 条主观记录 · \(model.visibleSleepRecords.count) 条睡眠补记 · \(model.snapshot.habits.count) 个习惯")
                                .font(.caption).foregroundStyle(theme.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                EnergyCard {
                    AccountSettingsView(model: model).disabled(model.isDemo)
                }
                EnergyCard {
                    StateThemeGuideView()
                }
                EnergyCard {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeading(title: "本地 AI 复盘", subtitle: "模型与设备授权由你决定")
                        Text("查看当天有限事实、系统模型和可选离线模型，主动生成复盘。跨设备处理默认关闭，不使用云推理。")
                            .font(.callout).foregroundStyle(theme.secondary)
                        Button { showsLocalAI = true } label: {
                            Label("打开每日复盘", systemImage: "sparkles")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.buttonStyle(.bordered).disabled(!model.isLoaded || model.hasLoadFailure)
                    }.fixedSize(horizontal: false, vertical: true)
                }
                EnergyCard {
                    VStack(alignment: .leading, spacing: 18) {
                        SectionHeading(title: "健康连接", subtitle: "可选，主观记录不依赖健康数据")
                        Text(healthStatus).font(.callout).foregroundStyle(theme.secondary)
                        Button { showsHealth = true } label: {
                            Label("查看与管理身体参考", systemImage: "heart.text.square")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.buttonStyle(.bordered).disabled(model.isDemo)
                        if model.healthConnected {
                            Button("停止读取并清除临时展示", role: .destructive) { model.disconnectHealth() }.disabled(model.isDemo)
                        }
                        Text("Apple 健康原始数据留在系统健康数据库。只有你明确同意的最新摘要会进入账号空间；未选择共享的读取结果仅临时显示。")
                            .font(.footnote).foregroundStyle(theme.secondary)
                        Divider()
                        HealthSharingControls(model: model)
                    }
                }
                EnergyCard {
                    VStack(alignment: .leading, spacing: 18) {
                        SectionHeading(title: "体验示例", subtitle: "看看记录积累后的样子")
                        Text("示例使用独立的内存空间。你的真实记录保持原样，退出后即回到自己的数据；示例期间不会读取健康或发起同步。")
                            .font(.callout).foregroundStyle(theme.secondary)
                        Button(model.isDemo ? "退出示例，回到我的记录" : "进入独立示例空间") {
                            if model.isDemo { model.exitDemo() } else { model.startDemo() }
                        }.buttonStyle(.bordered).disabled(!model.canEdit)
                    }
                }
                EnergyCard {
                    VStack(alignment: .leading, spacing: 18) {
                        SectionHeading(title: "数据管理", subtitle: "导出和删除前，都由你确认")
                        Text("导出包含精力、心情、备注、手动睡眠时段、习惯、完成记录、删除标记，以及账号中已明确共享的最新健康摘要（含睡眠时段）；不含 Apple 健康原始样本或历史序列。JSON 文件本身未加密，含个人信息，请自行选择保存位置并妥善保管。")
                            .font(.callout).foregroundStyle(theme.secondary)
                        Button { prepareExport() } label: {
                            Label(model.isDemo ? "导出示例记录" : "导出我的记录", systemImage: "square.and.arrow.up")
                        }.buttonStyle(.bordered).disabled(!model.isLoaded || model.hasLoadFailure)
                        if let exportResult { Text(exportResult).font(.footnote).foregroundStyle(theme.secondary).textSelection(.enabled) }
                        Divider()
                        Button(role: .destructive) { showsClear = true } label: {
                            Label(model.isDemo ? "清除示例空间中的记录" : "删除 MyEnergy 全部记录", systemImage: "trash")
                        }.disabled(!model.canEdit)
                        Text("清除范围包括手动睡眠补记和备注。清除后会保留删除标记，供设备恢复同步后处理。此操作不会删除 Apple 健康原始数据、系统备份或已导出文件。")
                            .font(.footnote).foregroundStyle(theme.secondary)
                    }
                }
                EnergyCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(title: "显示与辅助功能")
                        Text("跟随系统深色模式和文字大小。图表下方提供同样内容的逐日列表，所有状态同时用文字说明。")
                            .font(.callout).foregroundStyle(theme.secondary)
                        Toggle("触觉反馈", isOn: $hapticsEnabled)
                        Text("本机设置。手表的数码表冠反馈也可在手表状态页关闭。")
                            .font(.footnote).foregroundStyle(theme.secondary)
                    }
                }
                EnergyCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(title: "关于 MyEnergy")
                        Text("记录自己的精力与心情，用小习惯照顾每天的节奏。精力来自主观自评，身体数据单独提供参考。")
                            .font(.callout).foregroundStyle(theme.secondary)
                        Text("首版 · 原生四端应用").font(.caption).foregroundStyle(theme.secondary)
                    }
                }
                if let error = model.errorMessage { InlineError(message: error) }
            }.padding(24).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.background(theme.canvas)
            .sheet(isPresented: $showsHealth) { HealthDetailsView(model: model) }
            .sheet(isPresented: $showsLocalAI) { LocalAIView(model: model) }
            .sheet(isPresented: $showsClear) { ClearDataConfirmationView(model: model) }
            .fileExporter(isPresented: $showsExport, document: exportDocument, contentType: .json,
                defaultFilename: "MyEnergy-\(model.isDemo ? "示例-" : "")\(DateRules.dayKey(for: Date()))") { result in
                    switch result {
                    case .success: exportResult = "文件已交给系统保存。请妥善保管导出的个人记录。"
                    case .failure(let error): exportResult = "导出未完成：\(error.localizedDescription)"
                    }
                }
    }

    private var healthStatus: String {
        if model.isDemo { return "示例空间不连接 Apple 健康。" }
        if !model.healthIsAvailable {
            return model.latestSharedHealthSummary == nil
                ? "当前设备不支持本机读取 Apple 健康，暂无共享摘要。"
                : "当前设备不支持本机读取 Apple 健康，可以查看同账号明确共享的设备摘要。"
        }
        return model.healthConnected ? "已开启按需读取；可读数据取决于系统授权和现有样本。" : "尚未连接，你随时可以继续只用主观记录。"
    }

    private func prepareExport() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            exportDocument = EnergyExportDocument(data: try encoder.encode(model.snapshot.validated()))
            showsExport = true
        } catch { exportResult = "导出未完成：\(error.localizedDescription)" }
    }
}

private struct ClearDataConfirmationView: View {
    @Environment(\.energyTheme) private var theme
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var clearError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(model.isDemo ? "清除当前示例空间" : "删除全部 MyEnergy 记录", systemImage: "trash")
                        .font(.headline).foregroundStyle(.red)
                    Text("将删除当前空间的 \(model.snapshot.entries.count) 条主观记录、\(model.visibleSleepRecords.count) 条手动睡眠补记、\(model.snapshot.habits.count) 个习惯、全部习惯完成记录，以及 \(model.snapshot.sharedHealthSummaries.count) 份已共享健康摘要。")
                    Text(model.isDemo ? "这只会影响当前示例，你的真实记录保持原样。" : "删除标记会留在本机，开启同步后再传播到其他设备。离线设备和服务器尚未确认前，不能视为所有设备已清除。")
                        .foregroundStyle(theme.secondary)
                    Text("Apple 健康原始数据、已导出文件和系统备份不在此次清除范围。账号删除请在“设备与同步”中单独处理。")
                        .font(.callout).foregroundStyle(theme.secondary)
                }
                Section("输入“删除”以确认") { TextField("删除", text: $confirmation).accessibilityLabel("输入删除以确认") }
                if let clearError { Section { InlineError(message: clearError) } }
                Section {
                    Button("确认删除当前空间的全部记录", role: .destructive) {
                        Task {
                            if await model.clearAllData() { dismiss() }
                            else { clearError = model.errorMessage }
                        }
                    }.disabled(confirmation != "删除" || !model.canEdit)
                }
            }.formStyle(.grouped).navigationTitle("确认数据范围")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }.tint(theme.accent)
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 470, idealHeight: 580)
        #endif
    }
}

private struct EnergyExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
#endif
