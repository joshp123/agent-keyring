// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// Every button is a system button. Its colour says what it does: blue moves
// setup on, green approves, red denies, and nothing else is coloured.

import SwiftUI

/// A button's words, what it means and what it does.
public struct KeyringAction {
    public enum Kind: Sendable {
        /// Blue: moves setup on (Continue, Get Started, Send Practice Request).
        case advance
        /// Green: approves a request or a device, and nothing else.
        case approve
        /// Red: denies, and nothing else.
        case deny
        /// Grey: everything else (Back, Cancel, Not Now, Copy).
        case plain
        /// Text only: a way out or a help link (Having trouble?, Skip for Now).
        case link
    }

    public let title: String
    public let kind: Kind
    public let isEnabled: Bool
    public let perform: () -> Void

    public init(_ title: String, _ kind: Kind = .plain, isEnabled: Bool = true, perform: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.isEnabled = isEnabled
        self.perform = perform
    }

    public static func advance(_ title: String, isEnabled: Bool = true, perform: @escaping () -> Void) -> Self { .init(title, .advance, isEnabled: isEnabled, perform: perform) }
    public static func approve(_ title: String, isEnabled: Bool = true, perform: @escaping () -> Void) -> Self { .init(title, .approve, isEnabled: isEnabled, perform: perform) }
    public static func deny(_ title: String, isEnabled: Bool = true, perform: @escaping () -> Void) -> Self { .init(title, .deny, isEnabled: isEnabled, perform: perform) }
    public static func plain(_ title: String, isEnabled: Bool = true, perform: @escaping () -> Void) -> Self { .init(title, .plain, isEnabled: isEnabled, perform: perform) }
    public static func link(_ title: String, isEnabled: Bool = true, perform: @escaping () -> Void) -> Self { .init(title, .link, isEnabled: isEnabled, perform: perform) }
}

extension EnvironmentValues {
    /// Set by the part a button sits in: a page's or card's buttons on iPhone and Watch take the full width.
    @Entry var keyringButtonsFill = false
}

/// A system button for one `KeyringAction`.
public struct KeyringButton: View {
    let action: KeyringAction

    @Environment(\.keyringAudit) private var audit
    @Environment(\.keyringButtonsFill) private var fills
    @State private var id = UUID()

    public init(_ action: KeyringAction) { self.action = action }

    public init(_ title: String, _ kind: KeyringAction.Kind = .plain, isEnabled: Bool = true, perform: @escaping () -> Void) {
        self.action = KeyringAction(title, kind, isEnabled: isEnabled, perform: perform)
    }

    public var body: some View {
        styled(Button(action: action.perform) {
            KeyringText(action.title, as: .label)
                .multilineTextAlignment(.center)
                .frame(maxWidth: fills && action.kind != .link ? .infinity : nil)
                .environment(\.keyringAuditOwner, id)
        })
        .disabled(!action.isEnabled)
        .reportsPlacement(.init(id: id, kind: .button, label: action.title, owner: nil), to: audit)
    }

    @ViewBuilder private func styled(_ button: Button<some View>) -> some View {
        switch action.kind {
        case .advance: prominent(button, KeyringPalette.brand)
        case .approve: prominent(button, KeyringPalette.approve)
        case .deny: prominent(button, KeyringPalette.deny)
        case .plain: button.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(Self.size)
        case .link:
            #if os(watchOS)
            button.buttonStyle(.plain).foregroundStyle(KeyringPalette.brand)
            #else
            button.buttonStyle(.borderless).tint(KeyringPalette.brand).controlSize(Self.size)
            #endif
        }
    }

    private func prominent(_ button: Button<some View>, _ colour: Color) -> some View {
        button.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(colour).controlSize(Self.size)
    }

    private static var size: ControlSize {
        #if os(watchOS)
        .regular
        #else
        .large
        #endif
    }
}
