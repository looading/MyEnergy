import Foundation
#if !os(watchOS)
import SwiftUI
import Charts
import MyEnergyCore

struct SleepView: View {
    @Environment(\.energyTheme) private var theme
    @ObservedObject var model: AppModel
    @State private var dayCount = 7
    @State private var draft = SleepDraft()
    @State private var hasUnfinishedDraft = false
    @State private var showsEditor = false
    @State private var selectedRecord: SleepRecord?
    @State private var showsHealthDetails = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var observations: [SleepObservation] { model.sleepObservations(days: dayCount) }
    private var days: [SleepDay] {
        let byDay = Dictionary(observations.map { ($0.dayKey, $0) }, uniquingKeysWith: { first, _ in first })
        return DateRules.recentDays(count: dayCount).map { date in
            let key = DateRules.dayKey(for: date)
            return SleepDay(date: date, key: key, observation: byDay[key])
        }
    }
    private var points: [SleepChartPoint] {
        var segment = 0
        return days.compactMap { day in
            guard let observation = day.observation else { segment += 1; return nil }
            return SleepChartPoint(date: day.date, observation: observation, segment: segment)
        }
    }
    private var manualRecords: [SleepRecord] {
        model.visibleSleepRecords.sorted {
            if $0.wakeTime != $1.wakeTime { return $0.wakeTime > $1.wakeTime }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 16) {
                    SectionHeading(title: "看看睡眠的节奏", subtitle: "保留时长、时段和来源，慢慢了解自己的规律。")
                    Spacer(minLength: 0)
                    Image(systemName: "moon.stars").font(.system(size: 30, weight: .light)).foregroundStyle(theme.accent)
                        .accessibilityHidden(true)
                }
                latestCard
                Picker("睡眠观测时间范围", selection: $dayCount) {
                    Text("近 7 天").tag(7)
                    Text("近 30 天").tag(30)
                }.pickerStyle(.segmented).frame(maxWidth: 320)
                trendCard
                summary
                dailyList
                manualCard
                connectionCard
                if let error = model.errorMessage, !model.hasLoadFailure { InlineError(message: error) }
                Text("睡眠与主观精力分开展示，不计算睡眠质量、疾病或恢复评分。")
                    .font(.footnote).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(24).frame(maxWidth: 1040).frame(maxWidth: .infinity)
        }.background(theme.canvas)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { beginNewRecord() } label: {
                        Label(hasUnfinishedDraft ? "继续补记" : "补记睡眠", systemImage: "plus")
                    }.disabled(!model.canEdit).keyboardShortcut("n", modifiers: .command)
                }
            }
            .sheet(isPresented: $showsEditor) {
                SleepEditor(model: model, draft: $draft) {
                    hasUnfinishedDraft = false
                    draft = SleepDraft()
                }
            }
            .sheet(item: $selectedRecord) { SleepRecordDetailView(model: model, record: $0) }
            .sheet(isPresented: $showsHealthDetails) { HealthDetailsView(model: model) }
    }

    private func beginNewRecord() {
        if !hasUnfinishedDraft { draft = SleepDraft() }
        hasUnfinishedDraft = true
        showsEditor = true
    }

    private var latestCard: some View {
        EnergyCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeading(title: "最近睡眠观测", subtitle: "每日主要睡眠 · 按当前设备时区的结束日期归属")
                if let observation = model.latestSleepObservation {
                    SleepObservationContent(observation: observation)
                    Text(observation.isEstimated
                        ? "按手动填写的整个时段估算，可能包含清醒时间。"
                        : "实际睡眠时长按有效睡眠样本去重计算。开始和结束为观测边界，不能据此确定真正入睡或起床的时刻。")
                        .font(.footnote).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    EmptyState(symbol: "moon", title: "暂无带时间信息的观测", message: "可以先补记一段睡眠，也可以在支持的设备上按需连接 Apple 健康。")
                    Button { beginNewRecord() } label: { Label("先补记一段睡眠", systemImage: "pencil.and.outline") }
                        .buttonStyle(.bordered).disabled(!model.canEdit)
                }
            }
        }
    }

    private var trendCard: some View {
        EnergyCard {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeading(title: "每日主要睡眠", subtitle: "每天选择一段主要观测，不等于全天总睡眠")
                if points.isEmpty {
                    EmptyState(symbol: "chart.xyaxis.line", title: "这段时间暂无观测", message: "有数据后会显示时长变化。没有观测的日期保持空白。")
                } else { sleepChart }
                Text("缺失日留白，不计为零。同一天优先显示本机 Apple 健康，其次是明确共享的摘要，再次是手动补记；同一来源取较长的一段，互不相加。")
                    .font(.footnote).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Label("实际睡眠", systemImage: "circle.fill")
                    Label("手动时段估算", systemImage: "square.fill")
                }.font(.caption).foregroundStyle(theme.secondary)
                    .accessibilityElement(children: .combine)
            }
        }
    }

    private var sleepChart: some View {
        Chart(points) { point in
            LineMark(x: .value("日期", point.date), y: .value("主要睡眠时长", point.observation.durationHours),
                series: .value("连续观测", point.segment))
                .interpolationMethod(.linear).foregroundStyle(theme.accent).lineStyle(StrokeStyle(lineWidth: 2.5))
            PointMark(x: .value("日期", point.date), y: .value("主要睡眠时长", point.observation.durationHours))
                .symbol(point.observation.isEstimated ? .square : .circle)
                .foregroundStyle(theme.accent).symbolSize(46)
                .accessibilityLabel("\(point.observation.dayKey)，\(point.observation.sourceTitle)")
                .accessibilityValue("\(point.observation.isEstimated ? "时段估算" : "实际睡眠") \(point.observation.durationHours.formatted(.number.precision(.fractionLength(1)))) 小时")
        }
        .chartYScale(domain: 0...max(12, ceil((points.map { $0.observation.durationHours }.max() ?? 0) / 2) * 2))
        .chartXScale(domain: (days.first?.date ?? Date())...(days.last?.date ?? Date()))
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(theme.border)
                AxisValueLabel().foregroundStyle(theme.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: dayCount == 7 ? 1 : 7)) { _ in
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day()).foregroundStyle(theme.secondary)
            }
        }
        .chartLegend(.hidden).frame(height: 230)
        .accessibilityLabel("最近 \(dayCount) 天每日主要睡眠时长，单位小时。缺失日不连接。下方逐日列表提供时段与来源。")
    }

    private var summary: some View {
        let observed = days.compactMap(\.observation)
        let average = observed.isEmpty ? nil : observed.map(\.durationHours).reduce(0, +) / Double(observed.count)
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            summaryTile(value: "\(observed.count)/\(dayCount)", title: "有观测的日子")
            summaryTile(value: average.map { "\($0.formatted(.number.precision(.fractionLength(1)))) 小时" } ?? "—", title: "有观测日的平均时长")
        }
    }

    private func summaryTile(value: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(theme.ink)
            Text(title).font(.caption).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(theme.accentSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .combine)
    }

    private var dailyList: some View {
        EnergyCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "逐日观测", subtitle: "统计日期按当前设备时区，起止时段保留来源时区")
                ForEach(Array(days.reversed())) { day in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(day.date.formatted(.dateTime.month().day().weekday(.abbreviated)))
                                .font(.callout.weight(.medium)).foregroundStyle(theme.ink)
                            Spacer(minLength: 12)
                            Text(day.observation.map { "\($0.durationHours.formatted(.number.precision(.fractionLength(1)))) 小时" } ?? "暂无观测")
                                .font(.callout).monospacedDigit().foregroundStyle(day.observation == nil ? theme.secondary : theme.accent)
                        }
                        if let observation = day.observation {
                            Text(sleepSourceText(observation))
                                .font(.caption).foregroundStyle(theme.secondary)
                            Text("开始 \(sleepDateText(observation.bedtime, timeZoneIdentifier: observation.timeZoneIdentifier)) · 结束 \(sleepDateText(observation.wakeTime, timeZoneIdentifier: observation.timeZoneIdentifier)) · \(observation.timeZoneIdentifier)")
                                .font(.caption).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.vertical, 5).accessibilityElement(children: .combine)
                    if day.id != days.first?.id { Divider() }
                }
                Text("平均值只计算以上有观测的日子，其中可能包含手动时段估算；不同来源的测量方式可能不同。")
                    .font(.footnote).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var manualCard: some View {
        EnergyCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeading(title: "我的手动补记", subtitle: "所有补记均保留，未选为每日主要观测的也能查看")
                Button { beginNewRecord() } label: {
                    Label(hasUnfinishedDraft ? "继续未保存的补记" : "补记一段睡眠", systemImage: "pencil.and.outline")
                }.buttonStyle(.bordered).disabled(!model.canEdit)
                if manualRecords.isEmpty {
                    Text("暂无手动补记。你可以填写一段已经结束的睡眠时段。")
                        .font(.callout).foregroundStyle(theme.secondary)
                } else {
                    ForEach(Array(manualRecords.prefix(3))) { record in
                        Button { selectedRecord = record } label: { SleepRecordRow(record: record) }.buttonStyle(.plain)
                        if record.id != manualRecords.prefix(3).last?.id { Divider() }
                    }
                    NavigationLink { SleepRecordsHistoryView(model: model) } label: {
                        Label("查看全部手动补记（\(manualRecords.count)）", systemImage: "clock.arrow.circlepath")
                            .font(.callout).frame(minHeight: 44, alignment: .leading)
                    }
                }
                Text("手动记录按自述时段估算，保存到当前 MyEnergy 空间；进入账号空间后随你的应用记录加密同步。Apple 健康原始睡眠历史不会加入账号同步。")
                    .font(.footnote).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var connectionCard: some View {
        EnergyCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "自动读取 · Apple 健康", subtitle: "由你选择是否连接")
                if model.isDemo {
                    Text("示例睡眠来自虚构的手动补记。示例空间不会读取 Apple 健康，退出示例后可选择连接。")
                        .font(.callout).foregroundStyle(theme.secondary)
                } else if !model.healthIsAvailable {
                    Text("这台设备不支持本机读取 Apple 健康。可以继续手动补记，或查看同账号设备明确共享的最新摘要。")
                        .font(.callout).foregroundStyle(theme.secondary)
                } else if !model.healthConnected {
                    Text("连接后按需读取最近 30 天可用的睡眠样本。权限和样本由 Apple 健康管理，也可以继续只用手动补记。")
                        .font(.callout).foregroundStyle(theme.secondary)
                    Button { Task { await model.connectHealth() } } label: {
                        Label(model.isRefreshingHealth ? "正在读取…" : "连接 Apple 健康", systemImage: "heart")
                    }.buttonStyle(.bordered).disabled(model.isRefreshingHealth)
                } else {
                    Text("已开启按需读取。缺少睡眠观测时，可能是尚无睡眠样本，或当前没有可读的睡眠项目；仍可手动补记。")
                        .font(.callout).foregroundStyle(theme.secondary)
                    Button(model.isRefreshingHealth ? "正在读取…" : "重新读取睡眠观测") { Task { await model.refreshHealth() } }
                        .buttonStyle(.bordered).disabled(model.isRefreshingHealth)
                }
                if !model.isDemo {
                    Button("查看健康来源与共享设置") { showsHealthDetails = true }
                        .font(.callout).frame(minHeight: 44, alignment: .leading)
                    Text("本页不会自动请求读取权限。只有明确开启共享后，选定的最新睡眠摘要及开始、结束时间才进入账号空间；原始健康历史仅留在系统健康数据库。")
                        .font(.footnote).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.healthError { InlineError(message: error) }
            }
        }
    }
}

