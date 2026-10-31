// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The whole visual language: three colours that each mean one thing, SF type
// at Dynamic Type sizes, hairlines instead of cards. Change a value here and
// every screen follows.

import SwiftUI

public enum KeyringColour {
    /// Approve, and logins agents may use. White text on it passes WCAG AA.
    public static let approve = Color(light: 0x1A7F37, dark: 0x238636)
    /// Deny, block, and anything that stops an agent.
    public static let deny = Color(light: 0xCF222E, dark: 0xDA3633)
    /// Agent Keyring itself: waiting, timers, links.
    public static let signal = Color(light: 0x0A4BD6, dark: 0x4C8DFF)
    /// The same meanings as text. Brighter in dark mode, where the fills are too dim to read.
    public static let approveText = Color(light: 0x1A7F37, dark: 0x3FB950)
    public static let denyText = Color(light: 0xCF222E, dark: 0xFF6A69)
}

public enum KeyringMetric {
    public static let margin: CGFloat = 20
    public static let factLabelWidth: CGFloat = 76
    public static let buttonHeight: CGFloat = 52
    public static let buttonCorner: CGFloat = 14
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        #if os(iOS)
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
        #endif
    }
}

#if os(iOS)
extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#else
extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// The colour that goes with an outcome word. Nil means plain secondary text.
public func outcomeColour(_ state: AccessRequestState) -> Color? {
    switch state {
    case .approved, .released: KeyringColour.approveText
    case .denied, .blockedByRule: KeyringColour.denyText
    case .waitingForYou, .sendingAnswer: KeyringColour.signal
    case .unanswered, .cancelled, .expired, .ended: nil
    }
}

/// The symbol that goes with an outcome sentence.
public func outcomeSymbol(_ state: AccessRequestState) -> String {
    switch state {
    case .approved, .released: "checkmark.circle.fill"
    case .denied, .blockedByRule: "xmark.circle.fill"
    case .waitingForYou, .sendingAnswer: "clock"
    case .unanswered, .cancelled, .expired, .ended: "clock.badge.xmark"
    }
}

/// A 0.5 pt rule, the only divider the screens use.
public struct Hairline: View {
    public init() {}
    public var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

/// Filled, full-width, strongly coloured: Approve and Deny. With a quiet
/// fill and coloured text for the secondary answers (End now, Done).
public struct DecisionButtonStyle: ButtonStyle {
    let colour: Color
    let text: Color
    let height: CGFloat

    public init(colour: Color, text: Color = .white, height: CGFloat = KeyringMetric.buttonHeight) {
        self.colour = colour
        self.text = text
        self.height = height
    }

    public func makeBody(configuration: Configuration) -> some View {
        DecisionButtonBody(configuration: configuration, colour: colour, text: text, height: height)
    }

    private struct DecisionButtonBody: View {
        let configuration: Configuration
        let colour: Color
        let text: Color
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(text)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(colour.opacity(isEnabled ? 1 : 0.35),
                    in: .rect(cornerRadius: KeyringMetric.buttonCorner, style: .continuous))
                .opacity(configuration.isPressed ? 0.8 : 1)
                .contentShape(.rect)
        }
    }
}

extension ButtonStyle where Self == DecisionButtonStyle {
    /// A light fill with coloured text, for the answers that aren't Approve or Deny.
    public static func quiet(text: Color = .primary, height: CGFloat = KeyringMetric.buttonHeight) -> Self {
        DecisionButtonStyle(colour: Color.primary.opacity(0.08), text: text, height: height)
    }
}
