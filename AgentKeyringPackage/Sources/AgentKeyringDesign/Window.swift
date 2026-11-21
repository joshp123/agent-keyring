// Written by AI on 2026.11.21 by model claude opus 5.5, from boards 3 and 4
// of the Paper page "Agent Keyring (Holistic)".
//
// The frames of the everyday screens, so they set no margins or colours of
// their own: the main window's pane (a band at the top, the table or list,
// a bar at the bottom) and the menu bar's window.

import SwiftUI

/// A tab of the everyday window: a band at the top (the rules, the filter),
/// the content edge to edge (a system Table or List), and a bar at the bottom.
public struct KeyringPane<Top: View, Content: View, Bottom: View>: View {
    let top: Top
    let content: Content
    let bottom: Bottom

    public init(@ViewBuilder top: () -> Top, @ViewBuilder content: () -> Content, @ViewBuilder bottom: () -> Bottom) {
        self.top = top()
        self.content = content()
        self.bottom = bottom()
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: KeyringSpace.s4) { top }
                .padding(KeyringSpace.s5)
                .frame(maxWidth: .infinity, alignment: .leading)
            content
            Divider()
            HStack(spacing: KeyringSpace.s3) { bottom }
                .padding(.horizontal, KeyringSpace.s5)
                .padding(.vertical, KeyringSpace.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KeyringPalette.surface)
    }
}

extension KeyringPane where Bottom == EmptyView {
    public init(@ViewBuilder top: () -> Top, @ViewBuilder content: () -> Content) {
        self.init(top: top, content: content) { EmptyView() }
    }
}

/// The window under the menu bar's keyhole: its header, then sections, then its buttons.
public struct KeyringMenuBarWindow<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(alignment: .leading, spacing: KeyringSpace.s3) { content }
            .padding(KeyringSpace.s4)
            .background(KeyringPalette.sidebar)
    }

    /// The width board 4 draws it at; the app's window sets the real one.
    public static var width: CGFloat { 360 }
}

/// A named group of rows: "WAITING FOR YOU", "EARLIER TODAY", "OTHER COMPUTERS".
public struct KeyringSection<Rows: View>: View {
    let name: String
    let rows: Rows

    public init(_ name: String, @ViewBuilder rows: () -> Rows) {
        self.name = name
        self.rows = rows()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: KeyringSpace.s1) {
            KeyringText(name, as: .sectionName)
            KeyringRowGroup { rows }
        }
    }
}

/// A short state in a pill: "1 waiting", "All quiet", "Offline", "Connected".
public struct KeyringPill: View {
    public enum Tone: Sendable {
        /// Something waits for him: Keyring blue.
        case waiting
        /// All is well: green.
        case calm
        /// Cannot reach something: orange.
        case offline
    }

    let words: String
    let tone: Tone

    public init(_ words: String, tone: Tone) {
        self.words = words
        self.tone = tone
    }

    public var body: some View {
        KeyringText(words, as: .caption, colour: ink)
            .padding(.horizontal, KeyringSpace.s2)
            .padding(.vertical, 2)
            .background(tint, in: .capsule)
    }

    private var ink: Color {
        switch tone {
        case .waiting: KeyringPalette.brand
        case .calm: KeyringPalette.approve
        case .offline: KeyringPalette.stalled
        }
    }

    private var tint: Color {
        switch tone {
        case .waiting: KeyringPalette.brandTint
        case .calm: KeyringPalette.approveTint
        case .offline: KeyringPalette.stalledTint
        }
    }
}

/// A word beside a name that marks it: "Test password".
public struct KeyringTag: View {
    let words: String
    public init(_ words: String) { self.words = words }

    public var body: some View {
        KeyringText(words, as: .caption, colour: KeyringPalette.brand)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(KeyringPalette.brandTint, in: .rect(cornerRadius: 4))
    }
}
