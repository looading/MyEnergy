#if !os(watchOS)
import SwiftUI
import MyEnergyCore
import MyEnergyPlatform

struct HealthReferenceCard: View {
    @Environment(\.energyTheme) private var theme
    @ObservedObject var model: AppModel
    @State private var showsDetails = false

    var body: some View {
        EnergyCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    SectionHeading(title: "身体数据参考", subtitle: "与你的主观感受分开展示")
                    Spacer()
                    Image(systemName: "heart.text.square").font(.title2).foregroundStyle(theme.accent)
                }
                if model.isDemo {
                    Text("示例空间不读取健康数据。退出示例后，可按需连接 Apple 健康。")
                        .font(.callout).foregroundStyle(theme.secondary)
                } else if let report = model.healthReport, model.healthReportHasData {
                    recoveryContent(report)
                    Button("查看身体数据详情") { showsDetails = true }.font(.callout)
                } else if let shared = model.latestSharedHealthSummary {
                    SharedHealthSummaryContent(summary: shared, isOwn: model.isOwnSharedHealthSummary(shared))
                    if !model.healthIsAvailable {
                        Text("本机不读取 Apple 健康，以上内容来自账号中已明确共享的摘要。")
                            .font(.caption).foregroundStyle(theme.secondary)
                    }
                    Button("查看摘要来源与共享设置") { showsDetails = true }.font(.callout)
                } else if !model.healthIsAvailable {
                    Text("这台设备不支持读取 Apple 健康，账号中也暂无可显示的共享摘要。你仍然可以随时记录精力、心情和习惯。")
                        .font(.callout).foregroundStyle(theme.secondary)
                } else if !model.healthConnected {
                    Text("按需查看心率变异性、静息心率和睡眠。由你决定是否连接。")
                        .font(.callout).foregroundStyle(theme.secondary)
                    Button { Task { await model.connectHealth() } } label: {
                        Label(model.isRefreshingHealth ? "正在读取…" : "连接 Apple 健康", systemImage: "heart")
                    }.buttonStyle(.bordered).disabled(model.isRefreshingHealth)
                } else {
                    Text(model.isRefreshingHealth ? "正在读取可用数据…" : "暂无可显示数据")
                        .font(.callout).foregroundStyle(theme.secondary)
                    Button("重试读取") { Task { await model.refreshHealth() } }.disabled(model.isRefreshingHealth)
                }
                if let error = model.healthError { InlineError(message: error) }
            }
        }.sheet(isPresented: $showsDetails) { HealthDetailsView(model: model) }
    }

    private func recoveryContent(_ report: HealthReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("心率变异性（HRV）").font(.subheadline).foregroundStyle(theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(report.recovery.latestMS.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—")
                    .font(.system(.largeTitle, design: .rounded).weight(.medium)).foregroundStyle(theme.ink)
                Text("ms").font(.callout).foregroundStyle(theme.secondary)
            }
            Text(recoveryDescription(report.recovery)).font(.callout).foregroundStyle(theme.secondary)
            if let sampledAt = report.recovery.sampledAt {
                Text("采样：\(sampledAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(theme.secondary)
            }
            Text("来自 Apple 健康").font(.caption).foregroundStyle(theme.secondary)
        }.accessibilityElement(children: .combine)
    }
}

