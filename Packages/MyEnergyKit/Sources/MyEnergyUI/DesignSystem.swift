import SwiftUI
import MyEnergyCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum EnergyStyle {
    static let canvas = adaptive(light: (0.973, 0.969, 0.937), dark: (0.071, 0.102, 0.086))
    static let surface = adaptive(light: (1, 1, 0.985), dark: (0.114, 0.153, 0.129))
    static let ink = adaptive(light: (0.110, 0.180, 0.141), dark: (0.898, 0.941, 0.898))
    static let secondary = adaptive(light: (0.325, 0.384, 0.345), dark: (0.678, 0.769, 0.698))
    static let forest = adaptive(light: (0.184, 0.384, 0.290), dark: (0.588, 0.800, 0.631))
    static let sage = adaptive(light: (0.863, 0.914, 0.847), dark: (0.184, 0.282, 0.208))
    static let line = adaptive(light: (0.843, 0.871, 0.831), dark: (0.255, 0.337, 0.275))

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        #if os(watchOS)
        Color(red: dark.0, green: dark.1, blue: dark.2)
        #elseif canImport(UIKit)
        Color(UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
        #elseif canImport(AppKit)
        Color(NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
        #else
        Color(red: dark.0, green: dark.1, blue: dark.2)
        #endif
    }
}

struct EnergyCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content.padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(EnergyStyle.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(EnergyStyle.line.opacity(0.65), lineWidth: 1))
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(EnergyStyle.ink)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(EnergyStyle.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct StatusPill: View {
    let text: String
    var symbol: String = "internaldrive"

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium)).foregroundStyle(EnergyStyle.secondary)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(EnergyStyle.sage.opacity(0.6), in: Capsule())
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(EnergyStyle.forest)
                .frame(width: 68, height: 68).background(EnergyStyle.sage, in: RoundedRectangle(cornerRadius: 24))
            Text(title).font(.headline).foregroundStyle(EnergyStyle.ink)
            Text(message).font(.subheadline).foregroundStyle(EnergyStyle.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}

struct InlineError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("操作未完成。\(message)")
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(EnergyStyle.surface)
            .background(EnergyStyle.forest.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 15))
    }
}

struct EnergyRing: View {
    let value: Int?
    var size: CGFloat = 170

    var body: some View {
        ZStack {
            Circle().stroke(EnergyStyle.sage, lineWidth: 12)
            if let value {
                Circle().trim(from: 0, to: max(0.006, Double(value) / 100))
                    .stroke(EnergyStyle.forest, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                if let value {
                    Text("\(value)").font(.system(size: size * 0.31, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("/ 100").font(.caption).foregroundStyle(EnergyStyle.secondary)
                } else {
                    Image(systemName: "leaf").font(.system(size: size * 0.26, weight: .ultraLight))
                    Text("从此刻开始").font(.caption).padding(.top, 8)
                }
            }.foregroundStyle(EnergyStyle.ink)
        }.frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(value.map { "主观精力，\($0)，满分 100" } ?? "尚未记录主观精力")
    }
}

/// 五种表情独立于精力选择，不使用红绿灯等级。
struct MoodGlyph: View {
    let mood: Mood
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().fill(EnergyStyle.sage)
            FaceLines(mood: mood).stroke(EnergyStyle.ink, style: StrokeStyle(lineWidth: size / 25, lineCap: .round))
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
