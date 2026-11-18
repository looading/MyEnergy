#if !os(watchOS)
import SwiftUI
import MyEnergyCore

struct EntryEditor: View {
    @ObservedObject var model: AppModel
    private let entry: EnergyEntry?
    @Environment(\.dismiss) private var dismiss
    @State private var energy: Double
    @State private var mood: Mood?
    @State private var note: String
    @State private var occurredAt: Date
    @State private var saveError: String?

    init(model: AppModel, entry: EnergyEntry? = nil) {
        self.model = model
        self.entry = entry
        _energy = State(initialValue: Double(entry?.energy ?? 50))
        _mood = State(initialValue: entry?.mood)
        _note = State(initialValue: entry?.note ?? "")
        _occurredAt = State(initialValue: entry?.occurredAt ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.isDemo { Section { Label("示例空间中的操作不会保存或同步", systemImage: "sparkles").font(.callout) } }
                Section {
                    VStack(spacing: 18) {
                        EnergyRing(value: Int(energy), size: 140).padding(.top, 12)
                        Text("按你自己的感受来选择").foregroundStyle(EnergyStyle.secondary)
                        Slider(value: $energy, in: 0...100, step: 1) {
                            Text("主观精力")
                        } minimumValueLabel: { Text("0").font(.caption) }
                        maximumValueLabel: { Text("100").font(.caption) }
                        .accessibilityLabel("主观精力")
                        .accessibilityValue("\(Int(energy))，范围 0 至 100")
                        Stepper("精力：\(Int(energy)) / 100", value: $energy, in: 0...100, step: 1)
                            .font(.callout).accessibilityLabel("逐点调整主观精力")
                    }.padding(.vertical, 8)
                } header: { Text("主观自评") }
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 10)], spacing: 12) {
                        ForEach(Mood.allCases, id: \.self) { choice in
                            Button { mood = choice } label: {
                                VStack(spacing: 9) {
                                    MoodGlyph(mood: choice, size: 42)
                                    Text(choice.title).font(.caption).multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Image(systemName: mood == choice ? "checkmark.circle.fill" : "circle")
                                        .font(.caption).foregroundStyle(mood == choice ? EnergyStyle.forest : EnergyStyle.secondary)
                                }.frame(maxWidth: .infinity, minHeight: 108).padding(7)
                                    .background(mood == choice ? EnergyStyle.sage.opacity(0.7) : EnergyStyle.canvas, in: RoundedRectangle(cornerRadius: 16))
                                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(mood == choice ? EnergyStyle.forest : .clear, lineWidth: 1.5))
                            }.buttonStyle(.plain).accessibilityLabel(choice.title)
                                .accessibilityAddTraits(mood == choice ? .isSelected : [])
                        }
                    }.padding(.vertical, 8)
                    Button(mood == nil ? "暂不填写心情（当前）" : "暂不填写心情") { mood = nil }
                        .frame(minHeight: 36)
                } header: { Text("此刻心情 · 可选") }
                footer: { Text("精力和心情可以是任何组合，彼此独立。") }
                Section {
                    TextEditor(text: $note).frame(minHeight: 100).accessibilityLabel("简短备注，最多 500 字")
                    HStack {
                        Text("只给自己看的几句话").foregroundStyle(EnergyStyle.secondary)
                        Spacer()
                        Text("\(note.count)/500").monospacedDigit().foregroundStyle(note.count > 500 ? .red : EnergyStyle.secondary)
                    }.font(.caption)
                } header: { Text("备注 · 可选") }
                Section {
                    DatePicker("发生时间", selection: $occurredAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    if let entry {
                        Text("保留原记录时区：\(entry.timeZoneIdentifier)").font(.caption).foregroundStyle(EnergyStyle.secondary)
                    }
                }
                if let saveError { Section { InlineError(message: saveError) } }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden).background(EnergyStyle.canvas)
            .navigationTitle(entry == nil ? "记下此刻" : "编辑记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isSaving ? "保存中…" : "保存") { Task { await save() } }
                        .disabled(!model.canEdit || note.count > 500).keyboardShortcut(.defaultAction)
                }
            }
        }
        .tint(EnergyStyle.forest)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 620, idealHeight: 780)
        #endif
        .interactiveDismissDisabled(model.isSaving)
    }

    private func save() async {
        let success = await model.saveEntry(id: entry?.id, energy: Int(energy), mood: mood, note: note, occurredAt: occurredAt)
        if success { dismiss() } else { saveError = model.errorMessage ?? "保存未完成，请重试。" }
    }
}

struct EntryDetailView: View {
    @ObservedObject var model: AppModel
    let entryID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var showsEdit = false
    @State private var showsDelete = false
    @State private var deleteError: String?

    private var entry: EnergyEntry? { model.snapshot.entries.first { $0.id == entryID } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let entry {
                    VStack(alignment: .leading, spacing: 24) {
                        EnergyCard {
                            VStack(spacing: 18) {
                                Text("主观自评").font(.subheadline).foregroundStyle(EnergyStyle.secondary)
                                EnergyRing(value: entry.energy, size: 170)
                                if let mood = entry.mood {
                                    HStack { MoodGlyph(mood: mood); Text(mood.title) }
                                } else { Text("未填写心情").foregroundStyle(EnergyStyle.secondary) }
                                Text(entry.occurredAt.formatted(date: .complete, time: .shortened))
                                    .font(.callout).multilineTextAlignment(.center).foregroundStyle(EnergyStyle.secondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
                        EnergyCard {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeading(title: "给自己的备注")
                                Text(entry.note.isEmpty ? "这次没有填写备注。" : entry.note)
                                    .foregroundStyle(entry.note.isEmpty ? EnergyStyle.secondary : EnergyStyle.ink)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Text("记录时区：\(entry.timeZoneIdentifier)").font(.caption).foregroundStyle(EnergyStyle.secondary)
                            }
                        }
                        if let deleteError { InlineError(message: deleteError) }
                        Button(role: .destructive) { showsDelete = true } label: {
                            Label("删除这条记录", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered)
                    }.padding(24)
                } else {
                    EmptyState(symbol: "tray", title: "这条记录已不存在", message: "它可能已被删除，返回后查看其他记录。")
                        .padding(24)
                }
            }.background(EnergyStyle.canvas).navigationTitle("记录详情")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button("编辑") { showsEdit = true }.disabled(entry == nil || !model.canEdit) }
                }
                .sheet(isPresented: $showsEdit) { if let entry { EntryEditor(model: model, entry: entry) } }
                .confirmationDialog("删除 \(entry?.occurredAt.formatted(date: .abbreviated, time: .shortened) ?? "") 的主观记录？", isPresented: $showsDelete, titleVisibility: .visible) {
                    Button("删除记录", role: .destructive) {
                        Task {
                            if let entry, await model.deleteEntry(entry) { dismiss() }
                            else { deleteError = model.errorMessage }
                        }
                    }
                    Button("取消", role: .cancel) { }
                } message: { Text("此操作会删除精力、心情和备注；开启同步后会传播到其他设备。") }
        }.tint(EnergyStyle.forest)
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 580, idealHeight: 720)
        #endif
    }
}
#endif
