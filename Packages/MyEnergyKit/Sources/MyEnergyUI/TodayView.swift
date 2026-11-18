#if !os(watchOS)
import SwiftUI
import MyEnergyCore

struct TodayView: View {
    @Environment(\.energyTheme) private var theme
    @ObservedObject var model: AppModel
    let onRecord: () -> Void
    let onHabits: () -> Void
    let onSleep: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var selectedEntry: EnergyEntry?

    private var latest: EnergyEntry? { model.todayEntries.first }
    private var completed: Int { model.activeHabits.filter { model.isComplete($0) }.count }
    private var supportingColumns: [GridItem] {
        #if os(iOS)
        if sizeClass == .compact { return [GridItem(.flexible())] }
        #endif
        if typeSize.isAccessibilitySize { return [GridItem(.flexible())] }
        return [GridItem(.adaptive(minimum: 248), spacing: 20, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heading
                energyCard
                statistics
                LazyVGrid(columns: supportingColumns, alignment: .leading, spacing: 20) {
                    habitsCard
                    sleepCard
                    HealthReferenceCard(model: model)
                }
                recordsCard
                if let message = model.errorMessage, !model.hasLoadFailure {
                    InlineError(message: message)
                }
                Text("每次记录，都是多了解自己一点。")
                    .font(.footnote).foregroundStyle(theme.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }.padding(24).frame(maxWidth: 1040).frame(maxWidth: .infinity)
        }
        .background(theme.canvas)
        .sheet(item: $selectedEntry) { entry in EntryDetailView(model: model, entryID: entry.id) }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Date().energyDate).font(.subheadline).foregroundStyle(theme.secondary)
                Spacer()
                StatusPill(text: model.isDemo ? "示例数据" : "本机保存", symbol: model.isDemo ? "sparkles" : "internaldrive")
            }
            Text(greeting).font(.largeTitle.weight(.semibold)).foregroundStyle(theme.ink)
            Text("给自己片刻，感受现在的状态。")
                .font(.body).foregroundStyle(theme.secondary)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: "早上好，慢慢开启今天"
        case 11..<14: "中午好，给自己留个空隙"
        case 14..<18: "下午好，此刻感觉怎样？"
        default: "晚上好，回到自己的节奏"
        }
    }

    private var energyCard: some View {
        EnergyCard {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 36) {
                    energyCopy.frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)
                    EnergyRing(value: latest?.energy, size: 182).padding(12)
                }
                VStack(alignment: .leading, spacing: 24) {
                    EnergyRing(value: latest?.energy, size: 165).frame(maxWidth: .infinity).padding(.top, 8)
                    energyCopy
                }
            }
        }
    }

    private var energyCopy: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("我的精力", systemImage: "sun.haze").font(.title2.weight(.semibold)).foregroundStyle(theme.ink)
            Text("主观自评").font(.caption.weight(.semibold))
                .padding(.horizontal, 9).padding(.vertical, 5).background(theme.accentSoft, in: Capsule())
            StateThemeIndicator()
            if let latest {
                Text("你在 \(latest.occurredAt.energyTime) 留下的感受")
                    .font(.subheadline).foregroundStyle(theme.secondary)
                if let mood = latest.mood {
                    HStack(spacing: 9) { MoodGlyph(mood: mood); Text(mood.title).font(.body) }
                }
            } else {
                Text("现在感觉怎样？").font(.title3.weight(.medium))
                Text("没有标准答案，按自己的感受选就好。")
                    .font(.subheadline).foregroundStyle(theme.secondary)
            }
            Button(action: onRecord) {
                Label(latest == nil ? "记下此刻" : "再记一次", systemImage: "plus")
            }.buttonStyle(PrimaryButtonStyle()).disabled(!model.canEdit).padding(.top, 4)
        }.foregroundStyle(theme.ink)
    }

    private var statistics: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            statistic(value: "\(model.todayEntries.count)", title: "今日记录", symbol: "square.and.pencil")
            statistic(value: "\(completed)/\(model.activeHabits.count)", title: "今日习惯", symbol: "checkmark.circle")
            statistic(value: average, title: "今日平均精力", symbol: "waveform.path")
        }.accessibilityElement(children: .contain)
    }

    private var average: String {
        let entries = model.todayEntries
        guard !entries.isEmpty else { return "—" }
        return "\(Int((Double(entries.map(\.energy).reduce(0, +)) / Double(entries.count)).rounded()))"
    }

    private func statistic(value: String, title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(theme.accent)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(theme.ink)
            Text(title).font(.caption).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(theme.accentSoft.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .combine)
    }

    private var habitsCard: some View {
        EnergyCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    SectionHeading(title: "今天的小习惯", subtitle: "一件小事，也算照顾自己。")
                    Spacer()
                    Button("全部", action: onHabits).font(.callout)
                }
                if model.activeHabits.isEmpty {
                    EmptyState(symbol: "leaf", title: "从一件小事开始", message: "加一个属于自己的习惯，完成后随手记下。")
                    Button("添加小习惯", action: onHabits).buttonStyle(.bordered)
                } else {
                    ForEach(Array(model.activeHabits.prefix(3))) { habit in
                        HabitCompletionRow(model: model, habit: habit)
                    }
                }
            }
        }
    }

    private var sleepCard: some View {
        EnergyCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    SectionHeading(title: "睡眠观测", subtitle: "单独看看睡眠的节奏")
                    Spacer(minLength: 8)
                    Image(systemName: "moon.stars").font(.title2).foregroundStyle(theme.accent)
                }
                if let observation = model.latestSleepObservation {
                    SleepObservationContent(observation: observation, compact: true)
                    Text(observation.isEstimated ? "按手动填写的时段估算，可能包含清醒时间。" : "开始和结束表示观测边界，不据此确定真正入睡或起床的时刻。")
                        .font(.footnote).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("暂无带时间信息的睡眠观测。可以手动补记，也可以按需连接 Apple 健康。")
                        .font(.callout).foregroundStyle(theme.secondary)
                }
                Button(action: onSleep) {
                    Label("查看睡眠与补记", systemImage: "chevron.right")
                        .font(.callout).frame(minHeight: 44, alignment: .leading)
                }
            }
        }
    }

    private var recordsCard: some View {
        EnergyCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeading(title: "今日记录", subtitle: "按记录时的当地日期归档")
                NavigationLink {
                    RecordsHistoryView(model: model)
                } label: {
                    Label("查看全部记录（\(model.snapshot.entries.count)）", systemImage: "clock.arrow.circlepath")
                        .font(.callout).frame(minHeight: 44, alignment: .leading)
                }
                if model.todayEntries.isEmpty {
                    EmptyState(symbol: "square.and.pencil", title: "今天还没有记录", message: "精力可以有高有低，写下此刻就够了。")
                } else {
                    ForEach(model.todayEntries) { entry in
                        Button { selectedEntry = entry } label: { EntryRow(entry: entry) }
                            .buttonStyle(.plain)
                        if entry.id != model.todayEntries.last?.id { Divider().overlay(theme.border) }
                    }
                }
            }
        }
    }
}

struct EntryRow: View {
    @Environment(\.energyTheme) private var theme
    let entry: EnergyEntry
    var showDate = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("\(entry.energy)").font(.title2.weight(.medium).monospacedDigit())
                .foregroundStyle(theme.accent).frame(width: 54, height: 54)
                .background(theme.accentSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: 17))
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.mood?.title ?? "只记录了精力").font(.body.weight(.medium)).foregroundStyle(theme.ink)
                Text(entry.occurredAt.formatted(date: showDate ? .abbreviated : .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(theme.secondary)
            }
            Spacer(minLength: 4)
            if let mood = entry.mood { MoodGlyph(mood: mood, size: 32) }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(theme.secondary)
        }.frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.occurredAt.formatted(date: .abbreviated, time: .shortened))，主观精力 \(entry.energy)，\(entry.mood?.title ?? "未填写心情")")
            .accessibilityHint("查看详情、编辑或删除")
    }
}
#endif
