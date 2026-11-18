import SwiftUI
import MyEnergyCore
#if os(watchOS)
import WatchKit
#endif

/// 首页保留日常快记，身体、睡眠与设备设置分别展开。
public struct MyEnergyWatchView: View {
    @ObservedObject private var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        EnergyStateThemeHost(model: model) {
            MyEnergyWatchContent(model: model)
        }
    }
}

private struct MyEnergyWatchContent: View {
    @Environment(\.energyTheme) private var theme
    @ObservedObject private var model: AppModel

    init(model: AppModel) { self.model = model }

    var body: some View {
        NavigationStack {
            List {
                if model.isDemo {
                    Section {
                        Label("示例空间 · 不保存或同步", systemImage: "sparkles").font(.caption)
                    }.listRowBackground(theme.surface)
                }
                Section {
                    NavigationLink {
                        WatchQuickRecordView(model: model)
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("精力快记", systemImage: "plus.circle.fill").font(.headline)
                            Text("此刻感觉怎样？").font(.caption).foregroundStyle(theme.secondary)
                        }.padding(.vertical, 9)
                    }.disabled(!model.canEdit)
                }.listRowBackground(theme.surface)
                Section("最近一次 · 主观自评") {
                    if let latest = model.latestEntry {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text("\(latest.energy)").font(.system(.largeTitle, design: .rounded).weight(.medium))
                                Text("/100").font(.caption).foregroundStyle(theme.secondary)
                            }
                            if let mood = latest.mood {
                                HStack(spacing: 7) { MoodGlyph(mood: mood, size: 24); Text(mood.title).font(.caption) }
                            }
                            Text(latest.occurredAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(theme.secondary)
                        }.padding(.vertical, 4).accessibilityElement(children: .combine)
                    } else {
                        Text("还没有记录，\n从自己的感受开始。")
                            .font(.callout).foregroundStyle(theme.secondary).padding(.vertical, 4)
                    }
                }.listRowBackground(theme.surface)
                Section("独立参考") {
                    NavigationLink {
                        WatchHealthView(model: model)
                    } label: {
                        destinationLabel("身体参考", symbol: "heart.text.square", detail: healthSummary)
                    }
                    NavigationLink {
                        WatchSleepView(model: model)
                    } label: {
                        destinationLabel("睡眠详情", symbol: "moon.stars", detail: sleepSummary)
                    }
                }.listRowBackground(theme.surface)
                Section("今天的小习惯") {
                    if model.activeHabits.isEmpty {
                        Text("在 iPhone 上添加一个小习惯，就能在这里完成或撤销。")
                            .font(.caption).foregroundStyle(theme.secondary)
                    } else {
                        ForEach(model.activeHabits) { habit in
                            Button {
                                let fixedDay = model.todayKey
                                Task { await model.toggleHabit(habit, dayKey: fixedDay) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: model.isComplete(habit) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3).foregroundStyle(theme.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(habit.title).font(.callout)
                                        Text(model.isComplete(habit) ? "已完成 · 点击撤销" : "点击完成").font(.caption2).foregroundStyle(theme.secondary)
                                    }
                                }.frame(minHeight: 44)
                            }.buttonStyle(.plain).disabled(!model.canEdit)
                                .accessibilityLabel("\(habit.title)，\(model.isComplete(habit) ? "已完成，点击撤销" : "未完成，点击完成")")
                        }
                    }
                }.listRowBackground(theme.surface)
                Section {
                    NavigationLink {
                        WatchSettingsView(model: model)
                    } label: {
                        destinationLabel("设备与设置", symbol: "gearshape", detail: model.localStatus)
                    }
                    if let error = model.errorMessage { InlineError(message: error) }
                }.listRowBackground(theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .foregroundStyle(theme.ink)
            .navigationTitle("MyEnergy")
            #if os(watchOS)
            .listStyle(.carousel)
            #endif
        }.tint(theme.accent)
    }

    private var healthSummary: String {
        if model.isDemo { return "示例不读取健康数据" }
        if model.isRefreshingHealth { return "正在请求或读取…" }
        if model.healthError != nil { return "读取未完成，可查看并重试" }
        if model.healthReportHasData { return "查看本机数据与采样时间" }
        if model.latestSharedHealthSummary != nil { return "查看已共享的设备摘要" }
        return model.healthConnected ? "暂无可读样本" : "按需连接 Apple 健康"
    }

    private var sleepSummary: String {
        guard let observation = model.latestSleepObservation else { return "最近观测与近 7 天记录" }
        let hours = observation.durationHours.formatted(.number.precision(.fractionLength(1)))
        return "最近 \(hours) 小时 · \(observation.isEstimated ? "手动估算" : "查看来源")"
    }

    private func destinationLabel(_ title: String, symbol: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.headline)
            Text(detail).font(.caption).foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.vertical, 4)
    }
}

