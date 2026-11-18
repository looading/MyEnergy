import SwiftUI
import MyEnergyCore

struct EnergyCard<Content: View>: View {
    @Environment(\.energyTheme) private var theme
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content.padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(theme.border.opacity(0.65), lineWidth: 1))
    }
}

struct SectionHeading: View {
    @Environment(\.energyTheme) private var theme
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(theme.ink)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(theme.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct StatusPill: View {
    @Environment(\.energyTheme) private var theme
    let text: String
    var symbol: String = "internaldrive"

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium)).foregroundStyle(theme.secondary)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(theme.accentSoft.opacity(0.6), in: Capsule())
    }
}

struct EmptyState: View {
    @Environment(\.energyTheme) private var theme
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(theme.accent)
                .frame(width: 68, height: 68).background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 24))
            Text(title).font(.headline).foregroundStyle(theme.ink)
            Text(message).font(.subheadline).foregroundStyle(theme.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}

struct InlineError: View {
    @Environment(\.energyTheme) private var theme
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout).foregroundStyle(theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("操作未完成。\(message)")
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.energyTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(theme.onAccent)
            .background(theme.accent, in: RoundedRectangle(cornerRadius: 15))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
    }
}

struct EnergyRing: View {
    @Environment(\.energyTheme) private var theme
    let value: Int?
    var size: CGFloat = 170

    var body: some View {
        ZStack {
            Circle().stroke(theme.accentSoft, lineWidth: 12)
            if let value {
                Circle().trim(from: 0, to: max(0.006, Double(value) / 100))
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                if let value {
                    Text("\(value)").font(.system(size: size * 0.31, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("/ 100").font(.caption).foregroundStyle(theme.secondary)
                } else {
                    Image(systemName: "leaf").font(.system(size: size * 0.26, weight: .ultraLight))
                    Text("从此刻开始").font(.caption).padding(.top, 8)
                }
            }.foregroundStyle(theme.ink)
        }.frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(value.map { "主观精力，\($0)，满分 100" } ?? "尚未记录主观精力")
    }
}

/// 五种表情独立于精力选择，不使用红绿灯等级。
struct MoodGlyph: View {
    @Environment(\.energyTheme) private var theme
    let mood: Mood
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().fill(theme.accentSoft)
            FaceLines(mood: mood).stroke(theme.ink, style: StrokeStyle(lineWidth: size / 25, lineCap: .round))
                .padding(size * 0.20)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct FaceLines: Shape {
    let mood: Mood

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        for x in [0.28, 0.72] {
            if mood == .veryGood {
                path.move(to: CGPoint(x: w * (x - 0.08), y: h * 0.38))
                path.addQuadCurve(to: CGPoint(x: w * (x + 0.08), y: h * 0.38), control: CGPoint(x: w * x, y: h * 0.21))
            } else {
                path.move(to: CGPoint(x: w * x, y: h * 0.30))
                path.addLine(to: CGPoint(x: w * x, y: h * 0.38))
            }
        }
        let curve: Double
        switch mood {
        case .veryLow: curve = 0.44
        case .low: curve = 0.57
        case .neutral: curve = 0.73
        case .good: curve = 0.95
        case .veryGood: curve = 1.10
        }
        path.move(to: CGPoint(x: w * 0.24, y: h * 0.73))
        path.addQuadCurve(to: CGPoint(x: w * 0.76, y: h * 0.73), control: CGPoint(x: w * 0.50, y: h * curve))
        if mood == .veryLow {
            path.move(to: CGPoint(x: w * 0.16, y: h * 0.19))
            path.addLine(to: CGPoint(x: w * 0.37, y: h * 0.12))
            path.move(to: CGPoint(x: w * 0.63, y: h * 0.12))
            path.addLine(to: CGPoint(x: w * 0.84, y: h * 0.19))
        }
        return path
    }
}

extension Date {
    var energyDate: String { formatted(.dateTime.month(.wide).day().weekday(.wide)) }
    var energyTime: String { formatted(date: .omitted, time: .shortened) }
}