struct HealthDetailsView: View {
    @Environment(\.energyTheme) private var theme
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("身体指标只提供参考，不会计算或覆盖你的主观精力与心情。")
                        .foregroundStyle(theme.secondary)
                    if !model.healthIsAvailable {
                        Label("当前设备不支持读取 Apple 健康", systemImage: "info.circle")
                    } else if model.isDemo {
                        Label("示例空间不读取健康数据", systemImage: "sparkles")
                    } else if !model.healthConnected {
                        Button("按需连接 Apple 健康") { Task { await model.connectHealth() } }
                            .disabled(model.isRefreshingHealth)
                    }
                }
                if let report = model.healthReport, !model.isDemo {
                    Section("心率变异性（HRV）") {
                        metric("最近可读样本", value: report.recovery.latestMS, unit: "ms")
                        Text(recoveryDescription(report.recovery)).font(.callout).foregroundStyle(theme.secondary)
                        if let date = report.recovery.sampledAt {
                            LabeledContent("采样时间", value: date.formatted(date: .abbreviated, time: .shortened))
                        }
                        if report.recovery.status == .ready {
                            metric("个人历史基线", value: report.recovery.baselineMS, unit: "ms")
                            if let change = report.recovery.changePercent {
                                LabeledContent("相对基线", value: "\(change >= 0 ? "+" : "")\(change.formatted(.number.precision(.fractionLength(1))))%")
                            }
                        }
                        Text("以过去 30 天内、最近 24 小时之前的有效日中位数作对照，至少需要 7 天。这个对照不代表疾病、压力或情绪判断。")
                            .font(.footnote).foregroundStyle(theme.secondary)
                    }
                    Section("其他身体参考") {
                        metric("最近可读静息心率", value: report.restingHeartRate, unit: "次/分")
                        metric("最近睡眠观测", value: report.sleepHours, unit: "小时")
                        if let sleep = SleepNight.latestPrimary(in: report.sleepHistory) {
                            LabeledContent("观测开始", value: sleepDateText(sleep.bedtime, timeZoneIdentifier: sleep.timeZoneIdentifier))
                            LabeledContent("观测结束", value: sleepDateText(sleep.wakeTime, timeZoneIdentifier: sleep.timeZoneIdentifier))
                            Text("\(sleep.sourceDescription) · 时区 \(sleep.timeZoneIdentifier)")
                                .font(.caption).foregroundStyle(theme.secondary)
                        }
                        Text("缺失项目显示为“暂无数据”，不会补成零。睡眠按有效睡眠样本去重，不计卧床或清醒时间。开始和结束为观测边界，不能确定真正入睡或起床时刻，也不代表此后已经醒来。")
                            .font(.footnote).foregroundStyle(theme.secondary)
                    }
                    Section("来源与读取") {
                        Text(report.sourceDescription).font(.callout)
                        LabeledContent("本次读取时间", value: report.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        Text("读取时间与样本采样时间不同。没有可读样本时，无法由此判断你是否拒绝了某项读取。")
                            .font(.footnote).foregroundStyle(theme.secondary)
                    }
                } else if model.healthConnected && !model.isDemo {
                    Section { Text("暂无可显示数据。Apple 健康可能尚无样本，或当前没有可读取的项目。") }
                }
                if let shared = model.latestSharedHealthSummary, !model.isDemo {
                    Section("账号中的设备摘要") {
                        SharedHealthSummaryContent(summary: shared, isOwn: model.isOwnSharedHealthSummary(shared))
                        Text("此摘要由来源设备的用户明确选择共享。本机显示同步收到的摘要，不代表本机进行了健康测量，也不代表实时状态。")
                            .font(.footnote).foregroundStyle(theme.secondary)
                    }
                }
                Section("可选的跨设备健康摘要") {
                    HealthSharingControls(model: model)
                }
                if let error = model.healthError { Section { InlineError(message: error) } }
                if model.healthConnected && !model.isDemo {
                    Section {
                        Button(model.isRefreshingHealth ? "正在读取…" : "重新读取") { Task { await model.refreshHealth() } }
                            .disabled(model.isRefreshingHealth)
                        Button("停止读取并清除临时展示", role: .destructive) { model.disconnectHealth() }
                    } footer: {
                        Text("停止后会清除本机临时展示，并停止新增摘要。Apple 健康原始样本保留。此前明确共享的摘要仍在账号空间，可用上方共享设置单独移除；系统读取授权可在健康 App 中调整。")
                    }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden).background(theme.canvas)
                .navigationTitle("身体数据参考")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(theme.accent)
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 520, idealHeight: 700)
        #endif
    }

    private func metric(_ title: String, value: Double?, unit: String) -> some View {
        LabeledContent(title, value: value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) \(unit)" } ?? "暂无数据")
    }
}

struct HealthSharingControls: View {
    @Environment(\.energyTheme) private var theme
    @ObservedObject var model: AppModel
    @State private var confirmsSharing = false

