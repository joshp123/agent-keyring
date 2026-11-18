// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The iPhone's colours, from the tokens in the Paper file "Agent Keyring"
// (board "Design tokens"). Sizes are Dynamic Type styles whose default
// sizes are Paper's: 34 large title, 28 title, 20 title 3, 17 body,
// 15 subheadline, 13 footnote.

#if os(iOS)
import SwiftUI

enum Phone {
    static let ink = Color(light: 0x0B0B0C, dark: 0xFFFFFF)
    static let ink2 = Color(light: 0x5F5F67, dark: 0xA6A6AE)
    static let fill = Color(light: 0xEEEEF1, dark: 0x2E2E31)
    static let line = Color(light: 0xE1E1E6, dark: 0x3A3A3D)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1C1C1E)
    /// Behind grouped lists. Paper draws only the light list (fill); dark uses black, as iOS does.
    static let page = Color(light: 0xEEEEF1, dark: 0x000000)
    static let approve = Color(light: 0x17853F, dark: 0x23A455)
    static let deny = Color(light: 0xD5302A, dark: 0xE5453D)
    static let noAnswer = Color(light: 0xB4B4BC, dark: 0x6E6E76)
    static let onAnswer = Color.white
}

/// A pill-shaped button filled with one colour, 52 pt or 50 pt high.
struct PillButtonStyle: ButtonStyle {
    let fill: Color
    var text: Color = Phone.onAnswer
    var height: CGFloat = 52
    /// Full width, or the label's width with 20 pt either side.
    var stretches = true

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, fill: fill, text: text, height: height, stretches: stretches)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let fill: Color
        let text: Color
        let height: CGFloat
        let stretches: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(text)
                .padding(.horizontal, stretches ? 0 : 20)
                .frame(minHeight: height)
                .frame(maxWidth: stretches ? .infinity : nil)
                .background(fill, in: .capsule)
                .opacity(configuration.isPressed ? 0.8 : (isEnabled ? 1 : 0.4))
                .contentShape(.capsule)
        }
    }
}

/// The small 34 pt capsule at the end of a list row: Show, Stop.
struct RowButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(fill, in: .capsule)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Agent Keyring's keyhole, drawn from the icon's shapes in Paper.
struct KeyholeIcon: View {
    var size: CGFloat

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 100
            let rect = CGRect(x: 0, y: 0, width: 100 * s, height: 100 * s)
            context.fill(Path(roundedRect: rect, cornerRadius: 22.5 * s, style: .continuous),
                         with: .linearGradient(Gradient(colors: [Color(rgb: 0x2F62F5), Color(rgb: 0x1040D8)]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: 100 * s)))
            context.fill(Path(ellipseIn: CGRect(x: 28.5 * s, y: 17 * s, width: 43 * s, height: 43 * s)), with: .color(.white))
            var body = Path()
            body.move(to: CGPoint(x: 40.2 * s, y: 51.5 * s))
            body.addLine(to: CGPoint(x: 59.8 * s, y: 51.5 * s))
            body.addLine(to: CGPoint(x: 67.2 * s, y: 81.9 * s))
            body.addQuadCurve(to: CGPoint(x: 64.1 * s, y: 85.9 * s), control: CGPoint(x: 67.8 * s, y: 85.9 * s))
            body.addLine(to: CGPoint(x: 35.9 * s, y: 85.9 * s))
            body.addQuadCurve(to: CGPoint(x: 32.8 * s, y: 81.9 * s), control: CGPoint(x: 32.2 * s, y: 85.9 * s))
            body.closeSubpath()
            context.fill(body, with: .color(.white))
            for x in [46.3, 60.0] {
                context.fill(Path(ellipseIn: CGRect(x: (x - 4.9) * s, y: 32.6 * s, width: 9.8 * s, height: 9.8 * s)),
                             with: .color(Color(rgb: 0x0B1B4D)))
                context.fill(Path(ellipseIn: CGRect(x: (x + 1.47 - 1.764) * s, y: (35.932 - 1.764) * s,
                                                    width: 3.528 * s, height: 3.528 * s)),
                             with: .color(.white.opacity(0.9)))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}
#endif
