import Foundation
import SwiftUI
import MyEnergyCore

/// 每个窗口独立持有的临时视觉预览。它不引用存储，也不修改主观记录。
@MainActor
final class ThemePreviewState: ObservableObject {
    @Published private(set) var state: StateThemeState?
    private var previews: [(token: UUID, state: StateThemeState)] = []

    func set(_ value: StateThemeState, for token: UUID) {
        previews.removeAll { $0.token == token }
        previews.append((token, value))
        state = value
    }

    func end(_ token: UUID) {
        guard previews.contains(where: { $0.token == token }) else { return }
        previews.removeAll { $0.token == token }
        state = previews.last?.state
    }

    func clear() {
        previews.removeAll()
        state = nil
    }
}

/// 心情与精力分别作为动画轴，每帧生成 RGB，不把精力加进心情方向。
nonisolated struct InterpolatingThemeModifier: AnimatableModifier {
    var valence: Double
    var vitality: Double
    let hasMood: Bool
    let hasEnergy: Bool
    let isDark: Bool
    let highContrast: Bool

    init(state: StateThemeState, isDark: Bool, highContrast: Bool) {
        valence = state.valence
        vitality = state.vitality
        hasMood = state.hasMood
        hasEnergy = state.hasEnergy
        self.isDark = isDark
        self.highContrast = highContrast
    }

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(valence, vitality) }
        set { valence = newValue.first; vitality = newValue.second }
    }

    var palette: EnergyThemePalette {
        EnergyThemePalette(state: StateThemeState(valence: valence, vitality: vitality,
            hasMood: hasMood, hasEnergy: hasEnergy), isDark: isDark, highContrast: highContrast)
    }

    @MainActor func body(content: Content) -> some View {
        content
            .environment(\.energyTheme, palette)
            .tint(palette.accent)
            .background(palette.canvas)
    }
}

struct EnergyStateThemeHost<Content: View>: View {
    @ObservedObject private var model: AppModel
    @StateObject private var preview = ThemePreviewState()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let content: Content

    init(model: AppModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { _ in
            // Timeline 只负责周期性触发过期检查；记录变更时使用真实当前时刻，不能沿用上次 tick 的时间。
            let savedState = ThemeStateResolver.state(entries: model.snapshot.entries, now: Date())
            let target = preview.state ?? savedState
            content
                .modifier(InterpolatingThemeModifier(state: target, isDark: colorScheme == .dark,
                    highContrast: contrast == .increased))
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.6), value: target)
                .transaction { transaction in
                    if reduceMotion {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
                .environmentObject(preview)
        }
        .onChange(of: model.storageURL) { _, _ in preview.clear() }
        .onChange(of: model.isDemo) { _, _ in preview.clear() }
    }
}

private struct StateThemeDraftModifier: ViewModifier {
    let energy: Double
    let mood: Mood?
    @EnvironmentObject private var preview: ThemePreviewState
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: energy) { _, _ in updatePreview() }
            .onChange(of: mood) { _, _ in updatePreview() }
            .onDisappear { preview.end(token) }
    }

    private func updatePreview() {
        preview.set(ThemeStateResolver.state(energy: energy, mood: mood), for: token)
    }
}

extension View {
    func stateThemeDraft(energy: Double, mood: Mood?) -> some View {
        modifier(StateThemeDraftModifier(energy: energy, mood: mood))
    }
}