struct SleepObservationContent: View {
    @Environment(\.energyTheme) private var theme
    let observation: SleepObservation
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 16) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(observation.durationHours.formatted(.number.precision(.fractionLength(1))))
                    .font(.system(compact ? .title : .largeTitle, design: .rounded).weight(.medium)).monospacedDigit()
                Text("小时").font(.callout).foregroundStyle(theme.secondary)
                Spacer(minLength: 0)
            }.foregroundStyle(theme.ink)
            Text(sleepSourceText(observation))
                .font(.caption.weight(.medium)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Label("开始 \(sleepDateText(observation.bedtime, timeZoneIdentifier: observation.timeZoneIdentifier))", systemImage: "moon")
                Label("结束 \(sleepDateText(observation.wakeTime, timeZoneIdentifier: observation.timeZoneIdentifier))", systemImage: "sun.horizon")
            }.font(.caption).foregroundStyle(theme.secondary)
            Text("统计日期 \(observation.dayKey)（当前设备时区）· 起止时区 \(observation.timeZoneIdentifier)")
                .font(.caption2).foregroundStyle(theme.secondary)
        }.accessibilityElement(children: .combine)
    }
}

struct SleepRecordRow: View {
    @Environment(\.energyTheme) private var theme
    let record: SleepRecord
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "moon").font(.title3).foregroundStyle(theme.accent)
                .frame(width: 46, height: 46).background(theme.accentSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 6) {
                Text("\(record.durationHours.formatted(.number.precision(.fractionLength(1)))) 小时 · 时段估算")
                    .font(.callout.weight(.medium)).foregroundStyle(theme.ink)
                Text("\(sleepDateText(record.bedtime, timeZoneIdentifier: record.timeZoneIdentifier)) → \(sleepDateText(record.wakeTime, timeZoneIdentifier: record.timeZoneIdentifier)) · \(record.timeZoneIdentifier)")
                    .font(.caption).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(theme.secondary)
        }.frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).contentShape(Rectangle())
            .accessibilityElement(children: .combine).accessibilityHint("查看手动睡眠记录、编辑或删除")
    }
}

