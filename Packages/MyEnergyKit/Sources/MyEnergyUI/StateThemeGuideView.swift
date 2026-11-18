#if !os(watchOS)
import SwiftUI

/// 说明心情与精力怎样分别影响配色；示例只展示颜色，不修改记录。
struct StateThemeGuideView: View {
    @Environment(\.energyTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var sampleColumns: [GridItem] {
        #if os(iOS)
        if sizeClass == .compact { return [GridItem(.flexible())] }
        #endif
        if typeSize.isAccessibilitySize { return [GridItem(.flexible())] }
        return [GridItem(.adaptive(minimum: 248), spacing: 12, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: "状态主题", subtitle: "心情决定色彩倾向，精力独立改变鲜明程度")
            Text("低精力时也能心情很好，精力充沛时也可能低落。两项记录各自保留，颜色只是它们的视觉表达。")
                .font(.callout).foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Text("配色示例").font(.subheadline.weight(.semibold)).foregroundStyle(theme.ink)
                LazyVGrid(columns: sampleColumns, alignment: .leading, spacing: 12) {
                    sample(title: "平静的好心情", detail: "心情好 · 精力低", symbol: "leaf", valence: 1, vitality: 0)
                    sample(title: "活跃的好心情", detail: "心情好 · 精力高", symbol: "sun.max", valence: 1, vitality: 1)
                    sample(title: "低落且疲惫", detail: "心情低落 · 精力低", symbol: "cloud", valence: -1, vitality: 0)
                    sample(title: "低落但有精力", detail: "心情低落 · 精力高", symbol: "cloud.sun", valence: -1, vitality: 1)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(currentStateDescription)
                    .font(.callout).foregroundStyle(theme.ink)
                Text("主题使用最近 24 小时内的主观记录，编辑时会临时预览。未填写心情时保留中性色彩倾向；身体参考不参与心情配色。")
                    .font(.footnote).foregroundStyle(theme.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var currentStateDescription: String {
        switch (theme.state.hasMood, theme.state.hasEnergy) {
        case (true, true): "当前主题随你填写的心情和精力变化。"
        case (false, true): "当前心情未填写，颜色只随精力调整鲜明程度。"
        case (true, false): "当前精力未知，颜色采用中等鲜明度，并保留心情的色彩倾向。"
        case (false, false): "当前没有可用的主观记录，使用中性主题。"
        }
    }

    private func sample(title: String, detail: String, symbol: String, valence: Double, vitality: Double) -> some View {
        let palette = EnergyThemePalette(
            state: StateThemeState(valence: valence, vitality: vitality),
            isDark: colorScheme == .dark,
            highContrast: contrast == .increased)
        return VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.caption).foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Capsule().fill(LinearGradient(colors: [palette.accentSoft, palette.accent],
                                         startPoint: .leading, endPoint: .trailing))
                .frame(height: 10).accessibilityHidden(true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.canvas, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(palette.border, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("配色示例，\(title)。\(detail)。")
    }
}
#endif
