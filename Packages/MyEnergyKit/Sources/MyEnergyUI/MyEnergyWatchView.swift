import SwiftUI
import MyEnergyCore

/// 手表提供快记、习惯和最近睡眠参考，一次只完成一件事。
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
    @AppStorage("myenergy.hapticsEnabled") private var hapticsEnabled = true

    init(model: AppModel) { self.model = model }

    var body: some View {
        NavigationStack {
            List {
                if model.isDemo {
                    Section {
                        Label("示例空间 · 不保存或同步", systemImage: "sparkles").font(.caption)
                        Button("退出示例") { model.exitDemo() }
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
                Section("最近睡眠 · 独立参考") {
                    if let observation = model.latestSleepObservation {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("\(observation.durationHours.formatted(.number.precision(.fractionLength(1)))) 小时", systemImage: "moon.stars")
                                .font(.title3.weight(.medium)).monospacedDigit()
                            Text(observation.isEstimated ? "自述时段估算" : "实际睡眠观测")
                                .font(.caption).foregroundStyle(theme.secondary)
                            Text(observation.sourceTitle).font(.caption2).foregroundStyle(theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("开始 \(sleepDateText(observation.bedtime, timeZoneIdentifier: observation.timeZoneIdentifier))")
                                .font(.caption2).foregroundStyle(theme.secondary)
                            Text("结束 \(sleepDateText(observation.wakeTime, timeZoneIdentifier: observation.timeZoneIdentifier))")
                                .font(.caption2).foregroundStyle(theme.secondary)
                            Text("时区 \(observation.timeZoneIdentifier)").font(.caption2).foregroundStyle(theme.secondary)
                            Text(observation.isEstimated ? "整个自述时段可能包含清醒时间。" : "起止时间为观测边界，无法确定真正入睡或起床时刻。")
                                .font(.caption2).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(.vertical, 4).accessibilityElement(children: .combine)
                    } else {
                        Text("暂无带时间信息的睡眠观测。可在 iPhone 上补记，或按需连接 Apple 健康。")
                            .font(.caption).foregroundStyle(theme.secondary)
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
                Section("状态") {
                    if let devices = AppDeviceCoordinator.current { WatchTransportSettingsView(coordinator: devices) }
                    Text(model.localStatus).font(.caption)
                    Toggle("触觉反馈", isOn: $hapticsEnabled).font(.caption)
                    Text("记录先保存在手表。传输和设备确认状态请在配对 iPhone 查看。")
                        .font(.caption2).foregroundStyle(theme.secondary)
                    if model.hasLoadFailure {
                        Button("重试读取本机记录") { Task { await model.load() } }.disabled(model.isSaving)
                    }
                    if let error = model.errorMessage { InlineError(message: error) }
                    if !model.isDemo {
                        Button("体验独立示例") { model.startDemo() }.font(.caption).disabled(!model.canEdit)
                    }
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
                    Button("完成") { dismiss() }.buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent)
                } else {
                    Text("主观自评").font(.caption).foregroundStyle(theme.secondary)
                    crownControl
                    HStack(spacing: 18) {
                        Button { energy = max(0, energy - 5) } label: { Image(systemName: "minus").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("精力减少 5")
                        Button { energy = min(100, energy + 5) } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("精力增加 5")
                    }.buttonStyle(.bordered)
                    Picker("心情 · 可选", selection: $mood) {
                        Text("暂不填写").tag(Mood?.none)
                        ForEach(Mood.allCases, id: \.self) { choice in Text(choice.title).tag(Optional(choice)) }
                    }.accessibilityLabel("心情，可选，与精力独立")
                    if let saveError { InlineError(message: saveError) }
                    Button {
                        Task {
                            if await model.saveEntry(energy: Int(energy), mood: mood, note: "", occurredAt: Date()) {
                                didSave = true
                            } else { saveError = model.errorMessage }
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
