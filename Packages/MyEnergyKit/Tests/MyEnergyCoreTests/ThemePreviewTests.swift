import Foundation
@testable import MyEnergyUI
import Testing

@Suite("State theme preview isolation")
struct ThemePreviewTests {
    @Test @MainActor func cancellingNestedPreviewRestoresUnderlyingDraft() {
        let state = ThemePreviewState()
        let outer = UUID(), inner = UUID()
        let low = StateThemeState(valence: -0.8, vitality: 0.2)
        let high = StateThemeState(valence: 0.7, vitality: 0.9)
        #expect(state.state == nil)
        state.set(low, for: outer)
        state.set(high, for: inner)
        #expect(state.state == high)
        state.end(UUID())
        #expect(state.state == high)
        state.end(inner)
        #expect(state.state == low)
        state.end(outer)
        #expect(state.state == nil)
    }

    @Test @MainActor func repeatedDraftUpdatesDoNotAccumulateAndWindowsRemainIndependent() {
        let first = ThemePreviewState(), second = ThemePreviewState()
        let token = UUID()
        for value in [-1.0, -0.4, 0.0, 0.5, 1.0] {
            first.set(StateThemeState(valence: value, vitality: (value + 1) / 2), for: token)
        }
        #expect(first.state?.valence == 1)
        #expect(first.state?.vitality == 1)
        #expect(second.state == nil)
        second.set(StateThemeState(valence: -1, vitality: 0), for: token)
        first.end(token)
        #expect(first.state == nil)
        #expect(second.state?.valence == -1)
        second.clear()
        #expect(second.state == nil)
    }

    @Test @MainActor func previewRetainsUnknownFlagsAndClearEndsAllTokens() {
        let state = ThemePreviewState()
        state.set(StateThemeState(valence: 1, vitality: 0), for: UUID())
        state.set(.neutral, for: UUID())
        #expect(state.state == .neutral)
        #expect(state.state?.hasMood == false)
        #expect(state.state?.hasEnergy == false)
        state.clear()
        #expect(state.state == nil)
    }

    @Test func transitionInterpolatesBothAxesAndUnknownFlagsDoNotForceAJump() {
        var modifier = InterpolatingThemeModifier(state: StateThemeState(valence: -1, vitality: 0),
            isDark: false, highContrast: false)
        let negative = modifier.palette
        modifier.animatableData = .init(-0.5, 0.25)
        let middle = modifier.palette
        #expect(middle.state.valence == -0.5)
        #expect(middle.state.vitality == 0.25)
        #expect(middle.canvasRGB != negative.canvasRGB)
        #expect(middle.canvasRGB != EnergyThemePalette(state: .neutral, isDark: false).canvasRGB)
        modifier.animatableData = .init(1, 1)
        #expect(modifier.palette == EnergyThemePalette(state: StateThemeState(valence: 1, vitality: 1), isDark: false))
        var toUnknown = InterpolatingThemeModifier(state: .neutral, isDark: true, highContrast: false)
        toUnknown.animatableData = .init(-0.5, 0.2)
        #expect(toUnknown.palette.state.valence == -0.5)
        #expect(toUnknown.palette.state.vitality == 0.2)
        #expect(!toUnknown.palette.state.hasMood)
    }
}
