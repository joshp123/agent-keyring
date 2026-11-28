// Written by AI on 2026.11.26 by model gemini-4-neon, from Josh's 16 Nov bookmark
// of Allo (github.com/joshpuckett/allo, SIL OFL 1.1) and Core Text verification.
//
// Registers the bundled AlloVariable.ttf once per process and maps every UI role
// to its exact PostScript name (asking Core Text for "Allo" silently returns
// Helvetica, so we always request the verified PostScript names directly).

import CoreText
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

public enum KeyringFont {
    public enum PostScript {
        public static let regular = "AlloVariable-Regular"
        public static let medium = "AlloVariable-Medium"
        public static let semibold = "AlloVariable-SemiBold"
        public static let bold = "AlloVariable-Bold"
        public static let displayMedium = "AlloVariable-DisplayMedium"
        public static let displaySemibold = "AlloVariable-DisplaySemiBold"
        public static let displayBold = "AlloVariable-DisplayBold"
    }

    /// Registers `AlloVariable.ttf` from `AgentKeyringDesign`'s bundle once per process.
    @discardableResult
    public static func register() -> Bool {
        _registered
    }

    private static let _registered: Bool = {
        guard let url = Bundle.module.url(forResource: "AlloVariable", withExtension: "ttf") else {
            return false
        }
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if ok { return true }
        // Already registered in this process is fine.
        if let cfError = error?.takeRetainedValue(),
           CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue {
            return true
        }
        return false
    }()

    /// Fixed-size Allo font (macOS desktop metrics).
    public static func fixed(_ psName: String, size: CGFloat) -> Font {
        _ = register()
        return .custom(psName, fixedSize: size)
    }

    /// Dynamic-Type-scaling Allo font (iPhone and Apple Watch).
    public static func scaled(_ psName: String, size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        _ = register()
        return .custom(psName, size: size, relativeTo: style)
    }

    #if os(iOS)
    /// Styles UIKit-owned navigation bar titles and tab bar labels in Allo so iOS chrome
    /// matches the SwiftUI views inside them (system alerts and Face ID sheets stay native).
    @MainActor
    public static func configureNavigationAppearance() {
        _ = register()
        let largeTitle = UIFont(name: PostScript.displayBold, size: 34)
            ?? UIFont.systemFont(ofSize: 34, weight: .bold)
        let inlineTitle = UIFont(name: PostScript.semibold, size: 17)
            ?? UIFont.systemFont(ofSize: 17, weight: .semibold)
        let navAppearance = UINavigationBar.appearance()
        navAppearance.largeTitleTextAttributes = [.font: largeTitle]
        navAppearance.titleTextAttributes = [.font: inlineTitle]

        let tabFont = UIFont(name: PostScript.medium, size: 10)
            ?? UIFont.systemFont(ofSize: 10, weight: .medium)
        UITabBarItem.appearance().setTitleTextAttributes([.font: tabFont], for: .normal)
        UITabBarItem.appearance().setTitleTextAttributes([.font: tabFont], for: .selected)
    }
    #endif
}