private struct WatchQuickRecordView: View {
    @Environment(\.energyTheme) private var theme
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var energy = 50.0
    @State private var mood: Mood?
    @State private var saveError: String?
    @State private var didSave = false
    @AppStorage("myenergy.hapticsEnabled") private var hapticsEnabled = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if model.isDemo {
                    Text("示例 · 不保存或同步").font(.caption2).foregroundStyle(theme.accent)
                }
                if didSave {
                    Image(systemName: "checkmark.circle").font(.system(size: 44, weight: .light)).foregroundStyle(theme.accent)
                    Text(model.isDemo ? "已记录到示例空间" : "手表本机已保存").font(.headline).multilineTextAlignment(.center)
                    Text(model.isDemo ? "退出示例后，真实记录保持原样。" : "后续传输由设备连接处理，无需重复填写。")
                        .font(.caption).foregroundStyle(theme.secondary).multilineTextAlignment(.center)
                    Button { dismiss() } label: { Text("完成").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent)
                } else {
                    Text("主观自评").font(.caption).foregroundStyle(theme.secondary)
                    crownControl.disabled(model.isSaving)
                    HStack(spacing: 18) {
                        Button { energy = max(0, energy - 5) } label: { Image(systemName: "minus").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("精力减少 5")
                        Button { energy = min(100, energy + 5) } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("精力增加 5")
                    }.buttonStyle(.bordered).disabled(model.isSaving)
                    Picker("心情 · 可选", selection: $mood) {
                        Text("暂不填写").tag(Mood?.none)
                        ForEach(Mood.allCases, id: \.self) { choice in Text(choice.title).tag(Optional(choice)) }
                    }.accessibilityLabel("心情，可选，与精力独立").disabled(model.isSaving)
                    if let saveError { InlineError(message: saveError) }
                    Button {
                        Task {
                            saveError = nil
                            if await model.saveEntry(energy: Int(energy), mood: mood, note: "", occurredAt: Date()) {
                                didSave = true
                                #if os(watchOS)
                                if hapticsEnabled { WKInterfaceDevice.current().play(.success) }
                                #endif
                            } else { saveError = model.errorMessage ?? "尚未保存，请稍后重试。" }
                        }
                    } label: {
                        Text(model.isSaving ? "保存中…" : "保存这次感受").frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent).disabled(!model.canEdit)
                }
            }.padding(.horizontal, 8).padding(.vertical, 12)
        }
        .background(theme.canvas)
        .foregroundStyle(theme.ink)
        .navigationTitle(didSave ? "已记录" : "精力快记")
        .stateThemeDraft(energy: energy, mood: mood)
    }

    @ViewBuilder private var crownControl: some View {
        #if os(watchOS)
        EnergyRing(value: Int(energy), size: 114)
            .focusable()
            .digitalCrownRotation($energy, from: 0, through: 100, by: 1, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: hapticsEnabled)
            .accessibilityHint("转动数码表冠逐点调整，或使用下方加减按钮")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: energy = min(100, energy + 1)
                case .decrement: energy = max(0, energy - 1)
                @unknown default: break
                }
            }
        #else
        VStack {
            EnergyRing(value: Int(energy), size: 114)
            Slider(value: $energy, in: 0...100, step: 1).accessibilityLabel("主观精力")
        }
        #endif
    }
}
