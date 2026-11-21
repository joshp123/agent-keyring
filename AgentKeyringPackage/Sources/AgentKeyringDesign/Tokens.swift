// Written by AI on 2026.11.21 by model claude opus 5.5, from the design tokens
// in the Paper file "Agent Keyring" (board 5, "Design System").
//
// Every colour, space, radius and size the parts use. Pages never use a raw
// number: margins and spacing belong to the page part, never to its content.

import SwiftUI

/// The design's colours. Light and dark on Mac and iPhone; the Watch is always dark.
public enum KeyringPalette {
    public static let surface = Color(light: 0xFFFFFF, dark: 0x1C1C1E)
    /// Main text: titles, the site, the agent's reason.
    public static let ink = Color(light: 0x0B0B0C, dark: 0xFFFFFF)
    /// Secondary text: sentences, who is asking, the account.
    public static let ink2 = Color(light: 0x5F5F67, dark: 0xA6A6AE)
    /// Steps not started; disabled text.
    public static let ink3 = Color(light: 0xA1A1A8, dark: 0x6E6E76)
    /// Neutral fills: cards, the reply box.
    public static let fill = Color(light: 0xEEEEF1, dark: 0x2E2E31)
    public static let line = Color(light: 0xE1E1E6, dark: 0x3A3A3D)
    /// The Mac setup window's step list.
    public static let sidebar = Color(light: 0xF4F4F6, dark: 0x232326)
    /// Green means approve and nothing else.
    public static let approve = Color(light: 0x17853F, dark: 0x23A455)
    /// Red means deny and nothing else.
    public static let deny = Color(light: 0xD5302A, dark: 0xE5453D)
    public static let onAnswer = Color.white
    /// Keyring blue: moves setup on, marks the current step, links.
    public static let brand = Color(light: 0x1447E6, dark: 0x5B8CFF)
    /// The current step's row; the hand-over card.
    public static let brandTint = Color(light: 0xE6ECFD, dark: 0x1D2B52)
    /// A waiting line that has waited too long; a checklist item that is off.
    public static let stalled = Color(light: 0xC25E00, dark: 0xFF9F43)
    public static let stalledTint = Color(light: 0xFFF4E6, dark: 0x3A2A16)
    /// The Focus hint.
    public static let focus = Color(light: 0x5B3FD1, dark: 0x9C88FF)
    public static let focusTint = Color(light: 0xEEEAFB, dark: 0x2A2440)
    public static let approveTint = Color(light: 0xEAF6EE, dark: 0x16301F)
    public static let denyTint = Color(light: 0xFDECEB, dark: 0x3A1A18)
}

/// Paper's spacing scale, by its own names: `s4` is `--spacing-4`, 16 pt.
public enum KeyringSpace {
    public static let s1: CGFloat = 4
    public static let s2: CGFloat = 8
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16
    public static let s5: CGFloat = 20
    public static let s6: CGFloat = 24
    public static let s8: CGFloat = 32
    public static let s10: CGFloat = 40
}

public enum KeyringRadius {
    /// Cards inside a page: copy block, hint, step group.
    public static let card: CGFloat = 12
    /// The request on the Mac.
    public static let panel: CGFloat = 18
}

/// The sizes the checks host every part and page at: the smallest each device gives.
public enum KeyringSize {
    /// The Mac setup window.
    public static let macWindow = CGSize(width: 760, height: 560)
    /// The setup window's step list.
    public static let macSidebar: CGFloat = 226
    /// The Mac approval card.
    public static let macCard: CGFloat = 360
    /// Longest line of body text on a Mac page.
    public static let measure: CGFloat = 460
    /// The smallest supported iPhone (iPhone SE, 13 mini).
    public static let phone = CGSize(width: 375, height: 667)
    /// Apple Watch 41 mm.
    public static let watch = CGSize(width: 176, height: 215)
    static let macPageMargin: CGFloat = 40
    static let phoneMargin: CGFloat = 24
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        #if os(iOS)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #elseif os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #else
        self.init(hex: dark)
        #endif
    }

    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

#if os(iOS)
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#elseif os(macOS)
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif
