import SwiftUI
import MyEnergyCore

public struct MyEnergyRootView: View {
    @ObservedObject private var model: AppModel
    #if !os(watchOS)
    @State private var section: AppSection = .today
    @State private var showsEntry = false
    #endif
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        #if os(watchOS)
        MyEnergyWatchView(model: model)
        #else
        navigation
            .tint(EnergyStyle.forest)
            .background(EnergyStyle.canvas)
            .safeAreaInset(edge: .top, spacing: 0) { statusBanner }
            .sheet(isPresented: $showsEntry) { EntryEditor(model: model) }
        #endif
    }

    #if !os(watchOS)
    @ViewBuilder private var navigation: some View {
        #if os(iOS)
        if sizeClass == .compact {
            TabView(selection: $section) {
                ForEach(AppSection.allCases) { item in
                    NavigationStack { page(item) }
                        .tabItem { Label(item.title, systemImage: item.symbol) }.tag(item)
                }
            }
        } else { sidebar }
        #else
        sidebar
        #endif
    }

    private var sidebar: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: Binding<AppSection?>(get: { section }, set: { if let value = $0 { section = value } })) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
                    .padding(.vertical, 7)
            }
            .navigationTitle("MyEnergy")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "leaf").font(.title2).foregroundStyle(EnergyStyle.forest)
                    Text("留一点时间，\n听听自己的感受。")
                        .font(.callout).foregroundStyle(EnergyStyle.secondary)
                    Text(model.localStatus).font(.caption2).foregroundStyle(EnergyStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
            }
            .navigationSplitViewColumnWidth(min: 195, ideal: 220, max: 270)
        } detail: {
            NavigationStack { page(section) }
        }
    }

    private func page(_ item: AppSection) -> some View {
        Group {
            switch item {
            case .today: TodayView(model: model, onRecord: { showsEntry = true }, onHabits: { section = .habits })
            case .trends: TrendsView(model: model)
            case .habits: HabitsView(model: model)
            case .settings: EnergySettingsView(model: model)
            }
        }
        .navigationTitle(item.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showsEntry = true } label: { Label("记一下", systemImage: "plus") }
                    .disabled(!model.canEdit).keyboardShortcut("n", modifiers: .command)
            }
            #if os(macOS)
            ToolbarItem(placement: .automatic) {
                Button { section = .settings } label: { Label("我的", systemImage: "gearshape") }
                    .keyboardShortcut(",", modifiers: .command)
            }
            #endif
        }
    }

    @ViewBuilder private var statusBanner: some View {
        if model.isDemo {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                Text("正在体验示例 · 不会保存或同步").font(.callout.weight(.medium))
                Spacer(minLength: 0)
                Button("退出示例") { model.exitDemo() }.buttonStyle(.bordered)
            }.padding(.horizontal, 20).padding(.vertical, 10)
                .background(EnergyStyle.sage).foregroundStyle(EnergyStyle.ink)
                .accessibilityElement(children: .contain)
        } else if model.hasLoadFailure {
            HStack(alignment: .top, spacing: 12) {
                InlineError(message: model.errorMessage ?? "本机记录读取失败，原文件已保留。")
                Spacer(minLength: 0)
                Button("重试") { Task { await model.load() } }.disabled(model.isSaving)
            }.padding(16).background(EnergyStyle.surface)
        } else if !model.isLoaded {
            HStack { ProgressView(); Text("正在读取本机记录…").font(.callout) }
                .frame(maxWidth: .infinity).padding(12).background(EnergyStyle.surface)
        }
    }
    #endif
}

#if !os(watchOS)
private enum AppSection: String, CaseIterable, Identifiable {
    case today, trends, habits, settings
    var id: Self { self }
    var title: String {
        switch self { case .today: "今日"; case .trends: "趋势"; case .habits: "习惯"; case .settings: "我的" }
    }
    var symbol: String {
        switch self { case .today: "sun.max"; case .trends: "chart.xyaxis.line"; case .habits: "leaf"; case .settings: "person.crop.circle" }
    }
}
#endif
