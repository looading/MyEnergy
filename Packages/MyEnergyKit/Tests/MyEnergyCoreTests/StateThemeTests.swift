import Foundation
import MyEnergyCore
@testable import MyEnergyUI
import Testing

@Suite("Two-dimensional subjective state theme")
struct StateThemeTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func moodDirectionAndEnergyRemainIndependent() {
        let mappings: [(Mood, Double)] = [(.veryLow, -1), (.low, -0.5), (.neutral, 0), (.good, 0.5), (.veryGood, 1)]
        for (mood, valence) in mappings {
            for energy in [0.0, 17.3, 50, 100] {
                let state = ThemeStateResolver.state(energy: energy, mood: mood)
                #expect(state.valence == valence)
                #expect(state.vitality == energy / 100)
                #expect(state.hasMood)
                #expect(state.hasEnergy)
            }
        }
        let tiredAndHappy = ThemeStateResolver.state(energy: 0, mood: .veryGood)
        let energeticAndLow = ThemeStateResolver.state(energy: 100, mood: .veryLow)
        #expect(tiredAndHappy == StateThemeState(valence: 1, vitality: 0))
        #expect(energeticAndLow == StateThemeState(valence: -1, vitality: 1))
    }

    @Test func energyWithoutMoodNeverAddsAPositiveOrNegativeDirection() {
        for energy in [0.0, 25, 63.2, 75, 100] {
            let state = ThemeStateResolver.state(energy: energy, mood: nil)
            #expect(state.valence == 0)
            #expect(state.vitality == energy / 100)
            #expect(!state.hasMood)
            #expect(state.hasEnergy)
        }
        #expect(ThemeStateResolver.state(energy: nil, mood: nil) == .neutral)
        let unrecordedEnergy = ThemeStateResolver.state(energy: nil, mood: .good)
        #expect(unrecordedEnergy.valence == 0.5)
        #expect(unrecordedEnergy.vitality == 0.5)
        #expect(unrecordedEnergy.hasMood)
        #expect(!unrecordedEnergy.hasEnergy)
    }

    @Test func finiteEnergyClampsAndInvalidEnergyStaysUnknown() {
        #expect(ThemeStateResolver.state(energy: -10_000, mood: .good) == StateThemeState(valence: 0.5, vitality: 0))
        #expect(ThemeStateResolver.state(energy: 10_000, mood: .low) == StateThemeState(valence: -0.5, vitality: 1))
        for invalid in [Double.nan, .infinity, -.infinity] {
            #expect(ThemeStateResolver.state(energy: invalid, mood: nil) == .neutral)
            #expect(ThemeStateResolver.state(energy: invalid, mood: .veryLow)
                    == StateThemeState(valence: -1, vitality: 0.5, hasEnergy: false))
        }
    }

    @Test func stateClampsAxesWithoutDiscardingAnimationFramesForUnknownTargets() {
        #expect(StateThemeState(valence: -100, vitality: -100) == StateThemeState(valence: -1, vitality: 0))
        #expect(StateThemeState(valence: 100, vitality: 100) == StateThemeState(valence: 1, vitality: 1))
        for invalid in [Double.nan, .infinity, -.infinity] {
            #expect(StateThemeState(valence: invalid, vitality: invalid) == .neutral)
            #expect(StateThemeState(valence: invalid, vitality: 0.8)
                    == StateThemeState(valence: 0, vitality: 0.8, hasMood: false))
            #expect(StateThemeState(valence: -0.5, vitality: invalid)
                    == StateThemeState(valence: -0.5, vitality: 0.5, hasEnergy: false))
        }
        let fadingToUnknown = StateThemeState(valence: -0.4, vitality: 0.7, hasMood: false, hasEnergy: false)
        #expect(fadingToUnknown.valence == -0.4)
        #expect(fadingToUnknown.vitality == 0.7)
        #expect(!fadingToUnknown.hasMood)
        #expect(!fadingToUnknown.hasEnergy)
    }

    @Test func onlyRecordsInsideThePastDayDriveTheCurrentTheme() throws {
        let fresh = try EnergyEntry(energy: 75, mood: .low, occurredAt: now.addingTimeInterval(-3_600))
        let future = try EnergyEntry(energy: 0, mood: .veryLow, occurredAt: now.addingTimeInterval(0.001))
        let expired = try EnergyEntry(energy: 100, mood: .veryGood, occurredAt: now.addingTimeInterval(-86_400.001))
        #expect(ThemeStateResolver.state(entries: [], now: now) == .neutral)
        #expect(ThemeStateResolver.state(entries: [future, expired], now: now) == .neutral)
        #expect(ThemeStateResolver.state(entries: [future, expired, fresh], now: now)
                == StateThemeState(valence: -0.5, vitality: 0.75))
        let boundary = try EnergyEntry(energy: 0, occurredAt: now.addingTimeInterval(-86_400))
        #expect(ThemeStateResolver.state(entries: [boundary], now: now)
                == StateThemeState(valence: 0, vitality: 0, hasMood: false))
        #expect(ThemeStateResolver.state(entries: [boundary], now: now.addingTimeInterval(0.001)) == .neutral)
        let current = try EnergyEntry(energy: 100, mood: .neutral, occurredAt: now)
        #expect(ThemeStateResolver.state(entries: [current], now: now)
                == StateThemeState(valence: 0, vitality: 1))
    }

    @Test func newestOccurrenceWinsEvenWhenItsMoodIsMissing() throws {
        let earlier = try EnergyEntry(energy: 100, mood: .veryGood,
                                      occurredAt: now.addingTimeInterval(-200), modifiedAt: now)
        let later = try EnergyEntry(energy: 0, occurredAt: now.addingTimeInterval(-100),
                                   modifiedAt: now.addingTimeInterval(-100))
        #expect(ThemeStateResolver.state(entries: [later, earlier], now: now)
                == StateThemeState(valence: 0, vitality: 0, hasMood: false))
    }

    @Test func modificationThenUUIDBreakTiesWithoutDependingOnArrayOrder() throws {
        let earlier = try EnergyEntry(energy: 0, mood: .veryLow, occurredAt: now,
                                      modifiedAt: now.addingTimeInterval(-100))
        let edited = try EnergyEntry(energy: 75, mood: .good, occurredAt: now,
                                    modifiedAt: now.addingTimeInterval(-50))
        for reordered in [[earlier, edited], [edited, earlier]] {
            #expect(ThemeStateResolver.state(entries: reordered, now: now)
                    == StateThemeState(valence: 0.5, vitality: 0.75))
        }
        let lowID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
        let highID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
        let negative = try EnergyEntry(id: lowID, energy: 100, mood: .veryLow, occurredAt: now, modifiedAt: now)
        let positive = try EnergyEntry(id: highID, energy: 0, mood: .veryGood, occurredAt: now, modifiedAt: now)
        for reordered in [[negative, positive, earlier], [positive, earlier, negative], [earlier, negative, positive]] {
            #expect(ThemeStateResolver.state(entries: reordered, now: now)
                    == StateThemeState(valence: 1, vitality: 0))
        }
    }

    @Test func invalidDatesCannotPoisonSelection() throws {
        let valid = try EnergyEntry(energy: 75, mood: .good, occurredAt: now)
        for invalid in [Double.nan, .infinity, -.infinity] {
            var badOccurrence = valid
            badOccurrence.occurredAt = Date(timeIntervalSinceReferenceDate: invalid)
            var badModification = valid
            badModification.modifiedAt = Date(timeIntervalSinceReferenceDate: invalid)
            #expect(ThemeStateResolver.state(entries: [badOccurrence, badModification], now: now) == .neutral)
            #expect(ThemeStateResolver.state(entries: [badOccurrence, valid, badModification], now: now)
                    == StateThemeState(valence: 0.5, vitality: 0.75))
            #expect(ThemeStateResolver.state(entries: [valid], now: Date(timeIntervalSinceReferenceDate: invalid)) == .neutral)
        }
    }

    @Test func contrastMathUsesKnownSRGBRelativeLuminanceValues() {
        let black = ThemeRGB(red: 0, green: 0, blue: 0)
        let white = ThemeRGB(red: 1, green: 1, blue: 1)
        let middle = ThemeRGB(red: 0.5, green: 0.5, blue: 0.5)
        #expect(white.contrastRatio(against: black) == 21)
        #expect(black.contrastRatio(against: white) == 21)
        #expect(middle.contrastRatio(against: middle) == 1)
        #expect(abs(white.contrastRatio(against: middle) - 3.976_653) < 0.000_001)
    }

    @Test(arguments: [false, true], [false, true])
    func bothDimensionsMeetTextAndControlContrast(isDark: Bool, highContrast: Bool) {
        for moodSample in 0...20 {
            for energySample in 0...20 {
                let state = StateThemeState(valence: Double(moodSample) / 10 - 1, vitality: Double(energySample) / 20)
                let palette = EnergyThemePalette(state: state, isDark: isDark, highContrast: highContrast)
                let textMinimum = highContrast ? 7.0 : 4.5
                let controlMinimum = highContrast ? 4.5 : 3.0
                for background in [palette.canvasRGB, palette.surfaceRGB, palette.accentSoftRGB] {
                    #expect(palette.inkRGB.contrastRatio(against: background) >= textMinimum)
                    #expect(palette.secondaryRGB.contrastRatio(against: background) >= textMinimum)
                    #expect(palette.accentRGB.contrastRatio(against: background) >= controlMinimum)
                }
                #expect(palette.onAccentRGB.contrastRatio(against: palette.accentRGB) >= textMinimum)
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func colorsChangeContinuouslyAlongBothAxesAndAtTheNeutralJoin(isDark: Bool, highContrast: Bool) {
        for fixedSample in 0...20 {
            let fixed = Double(fixedSample) / 20
            var alongMood = palette(valence: -1, vitality: fixed, isDark: isDark, highContrast: highContrast)
            var alongEnergy = palette(valence: fixed * 2 - 1, vitality: 0, isDark: isDark, highContrast: highContrast)
            for movingSample in 1...100 {
                let moving = Double(movingSample) / 100
                let nextMood = palette(valence: moving * 2 - 1, vitality: fixed, isDark: isDark, highContrast: highContrast)
                let nextEnergy = palette(valence: fixed * 2 - 1, vitality: moving, isDark: isDark, highContrast: highContrast)
                expectClose(alongMood, nextMood, tolerance: 0.012)
                expectClose(alongEnergy, nextEnergy, tolerance: 0.012)
                #expect(alongMood.accentRGB != nextMood.accentRGB)
                #expect(alongEnergy.accentRGB != nextEnergy.accentRGB)
                alongMood = nextMood
                alongEnergy = nextEnergy
            }
            let left = palette(valence: -0.000_000_1, vitality: fixed, isDark: isDark, highContrast: highContrast)
            let center = palette(valence: 0, vitality: fixed, isDark: isDark, highContrast: highContrast)
            let right = palette(valence: 0.000_000_1, vitality: fixed, isDark: isDark, highContrast: highContrast)
            expectClose(left, center, tolerance: 0.000_001)
            expectClose(center, right, tolerance: 0.000_001)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func intermediateColorsUseBothDimensions(isDark: Bool, highContrast: Bool) {
        for valence in [-0.85, -0.2, 0.15, 0.75] {
            let leftValence = valence < 0 ? -1.0 : 0
            let rightValence = valence < 0 ? 0.0 : 1
            let moodFraction = valence - leftValence
            let energyFraction = 0.35
            let lowerLeft = colors(palette(valence: leftValence, vitality: 0, isDark: isDark, highContrast: highContrast))
            let upperLeft = colors(palette(valence: leftValence, vitality: 1, isDark: isDark, highContrast: highContrast))
            let lowerRight = colors(palette(valence: rightValence, vitality: 0, isDark: isDark, highContrast: highContrast))
            let upperRight = colors(palette(valence: rightValence, vitality: 1, isDark: isDark, highContrast: highContrast))
            let result = colors(palette(valence: valence, vitality: energyFraction, isDark: isDark, highContrast: highContrast))
            for index in result.indices {
                let left = mix(lowerLeft[index], upperLeft[index], amount: energyFraction)
                let right = mix(lowerRight[index], upperRight[index], amount: energyFraction)
                expectClose(result[index], mix(left, right, amount: moodFraction), tolerance: 0.000_000_001)
            }
        }
    }

    @Test(arguments: [false, true])
    func sixAnchorsRetainDistinctProductColorFamilies(isDark: Bool) {
        let negativeLow = palette(valence: -1, vitality: 0, isDark: isDark).accentRGB
        let negativeHigh = palette(valence: -1, vitality: 1, isDark: isDark).accentRGB
        let positiveLow = palette(valence: 1, vitality: 0, isDark: isDark).accentRGB
        let positiveHigh = palette(valence: 1, vitality: 1, isDark: isDark).accentRGB
        #expect(negativeLow.blue > negativeLow.red)
        #expect(negativeHigh.red > negativeHigh.blue)
        #expect(negativeHigh.blue > negativeHigh.green)
        #expect(positiveLow.green > positiveLow.red)
        #expect(positiveLow.blue > positiveLow.red)
        #expect(positiveHigh.red > positiveHigh.green)
        #expect(positiveHigh.green > positiveHigh.blue)
        for vitality in [0.0, 0.5, 1] {
            let neutral = palette(valence: 0, vitality: vitality, isDark: isDark).accentRGB
            #expect(neutral.green > neutral.red)
            #expect(neutral.green > neutral.blue)
        }
    }

    private func palette(valence: Double, vitality: Double, isDark: Bool, highContrast: Bool = false) -> EnergyThemePalette {
        EnergyThemePalette(state: StateThemeState(valence: valence, vitality: vitality),
                           isDark: isDark, highContrast: highContrast)
    }

    private func colors(_ palette: EnergyThemePalette) -> [ThemeRGB] {
        [palette.canvasRGB, palette.surfaceRGB, palette.inkRGB, palette.secondaryRGB,
         palette.accentRGB, palette.accentSoftRGB, palette.borderRGB, palette.onAccentRGB]
    }

    private func expectClose(_ before: EnergyThemePalette, _ after: EnergyThemePalette, tolerance: Double) {
        for (first, second) in zip(colors(before), colors(after)) {
            expectClose(first, second, tolerance: tolerance)
        }
    }

    private func expectClose(_ before: ThemeRGB, _ after: ThemeRGB, tolerance: Double) {
        #expect(abs(before.red - after.red) < tolerance)
        #expect(abs(before.green - after.green) < tolerance)
        #expect(abs(before.blue - after.blue) < tolerance)
    }

    private func mix(_ before: ThemeRGB, _ after: ThemeRGB, amount: Double) -> ThemeRGB {
        ThemeRGB(red: before.red * (1 - amount) + after.red * amount,
                 green: before.green * (1 - amount) + after.green * amount,
                 blue: before.blue * (1 - amount) + after.blue * amount)
    }
}
