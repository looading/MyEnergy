#if !os(watchOS)
import SwiftUI
import MyEnergyCore

/// 不限制时间范围，补记到更早日期的记录也能重新找到。
struct RecordsHistoryView: View {
    @ObservedObject var model: AppModel
    @State private var selectedEntry: EnergyEntry?

    private var days: [HistoryDay] {
        let grouped = Dictionary(grouping: model.snapshot.entries) { entry in
            DateRules.dayKey(for: entry.occurredAt,
                timeZone: TimeZone(identifier: entry.timeZoneIdentifier) ?? .current)
        }
        return grouped.keys.sorted(by: >).map { key in
            HistoryDay(key: key, entries: (grouped[key] ?? []).sorted { $0.occurredAt > $1.occurredAt })
        }
    }

    var body: some View {
        Group {
            if model.snapshot.entries.isEmpty {
                EmptyState(symbol: "tray", title: "还没有记录", message: "记下第一次感受后，可以在这里查看、编辑和删除。")
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        Text("共 \(model.snapshot.entries.count) 条主观记录，按每条记录保存的当地日期归档，包含全部历史日期。")
                            .font(.footnote).foregroundStyle(EnergyStyle.secondary)
                            .listRowBackground(EnergyStyle.surface)
                    }
                    ForEach(days) { day in
                        Section(day.key) {
                            ForEach(day.entries) { entry in
                                Button { selectedEntry = entry } label: { EntryRow(entry: entry) }
                                    .buttonStyle(.plain).listRowBackground(EnergyStyle.surface)
                            }
                        }
                    }
                }.scrollContentBackground(.hidden)
            }
        }
        .background(EnergyStyle.canvas)
        .navigationTitle("全部记录")
        .sheet(item: $selectedEntry) { entry in EntryDetailView(model: model, entryID: entry.id) }
    }
}

private struct HistoryDay: Identifiable {
    let key: String
    let entries: [EnergyEntry]
    var id: String { key }
}
#endif
