#if !os(watchOS)
import SwiftUI
import MyEnergyCore

/// 表单草稿留在展示页面中，取消或保存失败后仍可继续填写。
struct SleepDraft: Equatable {
    let recordID: UUID?
    let timeZoneIdentifier: String
    var bedtime: Date
    var wakeTime: Date
    var note: String

    init(record: SleepRecord) {
        recordID = record.id
        timeZoneIdentifier = record.timeZoneIdentifier
        bedtime = record.bedtime
        wakeTime = record.wakeTime
        note = record.note
    }

    init(now: Date = Date()) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let todayEnd = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: today) ?? now
        let endDay = todayEnd <= now ? today : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        let previousDay = calendar.date(byAdding: .day, value: -1, to: endDay) ?? endDay
        recordID = nil
        timeZoneIdentifier = TimeZone.current.identifier
        bedtime = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: previousDay) ?? previousDay
        wakeTime = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: endDay) ?? now
        note = ""
    }
}

struct SleepEditor: View {
    @ObservedObject var model: AppModel
    @Binding var draft: SleepDraft
    var onSaved: () -> Void = { }
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?

    private var originalExists: Bool {
        guard let id = draft.recordID else { return true }
        return model.visibleSleepRecords.contains { $0.id == id }
    }

    private var validationMessage: String? {
        if !originalExists { return "这条记录已被删除，无法继续保存。输入仍保留在此处。" }
        if draft.wakeTime <= draft.bedtime { return "结束时间需要晚于开始时间。跨午夜时，请同时调整日期。" }
        if draft.wakeTime.timeIntervalSince(draft.bedtime) > 24 * 60 * 60 { return "单条睡眠时段不能超过 24 小时，请核对日期。" }
        if draft.wakeTime > Date() { return "结束时间不能在未来。请在这段睡眠结束后补记。" }
        if draft.note.count > 500 { return "备注最多 500 字，请缩短后再保存。" }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.isDemo {
                    Section { Label("示例空间 · 不保存到真实记录或同步", systemImage: "sparkles").font(.callout) }
                }
                Section {
                    Label("手动补记 · 自述时段估算", systemImage: "pencil.and.outline")
                        .font(.headline).foregroundStyle(EnergyStyle.ink)
                    Text("填写你记得的开始和结束时间。时长按整个时段估算，可能包含清醒时间；不会写入 Apple 健康。")
                        .font(.callout).foregroundStyle(EnergyStyle.secondary)
                }
                Section {
                    DatePicker("开始时间", selection: $draft.bedtime, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                        .environment(\.timeZone, TimeZone(identifier: draft.timeZoneIdentifier) ?? .current)
                    DatePicker("结束时间", selection: $draft.wakeTime, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                        .environment(\.timeZone, TimeZone(identifier: draft.timeZoneIdentifier) ?? .current)
                    if draft.wakeTime > draft.bedtime {
                        LabeledContent("时段估算", value: "\((draft.wakeTime.timeIntervalSince(draft.bedtime) / 3600).formatted(.number.precision(.fractionLength(1)))) 小时")
                    }
                    Text("记录时区：\(draft.timeZoneIdentifier)")
                        .font(.caption).foregroundStyle(EnergyStyle.secondary)
                } header: { Text("睡眠时段") }
                footer: { Text("支持跨午夜，最长 24 小时。保留填写时的时区；趋势按查看设备时区的结束日期汇总。") }
                Section {
                    TextEditor(text: $draft.note).frame(minHeight: 110)
                        .accessibilityLabel("睡眠备注，最多 500 字")
                    HStack {
                        Text("例如夜里醒过、午睡或记不清时间")
                        Spacer()
                        Text("\(draft.note.count)/500").monospacedDigit()
                            .foregroundStyle(draft.note.count > 500 ? .red : EnergyStyle.secondary)
                    }.font(.caption).foregroundStyle(EnergyStyle.secondary)
                } header: { Text("备注 · 可选") }
                if let validationMessage { Section { InlineError(message: validationMessage) } }
                if let saveError { Section { InlineError(message: saveError) } }
                Section {
                    Text("取消后，输入会暂留在当前页面，便于继续填写。只有点“保存”才会写入记录；离开本栏目或关闭应用可能丢失未保存的草稿。")
                        .font(.footnote).foregroundStyle(EnergyStyle.secondary)
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden).background(EnergyStyle.canvas)
            .navigationTitle(draft.recordID == nil ? "补记睡眠" : "编辑睡眠记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(model.isSaving).keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isSaving ? "保存中…" : "保存") { Task { await save() } }
                        .disabled(!model.canEdit || validationMessage != nil).keyboardShortcut(.defaultAction)
                }
            }
        }.tint(EnergyStyle.forest)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 560, idealHeight: 700)
        #endif
        .interactiveDismissDisabled(model.isSaving)
    }

    private func save() async {
        saveError = nil
        if await model.saveSleep(id: draft.recordID, bedtime: draft.bedtime, wakeTime: draft.wakeTime, note: draft.note) {
            onSaved()
            dismiss()
        } else { saveError = model.errorMessage ?? "保存未完成。输入已保留，请重试。" }
    }
}

