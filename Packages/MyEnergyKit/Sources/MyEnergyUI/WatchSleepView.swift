import SwiftUI
import MyEnergyCore

/// 缺失日保留空白；每天只展示模型选定的一份主要观测。
struct WatchSleepView: View {
    @Environment(\.energyTheme) private var theme
    @ObservedObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let now = Date()
            let observations = model.sleepObservations(days: 7, now: now)
            let latest = model.sleepObservations(days: 30, now: now).last
            let byDay = Dictionary(observations.map { ($0.dayKey, $0) }, uniquingKeysWith: { first, _ in first })
            List {
                if model.isDemo {
                    Section {
                        Label("示例 · 不读取健康数据", systemImage: "sparkles").font(.caption)
                    }.listRowBackground(theme.surface)
                }
                Section("最近主要睡眠") {
                    if let observation = latest {
                        WatchSleepObservationContent(observation: observation)
                        Text(observation.isEstimated
                            ? "按整个自述时段估算，可能包含清醒时间。"
                            : "有效睡眠样本去重后计算时长。起止是观测边界，无法确定真正入睡或起床的时刻。")
                            .font(.caption).foregroundStyle(theme.secondary)
                    } else {
                        Text("近 30 天暂无带时间信息的睡眠观测。可在 iPhone 补记，或主动连接 Apple 健康。")
                            .font(.caption).foregroundStyle(theme.secondary)
                    }
                }.listRowBackground(theme.surface)
                Section("近 7 天 · 每日主要观测") {
                    ForEach(DateRules.recentDays(count: 7, endingAt: now).reversed(), id: \.self) { day in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(day.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated)))
                                .font(.headline)
                            if let observation = byDay[DateRules.dayKey(for: day)] {
                                WatchSleepObservationContent(observation: observation)
                            } else {
                                Text("—").font(.title3).accessibilityLabel("暂无观测")
                                Text("暂无观测，保留空白").font(.caption).foregroundStyle(theme.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                }.listRowBackground(theme.surface)
                Section("时段与来源") {
                    Text("日期按本机时区 \(TimeZone.current.identifier) 的结束日归属；各条时段使用记录的来源时区。")
                        .font(.caption).foregroundStyle(theme.secondary)
                    Text("同一天优先使用本机 Apple 健康，其次是已明确共享的设备摘要，再次是手动估算。每天选择一份主要观测，不相加，也不等于全天总睡眠。")
                        .font(.caption).foregroundStyle(theme.secondary)
                    Text("睡眠与主观感受分开展示，不计算睡眠质量或恢复分数。手动补记与编辑请在 iPhone 完成。")
                        .font(.caption).foregroundStyle(theme.secondary)
                    NavigationLink("身体参考与健康连接") { WatchHealthView(model: model) }.frame(minHeight: 44)
                }.listRowBackground(theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .foregroundStyle(theme.ink)
        }
        .navigationTitle("睡眠详情")
        .tint(theme.accent)
    }
}

private struct WatchSleepObservationContent: View {
    @Environment(\.energyTheme) private var theme
    let observation: SleepObservation

    private var source: String {
        observation.sourceTitle.hasPrefix("Apple 健康") ? "本机 \(observation.sourceTitle)" : observation.sourceTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(observation.durationHours.formatted(.number.precision(.fractionLength(1)))) 小时")
                .font(.title3.weight(.medium)).monospacedDigit()
            Text(observation.isEstimated ? "手动自述时段估算" : "主要睡眠观测")
                .font(.caption).foregroundStyle(theme.secondary)
            Text("来源：\(source)").font(.caption).foregroundStyle(theme.secondary)
            Text("开始 \(sleepDateText(observation.bedtime, timeZoneIdentifier: observation.timeZoneIdentifier))")
                .font(.caption)
            Text("结束 \(sleepDateText(observation.wakeTime, timeZoneIdentifier: observation.timeZoneIdentifier))")
                .font(.caption)
            Text("时区 \(observation.timeZoneIdentifier)").font(.caption).foregroundStyle(theme.secondary)
        }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
    }
}
