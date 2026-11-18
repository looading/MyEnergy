#if !os(watchOS)
import SwiftUI
import Charts
import MyEnergyCore

struct TrendsView: View {
    @ObservedObject var model: AppModel
    @State private var dayCount = 7
    @State private var selectedEntry: EnergyEntry?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var days: [DailyTrend] {
        DateRules.recentDays(count: dayCount).map { date in
            let key = DateRules.dayKey(for: date)
            return DailyTrend(date: date, key: key, entries: model.entries(for: key),
                habitCount: model.snapshot.checkIns.filter { $0.dayKey == key && $0.isComplete }.count)
        }
    }

    private var points: [TrendPoint] {
        var segment = 0
        return days.compactMap { day in
            guard let average = day.average else { segment += 1; return nil }
            return TrendPoint(id: day.key, date: day.date, average: average, segment: segment)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionHeading(title: "看见自己的节奏", subtitle: "每一条记录，都保留你当时的感受。")
                Picker("趋势时间范围", selection: $dayCount) {
                    Text("近 7 天").tag(7)
                    Text("近 30 天").tag(30)
                }.pickerStyle(.segmented).frame(maxWidth: 320)
                EnergyCard {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .top) {
                            SectionHeading(title: "主观精力", subtitle: "折线为每日均值 · 范围 0～100")
                            Spacer()
                            Image(systemName: "waveform.path").font(.title2).foregroundStyle(EnergyStyle.forest)
                        }
                        if points.isEmpty {
                            EmptyState(symbol: "chart.xyaxis.line", title: "从第一次记录开始", message: "记录后，这里会慢慢出现你的变化。没有记录的日子会保持空白。")
                        } else {
                            energyChart
                        }
                        Text("留白表示没有记录，不代表精力为零。日期按每条记录保存的当地时区归档。")
                            .font(.footnote).foregroundStyle(EnergyStyle.secondary)
                    }
                }
                summary
                EnergyCard {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeading(title: "逐日回顾", subtitle: "展开日期可查看全部原始记录，未记录日也会显示。")
                        ForEach(Array(days.reversed())) { day in
                            dayRow(day)
                            if day.key != days.first?.key { Divider() }
                        }
                    }
                }
            }.padding(24).frame(maxWidth: 1040).frame(maxWidth: .infinity)
        }.background(EnergyStyle.canvas)
            .sheet(item: $selectedEntry) { EntryDetailView(model: model, entryID: $0.id) }
    }

    private var energyChart: some View {
        Chart(points) { point in
            LineMark(x: .value("日期", point.date), y: .value("每日平均精力", point.average), series: .value("连续片段", point.segment))
                .interpolationMethod(.linear).foregroundStyle(EnergyStyle.forest).lineStyle(StrokeStyle(lineWidth: 2.5))
            PointMark(x: .value("日期", point.date), y: .value("每日平均精力", point.average))
                .foregroundStyle(EnergyStyle.forest).symbolSize(42)
                .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
                .accessibilityValue("每日平均主观精力 \(Int(point.average.rounded()))")
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: (days.first?.date ?? Date())...(days.last?.date ?? Date()))
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { _ in
                AxisGridLine().foregroundStyle(EnergyStyle.line)
                AxisValueLabel().foregroundStyle(EnergyStyle.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: dayCount == 7 ? 1 : 7)) { _ in
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day()).foregroundStyle(EnergyStyle.secondary)
            }
        }
        .chartLegend(.hidden).frame(height: 230)
        .accessibilityLabel("最近 \(dayCount) 天主观精力趋势图。缺失日不连接。下方逐日回顾包含完整数据。")
    }

    private var summary: some View {
        let allEntries = days.flatMap(\.entries)
        let average = allEntries.isEmpty ? nil : Double(allEntries.map(\.energy).reduce(0, +)) / Double(allEntries.count)
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            summaryTile(value: "\(points.count)/\(dayCount)", title: "有记录的日子")
            summaryTile(value: average.map { String(Int($0.rounded())) } ?? "—", title: "每条记录平均精力")
            summaryTile(value: "\(days.map(\.habitCount).reduce(0, +))", title: "习惯完成次数")
        }
    }

    private func summaryTile(value: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(EnergyStyle.ink)
            Text(title).font(.caption).foregroundStyle(EnergyStyle.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(EnergyStyle.sage.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func dayRow(_ day: DailyTrend) -> some View {
        if day.entries.isEmpty {
            HStack(alignment: .top) {
                Text(day.date.formatted(.dateTime.month().day().weekday(.abbreviated))).font(.callout)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("未记录精力").font(.callout).foregroundStyle(EnergyStyle.secondary)
                    if day.habitCount > 0 { Text("习惯完成 \(day.habitCount) 次").font(.caption).foregroundStyle(EnergyStyle.secondary) }
                }
            }.padding(.vertical, 5).foregroundStyle(EnergyStyle.ink).accessibilityElement(children: .combine)
        } else {
            DisclosureGroup {
                VStack(spacing: 12) {
                    ForEach(day.entries) { entry in
                        Button { selectedEntry = entry } label: { EntryRow(entry: entry) }.buttonStyle(.plain)
                    }
                }.padding(.top, 12)
            } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(day.date.formatted(.dateTime.month().day().weekday(.abbreviated))).font(.callout.weight(.medium))
                        Text("\(day.entries.count) 条记录 · 习惯完成 \(day.habitCount) 次").font(.caption).foregroundStyle(EnergyStyle.secondary)
                    }
                    Spacer()
                    Text("均值 \(Int((day.average ?? 0).rounded()))").font(.callout.weight(.medium)).foregroundStyle(EnergyStyle.forest)
                }.foregroundStyle(EnergyStyle.ink).padding(.vertical, 5)
            }
        }
    }
}

private struct DailyTrend: Identifiable {
    let date: Date
    let key: String
    let entries: [EnergyEntry]
    let habitCount: Int
    var id: String { key }
    var average: Double? {
        entries.isEmpty ? nil : Double(entries.map(\.energy).reduce(0, +)) / Double(entries.count)
    }
}

private struct TrendPoint: Identifiable {
    let id: String
    let date: Date
    let average: Double
    let segment: Int
}
#endif