struct SleepRecordDetailView: View {
    @ObservedObject var model: AppModel
    private let recordID: UUID
    @State private var draft: SleepDraft
    @State private var hasUnfinishedDraft = false
    @State private var showsEditor = false
    @State private var showsDelete = false
    @State private var deleteError: String?
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, record: SleepRecord) {
        self.model = model
        recordID = record.id
        _draft = State(initialValue: SleepDraft(record: record))
    }

    private var record: SleepRecord? { model.visibleSleepRecords.first { $0.id == recordID } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let record {
                        EnergyCard {
                            VStack(alignment: .leading, spacing: 18) {
                                StatusPill(text: "手动补记 · 时段估算", symbol: "pencil.and.outline")
                                Text("\(record.durationHours.formatted(.number.precision(.fractionLength(1)))) 小时")
                                    .font(.system(.largeTitle, design: .rounded).weight(.medium)).foregroundStyle(EnergyStyle.ink)
                                LabeledContent("开始时间", value: sleepDateText(record.bedtime, timeZoneIdentifier: record.timeZoneIdentifier))
                                LabeledContent("结束时间", value: sleepDateText(record.wakeTime, timeZoneIdentifier: record.timeZoneIdentifier))
                                Text("时长按你填写的整个时段估算，可能包含清醒时间。")
                                    .font(.footnote).foregroundStyle(EnergyStyle.secondary)
                            }
                        }
                        EnergyCard {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeading(title: "给自己的备注")
                                Text(record.note.isEmpty ? "这次没有填写备注。" : record.note)
                                    .foregroundStyle(record.note.isEmpty ? EnergyStyle.secondary : EnergyStyle.ink)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Text("记录时区：\(record.timeZoneIdentifier)").font(.caption).foregroundStyle(EnergyStyle.secondary)
                                Text("修改于 \(record.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(EnergyStyle.secondary)
                            }
                        }
                        if hasUnfinishedDraft {
                            Text("上次取消的编辑输入仍暂留在此页，可以继续编辑。")
                                .font(.footnote).foregroundStyle(EnergyStyle.secondary)
                        }
                        Button(role: .destructive) { showsDelete = true } label: {
                            Label("删除这条睡眠记录", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered).disabled(!model.canEdit)
                    } else {
                        EmptyState(symbol: "tray", title: "这条睡眠记录已不存在", message: "它可能已被删除，返回后可查看其他记录。")
                    }
                    if let deleteError { InlineError(message: deleteError) }
                }.padding(24)
            }.background(EnergyStyle.canvas).navigationTitle("手动睡眠记录")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button(hasUnfinishedDraft ? "继续编辑" : "编辑") {
                            if let record, !hasUnfinishedDraft { draft = SleepDraft(record: record) }
                            hasUnfinishedDraft = true
                            showsEditor = true
                        }.disabled(record == nil || !model.canEdit)
                    }
                }
                .sheet(isPresented: $showsEditor) {
                    SleepEditor(model: model, draft: $draft) { hasUnfinishedDraft = false }
                }
                .confirmationDialog("删除这条手动睡眠记录？", isPresented: $showsDelete, titleVisibility: .visible) {
                    Button("删除睡眠记录", role: .destructive) {
                        Task {
                            if let record, await model.deleteSleep(record) { dismiss() }
                            else { deleteError = model.errorMessage ?? "删除未完成，请重试。" }
                        }
                    }
                    Button("取消", role: .cancel) { }
                } message: { Text("将删除这段手动填写的时间和备注。开启同步后，删除会传播到同账号设备。") }
        }.tint(EnergyStyle.forest)
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 560, idealHeight: 700)
        #endif
    }
}
#endif