    private var canEnable: Bool {
        model.hasHealthSharingAccountContext && model.healthIsAvailable && model.healthReportHasData
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("将此设备最新健康摘要加入账号同步", isOn: Binding(
                get: { model.healthSharingEnabled },
                set: { enabled in
                    if enabled { confirmsSharing = true }
                    else { Task { await model.setHealthSharing(false) } }
                }))
                .disabled(!model.canEdit || model.isDemo || (!model.healthSharingEnabled && !canEnable))
            Text("默认关闭。只共享最近 HRV、个人历史对照、静息心率，以及选定的最新睡眠时长、开始与结束时间和来源；不共享原始健康样本或历史序列。摘要加入账号空间后，经加密同步传给同账号设备。")
                .font(.footnote).foregroundStyle(theme.secondary)
            if model.healthSharingEnabled {
                Text("已选择共享。摘要先保存在当前账号空间，设备收到与否请查看“设备与同步”；刷新本机健康数据时会更新这一份摘要。")
                    .font(.footnote).foregroundStyle(theme.secondary)
            } else if model.ownSharedHealthSummaryCount > 0 {
                Text("当前未自动更新摘要。此设备以前共享的摘要仍保留；切换账号、重启或停止读取后，都需要重新明确开启更新。")
                    .font(.footnote).foregroundStyle(theme.secondary)
            } else if !canEnable {
                Text("需先进入账号空间，并在支持的设备上主动读取到健康数据。这里不会自动请求健康权限。")
                    .font(.footnote).foregroundStyle(theme.secondary)
            }
            if model.ownSharedHealthSummaryCount > 0 {
                Button("停止并移除此设备已共享的摘要", role: .destructive) {
                    Task { await model.setHealthSharing(false) }
                }.disabled(!model.canEdit || model.isDemo)
                Text("仅移除此设备在当前账号的摘要，其他设备的摘要保留。删除先保存在本机，其他设备需恢复同步后处理。")
                    .font(.footnote).foregroundStyle(theme.secondary)
            }
            if let error = model.healthError { InlineError(message: error) }
        }
        .confirmationDialog("同意跨设备共享这份健康摘要？", isPresented: $confirmsSharing, titleVisibility: .visible) {
            Button("同意，将最新摘要加入当前账号") { Task { await model.setHealthSharing(true) } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将 HRV、历史对照、静息心率，以及选定的最新睡眠时长、开始与结束时间和来源保存到当前账号空间，并通过加密同步提供给同账号设备。默认不包含原始健康历史。你可随时停止并移除本设备摘要；已导出文件需自行管理。")
        }
    }
}

private struct SharedHealthSummaryContent: View {
    @Environment(\.energyTheme) private var theme
    let summary: SharedHealthSummary
    let isOwn: Bool

    private var isOld: Bool {
        Date().timeIntervalSince(summary.recovery.sampledAt ?? summary.updatedAt) > 24 * 60 * 60
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(isOwn ? "这台设备曾共享的加密摘要" : "来自其他设备的加密摘要", systemImage: "lock.shield")
                .font(.callout.weight(.semibold)).foregroundStyle(theme.ink)
            LabeledContent("心率变异性（HRV）", value: number(summary.recovery.latestMS, unit: "ms"))
            LabeledContent("静息心率", value: number(summary.restingHeartRate, unit: "次/分"))
            if let sleep = summary.sleepNight {
                LabeledContent("最近睡眠观测", value: number(sleep.durationHours, unit: "小时"))
                LabeledContent("观测开始", value: sleepDateText(sleep.bedtime, timeZoneIdentifier: sleep.timeZoneIdentifier))
                LabeledContent("观测结束", value: sleepDateText(sleep.wakeTime, timeZoneIdentifier: sleep.timeZoneIdentifier))
                Text("\(sleep.sourceDescription) · 时区 \(sleep.timeZoneIdentifier)")
                    .font(.caption).foregroundStyle(theme.secondary)
                Text("起止时间为观测边界，不能确定真正入睡或起床的时刻。这里只显示来源设备选定的最新摘要，不包含睡眠历史。")
                    .font(.footnote).foregroundStyle(theme.secondary)
            } else {
                LabeledContent("睡眠时长参考", value: number(summary.sleepHours, unit: "小时"))
                if summary.sleepHours != nil {
                    Text("这份旧摘要没有睡眠时段时间信息，暂不纳入睡眠逐日观测。")
                        .font(.caption).foregroundStyle(theme.secondary)
                }
            }
            Text(isOld ? "这份摘要已有一段时间，请留意以下采样与更新时间。" : recoveryDescription(summary.recovery))
                .font(.footnote).foregroundStyle(theme.secondary)
            if let sampledAt = summary.recovery.sampledAt {
                Text("HRV 采样：\(sampledAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(theme.secondary)
            }
            Text("摘要更新：\(summary.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(theme.secondary)
            Text(summary.sourceDescription).font(.caption).foregroundStyle(theme.secondary)
        }.accessibilityElement(children: .combine)
    }

    private func number(_ value: Double?, unit: String) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) \(unit)" } ?? "暂无数据"
    }
}

private func recoveryDescription(_ recovery: RecoverySummary) -> String {
    switch recovery.status {
    case .unavailable: "暂无可显示的 HRV 数据"
    case .insufficientHistory: "正在积累个人历史，已有 \(recovery.historyDays) 个有效日。"
    case .stale: "最近样本已超过 24 小时，请留意采样时间。"
    case .ready: "已有足够历史，可查看与个人基线的对照。"
    }
}
#endif
