import Foundation
import MyEnergyCore
import SwiftUI

/// 两个独立的视觉维度；缺失标志用于文案，数值仍可承载动画中的中间帧。
struct StateThemeState: Equatable, Sendable {
    let valence: Double
    let vitality: Double
    let hasMood: Bool
    let hasEnergy: Bool

    init(valence: Double, vitality: Double, hasMood: Bool = true, hasEnergy: Bool = true) {
        self.valence = valence.isFinite ? min(1, max(-1, valence)) : 0
        self.vitality = vitality.isFinite ? min(1, max(0, vitality)) : 0.5
        self.hasMood = hasMood && valence.isFinite
        self.hasEnergy = hasEnergy && vitality.isFinite
    }

    static let neutral = StateThemeState(valence: 0, vitality: 0.5, hasMood: false, hasEnergy: false)
}

/// 只使用主观记录：心情决定方向，精力独立调整鲜明程度，不推断情绪。
enum ThemeStateResolver {
    static func state(energy: Double?, mood: Mood?) -> StateThemeState {
        let valence: Double = switch mood {
        case .veryLow: -1
        case .low: -0.5
        case .neutral: 0
        case .good: 0.5
        case .veryGood: 1
        case nil: 0
        }
        let vitality = energy.flatMap { $0.isFinite ? min(100, max(0, $0)) / 100 : nil }
        return StateThemeState(valence: valence, vitality: vitality ?? 0.5,
                               hasMood: mood != nil, hasEnergy: vitality != nil)
    }

    static func state(entries: [EnergyEntry], now: Date = Date()) -> StateThemeState {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return .neutral }
        let oldest = now.addingTimeInterval(-24 * 60 * 60)
        let latest = entries.filter {
            $0.occurredAt.timeIntervalSinceReferenceDate.isFinite
                && $0.modifiedAt.timeIntervalSinceReferenceDate.isFinite
                && $0.occurredAt >= oldest && $0.occurredAt <= now
        }.max {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard let latest else { return .neutral }
        return state(energy: Double(latest.energy), mood: latest.mood)
    }
}

