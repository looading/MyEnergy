#if !os(watchOS)
import SwiftUI
import MyEnergyCore

struct HabitsView: View {
    @Environment(\.energyTheme) private var theme
    @ObservedObject var model: AppModel
    @State private var showsNewHabit = false
    @State private var editingHabit: HabitDefinition?
    @State private var showsArchived = false

    private var archived: [HabitDefinition] { model.snapshot.habits.filter(\.isArchived) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionHeading(title: "从一件小事开始", subtitle: "完成多少都可以，每天重新出发。")
                EnergyCard {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Text("今天 · \(model.activeHabits.filter { model.isComplete($0) }.count)/\(model.activeHabits.count) 已完成")
                                .font(.headline).foregroundStyle(theme.ink)
                            Spacer()
                            Button { showsNewHabit = true } label: { Label("添加", systemImage: "plus") }.disabled(!model.canEdit)
                        }
                        if model.activeHabits.isEmpty {
                            EmptyState(symbol: "leaf", title: "留一件小事给自己", message: "走走、喝水、安静片刻，选一个你喜欢的开始。")
                            HStack {
                                suggestedHabit("起身走一走", symbol: "figure.walk")
                                suggestedHabit("喝一杯水", symbol: "drop")
                            }
                        } else {
                            ForEach(model.activeHabits) { habit in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 10) {
                                        HabitCompletionRow(model: model, habit: habit)
                                        Menu {
                                            Button("编辑", systemImage: "pencil") { editingHabit = habit }
                                            Button("停用习惯", systemImage: "archivebox") { Task { await model.setHabitArchived(habit, archived: true) } }
                                        } label: {
                                            Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                                        }.accessibilityLabel("管理\(habit.title)").disabled(!model.canEdit)
                                    }
                                    Text("近 7 天完成 \(recentCompletionCount(habit)) 天")
                                        .font(.caption).foregroundStyle(theme.secondary).padding(.leading, 50)
                                }
                                if habit.id != model.activeHabits.last?.id { Divider() }
                            }
                        }
                    }
                }
                Text("点击圆圈标记完成，再点一次即可撤销。记录日期在打卡时固定，旅行后也会保留。")
                    .font(.footnote).foregroundStyle(theme.secondary)
                if !archived.isEmpty {
                    EnergyCard {
                        DisclosureGroup("已停用的习惯（\(archived.count)）", isExpanded: $showsArchived) {
                            VStack(spacing: 16) {
                                ForEach(archived) { habit in
                                    HStack {
                                        Label(habit.title, systemImage: habit.symbol).foregroundStyle(theme.secondary)
                                        Spacer()
                                        Button("重新启用") { Task { await model.setHabitArchived(habit, archived: false) } }
                                            .disabled(!model.canEdit)
                                    }
                                }
                                Text("过去的完成记录会保留。停用期间无需打卡。")
                                    .font(.caption).foregroundStyle(theme.secondary)
                            }.padding(.top, 16)
                        }
                    }
                }
                if let error = model.errorMessage { InlineError(message: error) }
            }.padding(24).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.background(theme.canvas)
            .sheet(isPresented: $showsNewHabit) { HabitEditor(model: model) }
            .sheet(item: $editingHabit) { HabitEditor(model: model, habit: $0) }
    }

    private func suggestedHabit(_ title: String, symbol: String) -> some View {
        Button { Task { await model.saveHabit(title: title, symbol: symbol) } } label: {
            Label(title, systemImage: symbol).font(.callout).frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.bordered).disabled(!model.canEdit)
    }

    private func recentCompletionCount(_ habit: HabitDefinition) -> Int {
        let keys = Set(DateRules.recentDays(count: 7).map { DateRules.dayKey(for: $0) })
        return model.snapshot.checkIns.filter { $0.habitID == habit.id && $0.isComplete && keys.contains($0.dayKey) }.count
    }
}

struct HabitCompletionRow: View {
    @Environment(\.energyTheme) private var theme
    @ObservedObject var model: AppModel
    let habit: HabitDefinition

    var body: some View {
        Button {
            let fixedDay = model.todayKey
            Task { await model.toggleHabit(habit, dayKey: fixedDay) }
        } label: {
            HStack(spacing: 13) {
                Image(systemName: model.isComplete(habit) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 29, weight: .light)).foregroundStyle(theme.accent)
                Image(systemName: habit.symbol).font(.body).foregroundStyle(theme.secondary).frame(width: 23)
                Text(habit.title).font(.body).foregroundStyle(theme.ink).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if model.isComplete(habit) { Text("完成").font(.caption).foregroundStyle(theme.secondary) }
            }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!model.canEdit)
            .accessibilityLabel("\(habit.title)，\(model.isComplete(habit) ? "今天已完成" : "今天未完成")")
            .accessibilityHint(model.isComplete(habit) ? "撤销今日完成" : "标记今日完成")
    }
}

struct HabitEditor: View {
    @Environment(\.energyTheme) private var theme
    @ObservedObject var model: AppModel
    private let habit: HabitDefinition?
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var symbol: String
    @State private var saveError: String?
    private let symbols = ["leaf", "figure.walk", "drop", "cup.and.saucer", "sun.max", "book", "bed.double", "wind", "heart", "moon"]

    init(model: AppModel, habit: HabitDefinition? = nil) {
        self.model = model
        self.habit = habit
        _title = State(initialValue: habit?.title ?? "")
        _symbol = State(initialValue: habit?.symbol ?? "leaf")
    }

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：给自己留十分钟", text: $title).accessibilityLabel("习惯名称")
                    Text("\(trimmed.count)/40 字").font(.caption).foregroundStyle(trimmed.count > 40 ? .red : theme.secondary)
                } header: { Text("一件想为自己做的小事") }
                Section("选一个图标") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 54))], spacing: 12) {
                        ForEach(symbols, id: \.self) { item in
                            Button { symbol = item } label: {
                                Image(systemName: item).font(.title2).frame(maxWidth: .infinity, minHeight: 54)
                                    .foregroundStyle(theme.accent)
                                    .background(symbol == item ? theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 13))
                                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(symbol == item ? theme.accent : theme.border))
                            }.buttonStyle(.plain).accessibilityLabel(iconLabel(item))
                                .accessibilityAddTraits(symbol == item ? .isSelected : [])
                        }
                    }.padding(.vertical, 8)
                }
                Section { Text("每天手动完成，也可以随时撤销。停用习惯后，历史记录仍会保留。")
                    .font(.callout).foregroundStyle(theme.secondary) }
                if let saveError { Section { InlineError(message: saveError) } }
            }.formStyle(.grouped).scrollContentBackground(.hidden).background(theme.canvas)
                .navigationTitle(habit == nil ? "添加小习惯" : "编辑小习惯")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.keyboardShortcut(.cancelAction) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            Task {
                                if await model.saveHabit(id: habit?.id, title: trimmed, symbol: symbol) { dismiss() }
                                else { saveError = model.errorMessage }
                            }
                        }.disabled(!model.canEdit || trimmed.isEmpty || trimmed.count > 40).keyboardShortcut(.defaultAction)
                    }
                }
        }.tint(theme.accent)
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 430, idealHeight: 520)
        #endif
    }

    private func iconLabel(_ symbol: String) -> String {
        switch symbol {
        case "leaf": "叶子"; case "figure.walk": "散步"; case "drop": "水滴"; case "cup.and.saucer": "茶杯"
        case "sun.max": "太阳"; case "book": "读书"; case "bed.double": "休息"; case "wind": "微风"
        case "heart": "爱心"; default: "月亮"
        }
    }
}
#endif