private struct SleepRecordsHistoryView: View {
    @Environment(\.energyTheme) private var theme
    @ObservedObject var model: AppModel
    @State private var selectedRecord: SleepRecord?

    private var records: [SleepRecord] { model.visibleSleepRecords.sorted { $0.wakeTime > $1.wakeTime } }

    var body: some View {
        ScrollView {
            EnergyCard {
                VStack(alignment: .leading, spacing: 18) {
                    SectionHeading(title: "全部手动补记", subtitle: "共 \(records.count) 条，按结束时间从近到远")
                    if records.isEmpty {
                        EmptyState(symbol: "moon", title: "暂无手动补记", message: "返回睡眠页，可以补记一段已经结束的睡眠时段。")
                    } else {
                        ForEach(records) { record in
                            Button { selectedRecord = record } label: { SleepRecordRow(record: record) }.buttonStyle(.plain)
                            if record.id != records.last?.id { Divider() }
                        }
                    }
                }
            }.padding(24).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.background(theme.canvas).navigationTitle("手动睡眠记录")
            .sheet(item: $selectedRecord) { SleepRecordDetailView(model: model, record: $0) }
    }
}

private struct SleepDay: Identifiable {
    let date: Date
    let key: String
    let observation: SleepObservation?
    var id: String { key }
}

private struct SleepChartPoint: Identifiable {
    let date: Date
    let observation: SleepObservation
    let segment: Int
    var id: String { observation.id }
}
#endif

/// 以来源记录的时区展示观测边界，避免跨设备时悄悄改变钟面时间。
func sleepDateText(_ date: Date, timeZoneIdentifier: String) -> String {
    var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
    style.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
    return date.formatted(style)
}

func sleepSourceText(_ observation: SleepObservation) -> String {
    let kind = observation.isEstimated ? "自述时段估算" : "实际睡眠"
    return observation.sourceTitle.contains(kind) ? observation.sourceTitle : "\(observation.sourceTitle) · \(kind)"
}
