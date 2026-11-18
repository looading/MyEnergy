import SwiftUI
import MyEnergyCore
import MyEnergyPlatform

/// 仅按钮动作请求健康读取；页面随当前时间重新判断样本时效。
struct WatchHealthView: View {
    @Environment(\.energyTheme) private var theme
    @ObservedObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let now = Date()
            List {
                Section {
                    Text("与你的主观精力和心情分开展示，只作个人历史参考。")
                        .font(.caption).foregroundStyle(theme.secondary)
                    connectionContent
                }.listRowBackground(theme.surface)

                if !model.isDemo {
                    if let error = model.healthError {
                        Section("本次操作未完成") {
                            InlineError(message: error)
                            if model.healthReport != nil {
                                Text("下方保留上次成功读取的结果，请留意采样与读取时间。")
                                    .font(.caption).foregroundStyle(theme.secondary)
                            }
                        }.listRowBackground(theme.surface)
                    }
                    if let report = model.healthReport {
                        reportSections(report, now: now)
                    } else if model.healthConnected && !model.isRefreshingHealth {
                        Section {
                            noSamples
                        }.listRowBackground(theme.surface)
                    }
                    if let summary = model.latestSharedHealthSummary {
                        Section("账号中的设备摘要") {
                            WatchSharedHealthContent(summary: summary,
                                isOwn: model.isOwnSharedHealthSummary(summary), now: now)
                        }.listRowBackground(theme.surface)
                    }
                    Section("可选的摘要共享") {
                        WatchHealthSharingControls(model: model)
                    }.listRowBackground(theme.surface)
                    if model.healthConnected || model.isRefreshingHealth {
                        Section {
                            Button(role: .destructive) { model.disconnectHealth() } label: {
                                Text("停止读取并清除临时展示")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            Text("停止后不再更新摘要。Apple 健康原始样本保留；此前已共享的摘要可在上方单独移除。系统授权可在健康 App 中调整。")
                                .font(.caption).foregroundStyle(theme.secondary)
                        }.listRowBackground(theme.surface)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .foregroundStyle(theme.ink)
        }
        .navigationTitle("身体参考")
        .tint(theme.accent)
    }

    @ViewBuilder private var connectionContent: some View {
        if model.isDemo {
            Label("示例空间不读取或共享健康数据", systemImage: "sparkles")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("可在设备与设置中退出示例，再按需连接。")
                .font(.caption).foregroundStyle(theme.secondary)
        } else if !model.healthIsAvailable {
            Label("此设备暂不支持读取 Apple 健康", systemImage: "info.circle")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("同步收到的设备摘要会单独注明来源。")
                .font(.caption).foregroundStyle(theme.secondary)
        } else if model.isRefreshingHealth {
            ProgressView(model.healthConnected ? "正在读取可用数据…" : "正在请求读取权限…")
                .font(.callout).frame(minHeight: 44)
            Text("请在系统界面完成选择。请求结束并不表示每一项读取都已获准。")
                .font(.caption).foregroundStyle(theme.secondary)
        } else if !model.healthConnected {
            Text("由你决定是否读取 HRV SDNN、静息心率和睡眠。")
                .font(.caption).foregroundStyle(theme.secondary)
            Button { Task { await model.connectHealth() } } label: {
                Label(model.healthError == nil ? "连接 Apple 健康" : "重试连接", systemImage: "heart")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        } else {
            Text("本次进程内已连接。这里只读取已有样本，不会主动启动测量。")
                .font(.caption).foregroundStyle(theme.secondary)
            Button { Task { await model.refreshHealth() } } label: {
                Label(model.healthError == nil ? "重新读取" : "重试读取", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func reportSections(_ report: HealthReport, now: Date) -> some View {
        if !model.healthReportHasData {
            Section("暂无可读样本") { noSamples }.listRowBackground(theme.surface)
        }
        Section("心率变异性 · SDNN") {
            WatchRecoveryContent(recovery: report.recovery, now: now)
            Text("对照使用过去 30 天内、最近 24 小时之前的有效日中位数，至少需要 7 天。不据此判断疾病、压力或情绪。")
                .font(.caption).foregroundStyle(theme.secondary)
        }.listRowBackground(theme.surface)
        Section("静息心率") {
            WatchHealthMetric(title: "最近可读值", value: report.restingHeartRate, unit: "次/分")
            Text("只显示本次读取中最近 24 小时内的可用值。")
                .font(.caption).foregroundStyle(theme.secondary)
        }.listRowBackground(theme.surface)
        Section("本机来源与读取") {
            Text("通过本机 Apple 健康读取").font(.callout)
            Text(report.sourceDescription).font(.caption).foregroundStyle(theme.secondary)
            WatchDateValue(title: "上次成功读取", date: report.updatedAt)
            Text("读取时间不等于样本采样时间。睡眠时段与来源可在睡眠详情查看。")
                .font(.caption).foregroundStyle(theme.secondary)
            NavigationLink("查看睡眠详情") { WatchSleepView(model: model) }.frame(minHeight: 44)
        }.listRowBackground(theme.surface)
    }

    private var noSamples: some View {
        Text("Apple 健康可能尚无记录，或当前没有开放可读取的项目。空结果不能说明你拒绝了授权；你仍可记录自己的感受。")
            .font(.caption).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct WatchRecoveryContent: View {
    @Environment(\.energyTheme) private var theme
    let recovery: RecoverySummary
    let now: Date

    var body: some View {
        let status = HealthReferencePresentation.recoveryStatus(recovery, now: now)
        VStack(alignment: .leading, spacing: 12) {
            WatchHealthMetric(title: "最近 HRV SDNN", value: status == .unavailable ? nil : recovery.latestMS, unit: "ms")
            Text(HealthReferencePresentation.recoveryText(recovery, now: now))
                .font(.callout).foregroundStyle(theme.secondary)
            if status != .unavailable, let sampledAt = recovery.sampledAt {
                WatchDateValue(title: "HRV 采样时间", date: sampledAt)
            }
            if status == .ready {
                WatchHealthMetric(title: "个人历史基线", value: recovery.baselineMS, unit: "ms")
                if let change = recovery.changePercent {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("相对个人基线").font(.caption).foregroundStyle(theme.secondary)
                        Text("\(change >= 0 ? "+" : "")\(change.formatted(.number.precision(.fractionLength(1))))%")
                            .font(.title3).monospacedDigit()
                    }.accessibilityElement(children: .combine)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

private struct WatchHealthMetric: View {
    @Environment(\.energyTheme) private var theme
    let title: String
    let value: Double?
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(theme.secondary)
            Text(value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) \(unit)" } ?? "暂无数据")
                .font(.title3.weight(.medium)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}

private struct WatchDateValue: View {
    @Environment(\.energyTheme) private var theme
    let title: String
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(theme.secondary)
            Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
        }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
    }
}

private struct WatchSharedHealthContent: View {
    @Environment(\.energyTheme) private var theme
    let summary: SharedHealthSummary
    let isOwn: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(isOwn ? "此手表曾共享的摘要" : "其他设备共享的摘要", systemImage: "lock.shield")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("来自账号同步，不能据此认为手表刚完成测量，也不代表实时状态。")
                .font(.caption).foregroundStyle(theme.secondary)
            WatchRecoveryContent(recovery: summary.recovery, now: now)
            WatchHealthMetric(title: "摘要中的静息心率", value: summary.restingHeartRate, unit: "次/分")
            WatchDateValue(title: "来源设备更新摘要", date: summary.updatedAt)
            Text("来源：\(summary.sourceDescription)")
                .font(.caption).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            if summary.sleepNight != nil {
                Text("睡眠详情按日期和来源选择主要观测，未必显示这份摘要中的睡眠。")
                    .font(.caption).foregroundStyle(theme.secondary)
            } else if let hours = summary.sleepHours {
                Text("旧摘要睡眠参考：\(hours.formatted(.number.precision(.fractionLength(1)))) 小时。缺少起止时间，不纳入逐日列表。")
                    .font(.caption).foregroundStyle(theme.secondary)
            }
        }
    }
}

private struct WatchHealthSharingControls: View {
    @Environment(\.energyTheme) private var theme
    @ObservedObject var model: AppModel
    @State private var confirmsSharing = false
    @State private var confirmsRemoval = false
    @State private var sharingStorageURL: URL?
    @State private var removalStorageURL: URL?

    private var canEnable: Bool {
        model.canEdit && !model.isDemo && model.hasHealthSharingAccountContext
            && model.healthIsAvailable && model.healthConnected && model.healthReportHasData
            && !model.isRefreshingHealth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("默认关闭。只有你同意，最新摘要才会经配对 iPhone 进入同账号服务，提供给同账号设备。")
                .font(.caption).foregroundStyle(theme.secondary)
            if !model.hasHealthSharingAccountContext {
                Text("当前为匿名配对空间，不能开启摘要共享。请先在配对 iPhone 进入账号，并等待账号空间传到手表。")
                    .font(.caption).foregroundStyle(theme.secondary)
            } else if model.healthSharingEnabled {
                Label("已开启最新摘要更新", systemImage: "checkmark.circle")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("本机重新读取成功时更新摘要。传输进度在设备与设置中查看。")
                    .font(.caption).foregroundStyle(theme.secondary)
            } else {
                Button {
                    sharingStorageURL = model.storageURL
                    confirmsSharing = true
                } label: {
                    Text("开启最新摘要共享").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.disabled(!canEnable)
                if !model.healthReportHasData || !model.healthConnected {
                    Text("需先主动连接，并读取到可用健康数据。")
                        .font(.caption).foregroundStyle(theme.secondary)
                }
            }
            Text("包含最近 HRV SDNN、个人历史对照、静息心率，以及最新睡眠时长、开始结束与来源；不包含原始样本或历史序列。")
                .font(.caption).foregroundStyle(theme.secondary)
            if model.ownSharedHealthSummaryCount > 0 || model.healthSharingEnabled {
                if !model.healthSharingEnabled {
                    Text("当前已停止更新，此手表此前共享的摘要仍保留。")
                        .font(.caption).foregroundStyle(theme.secondary)
                }
                Button(role: .destructive) {
                    removalStorageURL = model.storageURL
                    confirmsRemoval = true
                } label: {
                    Text("停止更新并移除本人摘要")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.disabled(!model.canEdit)
                Text("只移除此手表在当前空间共享的摘要。删除先保存在手表，需恢复配对与账号同步后传到其他设备。")
                    .font(.caption).foregroundStyle(theme.secondary)
            }
        }.buttonStyle(.bordered)
        .confirmationDialog("共享最新健康摘要？", isPresented: $confirmsSharing, titleVisibility: .visible) {
            Button("同意，经配对 iPhone 共享") {
                let expectedURL = sharingStorageURL
                Task {
                    guard let expectedURL, !model.isDemo else { return }
                    await model.setHealthSharing(true, expectedStorageURL: expectedURL)
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将最近 HRV SDNN、历史对照、静息心率、最新睡眠时长与起止时间及来源加入当前账号空间。经配对 iPhone 进入同账号服务，不包含原始健康历史。你可随时停止更新并移除此手表摘要。")
        }
        .confirmationDialog("停止并移除此手表摘要？", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("停止更新并移除", role: .destructive) {
                let expectedURL = removalStorageURL
                Task {
                    guard let expectedURL, !model.isDemo else { return }
                    await model.setHealthSharing(false, expectedStorageURL: expectedURL)
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("停止后不再更新，并删除此手表在当前空间共享的摘要。其他设备的摘要和 Apple 健康原始样本保留；删除需完成同步后才会传到其他设备。")
        }
        .onChange(of: model.storageURL) { _, _ in closeConfirmations() }
        .onChange(of: model.isDemo) { _, _ in closeConfirmations() }
        .onDisappear { closeConfirmations() }
    }

    private func closeConfirmations() {
        confirmsSharing = false
        confirmsRemoval = false
        sharingStorageURL = nil
        removalStorageURL = nil
    }
}