/// 数值 sRGB 颜色；与 SwiftUI 渲染共用数值，供无屏幕环境检查对比度。
struct ThemeRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = Self.channel(red)
        self.green = Self.channel(green)
        self.blue = Self.channel(blue)
    }

    fileprivate init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    func contrastRatio(against other: ThemeRGB) -> Double {
        let lighter = max(luminance, other.luminance)
        let darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    fileprivate func mixed(with other: ThemeRGB, amount: Double) -> ThemeRGB {
        ThemeRGB(red: red + (other.red - red) * amount,
                 green: green + (other.green - green) * amount,
                 blue: blue + (other.blue - blue) * amount)
    }

    private static func channel(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    private var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// 按两个连续维度生成语义色；配色是产品表达约定，不是情绪测量。
struct EnergyThemePalette: Equatable, Sendable {
    let state: StateThemeState
    let isDark: Bool
    let highContrast: Bool
    let canvasRGB: ThemeRGB
    let surfaceRGB: ThemeRGB
    let inkRGB: ThemeRGB
    let secondaryRGB: ThemeRGB
    let accentRGB: ThemeRGB
    let accentSoftRGB: ThemeRGB
    let borderRGB: ThemeRGB
    let onAccentRGB: ThemeRGB

    var canvas: Color { canvasRGB.color }
    var surface: Color { surfaceRGB.color }
    var ink: Color { inkRGB.color }
    var secondary: Color { secondaryRGB.color }
    var accent: Color { accentRGB.color }
    var accentSoft: Color { accentSoftRGB.color }
    var border: Color { borderRGB.color }
    var onAccent: Color { onAccentRGB.color }

    init(state: StateThemeState, isDark: Bool, highContrast: Bool = false) {
        self.state = state
        self.isDark = isDark
        self.highContrast = highContrast
        let anchors = isDark ? ThemeColors.dark : ThemeColors.light
        // 先在精力轴插值，再在消极／中性／积极之间插值；中性接缝保持连续。
        let negative = anchors.negativeLow.mixed(with: anchors.negativeHigh, amount: state.vitality)
        let neutral = anchors.neutralLow.mixed(with: anchors.neutralHigh, amount: state.vitality)
        let positive = anchors.positiveLow.mixed(with: anchors.positiveHigh, amount: state.vitality)
        let colors = state.valence <= 0
            ? negative.mixed(with: neutral, amount: state.valence + 1)
            : neutral.mixed(with: positive, amount: state.valence)
        let white = ThemeRGB(red: 1, green: 1, blue: 1)
        let black = ThemeRGB(red: 0, green: 0, blue: 0)
        if highContrast {
            canvasRGB = colors.canvas.mixed(with: isDark ? black : white, amount: 0.35)
            surfaceRGB = colors.surface.mixed(with: isDark ? black : white, amount: isDark ? 0.35 : 0.55)
            inkRGB = colors.ink.mixed(with: isDark ? white : black, amount: 0.25)
            secondaryRGB = colors.secondary.mixed(with: isDark ? white : black, amount: 0.25)
            accentRGB = colors.accent.mixed(with: isDark ? white : black, amount: 0.20)
            accentSoftRGB = colors.accentSoft.mixed(with: isDark ? black : white, amount: 0.15)
            borderRGB = colors.border.mixed(with: isDark ? white : black, amount: 0.20)
            onAccentRGB = isDark ? black : white
        } else {
            canvasRGB = colors.canvas
            surfaceRGB = colors.surface
            inkRGB = colors.ink
            secondaryRGB = colors.secondary
            accentRGB = colors.accent
            accentSoftRGB = colors.accentSoft
            borderRGB = colors.border
            onAccentRGB = isDark ? ThemeRGB(red: 0.04, green: 0.04, blue: 0.04) : white
        }
    }
}

private struct ThemeAnchors: Sendable {
    let negativeLow: ThemeColors
    let negativeHigh: ThemeColors
    let neutralLow: ThemeColors
    let neutralHigh: ThemeColors
    let positiveLow: ThemeColors
    let positiveHigh: ThemeColors
}

private struct ThemeColors: Sendable {
    let canvas: ThemeRGB
    let surface: ThemeRGB
    let ink: ThemeRGB
    let secondary: ThemeRGB
    let accent: ThemeRGB
    let accentSoft: ThemeRGB
    let border: ThemeRGB

    private init(canvas: UInt32, surface: UInt32, ink: UInt32, secondary: UInt32,
                 accent: UInt32, accentSoft: UInt32, border: UInt32) {
        self.canvas = ThemeRGB(hex: canvas)
        self.surface = ThemeRGB(hex: surface)
        self.ink = ThemeRGB(hex: ink)
        self.secondary = ThemeRGB(hex: secondary)
        self.accent = ThemeRGB(hex: accent)
        self.accentSoft = ThemeRGB(hex: accentSoft)
        self.border = ThemeRGB(hex: border)
    }

    private init(canvas: ThemeRGB, surface: ThemeRGB, ink: ThemeRGB, secondary: ThemeRGB,
                 accent: ThemeRGB, accentSoft: ThemeRGB, border: ThemeRGB) {
        self.canvas = canvas
        self.surface = surface
        self.ink = ink
        self.secondary = secondary
        self.accent = accent
        self.accentSoft = accentSoft
        self.border = border
    }

    func mixed(with other: ThemeColors, amount: Double) -> ThemeColors {
        ThemeColors(canvas: canvas.mixed(with: other.canvas, amount: amount),
                    surface: surface.mixed(with: other.surface, amount: amount),
                    ink: ink.mixed(with: other.ink, amount: amount),
                    secondary: secondary.mixed(with: other.secondary, amount: amount),
                    accent: accent.mixed(with: other.accent, amount: amount),
                    accentSoft: accentSoft.mixed(with: other.accentSoft, amount: amount),
                    border: border.mixed(with: other.border, amount: amount))
    }

    // 每种模式使用六个锚点，保持背景柔和，文字与按钮单独保证可读性。
    static let light = ThemeAnchors(
        negativeLow: ThemeColors(canvas: 0xF2EFF5, surface: 0xFCFAFE, ink: 0x322D3A,
                                 secondary: 0x59515F, accent: 0x675576, accentSoft: 0xE4DDEB, border: 0x8B7D94),
        negativeHigh: ThemeColors(canvas: 0xF8EDF2, surface: 0xFFFAFC, ink: 0x402831,
                                  secondary: 0x65434F, accent: 0x934661, accentSoft: 0xEED6E0, border: 0xA06D80),
        neutralLow: ThemeColors(canvas: 0xF0F2EC, surface: 0xFAFCF7, ink: 0x2D382F,
                                secondary: 0x505C51, accent: 0x526A55, accentSoft: 0xDDE5D9, border: 0x7F8D7C),
        neutralHigh: ThemeColors(canvas: 0xEFF7EA, surface: 0xFBFFF7, ink: 0x203A2B,
                                 secondary: 0x465B49, accent: 0x32673F, accentSoft: 0xD6E9CD, border: 0x738E6B),
        positiveLow: ThemeColors(canvas: 0xEAF5F2, surface: 0xF8FEFC, ink: 0x253D3A,
                                 secondary: 0x465D59, accent: 0x326B64, accentSoft: 0xCEE5DE, border: 0x6C9086),
        positiveHigh: ThemeColors(canvas: 0xFDF2E5, surface: 0xFFFCF6, ink: 0x432B1B,
                                  secondary: 0x674D36, accent: 0x985521, accentSoft: 0xF4DCBA, border: 0xA47E52))

    static let dark = ThemeAnchors(
        negativeLow: ThemeColors(canvas: 0x18151D, surface: 0x26212D, ink: 0xEEE8F4,
                                 secondary: 0xC3B9CE, accent: 0xB8A8C8, accentSoft: 0x3C3248, border: 0x81718E),
        negativeHigh: ThemeColors(canvas: 0x21141A, surface: 0x321F28, ink: 0xFAE8F0,
                                  secondary: 0xD9B8C7, accent: 0xD9A0B7, accentSoft: 0x4D2F3D, border: 0x9D7185),
        neutralLow: ThemeColors(canvas: 0x171C17, surface: 0x252E25, ink: 0xE8EFE5,
                                secondary: 0xB9CAB5, accent: 0xA8BE9F, accentSoft: 0x33422F, border: 0x758A6E),
        neutralHigh: ThemeColors(canvas: 0x121E15, surface: 0x1D3022, ink: 0xE6F5E1,
                                 secondary: 0xB3CEAA, accent: 0xA0CE8C, accentSoft: 0x30462A, border: 0x718E65),
        positiveLow: ThemeColors(canvas: 0x131E1C, surface: 0x20312E, ink: 0xE2F3ED,
                                 secondary: 0xB0CEC4, accent: 0x93CABC, accentSoft: 0x2B463E, border: 0x668F82),
        positiveHigh: ThemeColors(canvas: 0x23160E, surface: 0x332317, ink: 0xFDEDD8,
                                  secondary: 0xDFC1A1, accent: 0xF6BC78, accentSoft: 0x533A22, border: 0xA38156))
}

private struct EnergyThemeKey: EnvironmentKey {
    static let defaultValue = EnergyThemePalette(state: .neutral, isDark: false)
}

extension EnvironmentValues {
    var energyTheme: EnergyThemePalette {
        get { self[EnergyThemeKey.self] }
        set { self[EnergyThemeKey.self] = newValue }
    }
}

/// 分开显示心情方向与精力鲜明程度，缺少记录时不显示虚构的等级。
struct StateThemeIndicator: View {
    @Environment(\.energyTheme) private var theme

    private var moodDescription: String {
        guard theme.state.hasMood else { return "未填写，暂用中性配色" }
        if theme.state.valence < -0.01 { return "消极方向" }
        if theme.state.valence > 0.01 { return "积极方向" }
        return "中性方向"
    }

    private var energyDescription: String {
        guard theme.state.hasEnergy else { return "未记录，暂用适中鲜明度" }
        if theme.state.vitality < 0.33 { return "较柔和" }
        if theme.state.vitality > 0.67 { return "更鲜明" }
        return "适中鲜明度"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "状态色谱", subtitle: "心情决定方向，精力调整鲜明程度")
            dimensionHeading("心情方向", value: moodDescription)
            spectrum(colors: [-1.0, -0.5, 0, 0.5, 1].map {
                EnergyThemePalette(state: StateThemeState(valence: $0, vitality: theme.state.vitality),
                                   isDark: theme.isDark, highContrast: theme.highContrast).accent
            }, fraction: (theme.state.valence + 1) / 2, isKnown: theme.state.hasMood)
            endpoints("消极", "积极")
            dimensionHeading("精力呈色", value: energyDescription)
            spectrum(colors: [0.0, 0.25, 0.5, 0.75, 1].map {
                EnergyThemePalette(state: StateThemeState(valence: theme.state.valence, vitality: $0),
                                   isDark: theme.isDark, highContrast: theme.highContrast).accent
            }, fraction: theme.state.vitality, isKnown: theme.state.hasEnergy)
            endpoints("柔和", "鲜明")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("状态色谱，心情和精力分别呈现")
        .accessibilityValue("心情方向，\(moodDescription)。精力呈色，\(energyDescription)。")
    }

    private func dimensionHeading(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(theme.ink)
            Spacer(minLength: 8)
            Text(value).font(.caption).foregroundStyle(theme.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func endpoints(_ leading: String, _ trailing: String) -> some View {
        HStack {
            Text(leading)
            Spacer()
            Text(trailing)
        }.font(.caption).foregroundStyle(theme.secondary)
    }

    private func spectrum(colors: [Color], fraction: Double, isKnown: Bool) -> some View {
        GeometryReader { proxy in
            let markerSize: CGFloat = 18
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 10)
                if isKnown {
                    Circle().fill(theme.surface)
                        .overlay(Circle().strokeBorder(theme.ink, lineWidth: 2.5))
                        .frame(width: markerSize, height: markerSize)
                        .offset(x: max(0, proxy.size.width - markerSize) * CGFloat(fraction))
                }
            }.frame(maxHeight: .infinity)
        }.frame(height: 22)
    }
}
