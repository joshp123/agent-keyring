// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// Every button is a system button. Its colour says what it does: blue moves
// setup on, green approves, red denies, and nothing else is coloured.

import SwiftUI

public enum KeyringActionKind: Sendable {
    /// Blue: moves setup on (Continue, Get Started, Send Practice Request).
    case advance
    /// Green: approves a request or a device, and nothing else.
    case approve
    /// Red: denies, and nothing else.
    case deny
    /// Red bordered button: equal contrast to Deny for "Deny & Reply".
    case denySecondary
    /// Destructive bordered button (e.g. Reset on Mac Settings).
    case destructive
    /// Grey: everything else (Back, Cancel, Not Now, Copy).
    case plain
    /// Text only: a way out or a help link (Having trouble?, Skip for Now).
    case link
    /// Green text: a quiet way to approve.
    case approveLink
    /// Red text: a quiet way to deny.
    case denyLink
}

/// A button's words, what it means and what it does.
public struct KeyringAction {

    public let title: String
    public let symbol: String?
    public let kind: KeyringActionKind
    public let isEnabled: Bool
    public let perform: () -> Void
    /// Set for an action that asks for words first: the prompt, and what to do with the words.
    let words: (prompt: String, send: (String) -> Void)?

    public init(_ title: String, _ kind: KeyringActionKind = .plain, symbol: String? = nil, isEnabled: Bool = true, perform: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.kind = kind
        self.isEnabled = isEnabled
        self.perform = perform
        self.words = nil
    }

    #if os(watchOS)
    /// Deny and Explain on the Watch: opens watchOS's own text input (dictation,
    /// Scribble or the keyboard) with `prompt`, then sends what he said. Nothing
    /// is sent if he says nothing.
    public static func explain(_ title: String, prompt: String, isEnabled: Bool = true, send: @escaping (String) -> Void) -> Self {
        .init(title: title, prompt: prompt, isEnabled: isEnabled, send: send)
    }

    private init(title: String, prompt: String, isEnabled: Bool, send: @escaping (String) -> Void) {
        self.title = title
        self.symbol = nil
        self.kind = .plain
        self.isEnabled = isEnabled
        self.perform = {}
        self.words = (prompt, send)
    }
    #endif

    public static func advance(_ title: String, isEnabled: Bool = true, perform: @escaping () -> Void) -> Self { .init(title, .advance, isEnabled: isEnabled, perform: perform) }
    public static func approve(_ title: String, symbol: String? = nil, isEnabled: Bool = true, perform: @escaping () -> Void) -> Self { .init(title, .approve, symbol: symbol, isEnabled: isEnabled, perform: perform) }
    public static func deny(_ title: String, isEnabled: Bool = true, perform: @escaping () -> Void) -> Self { .init(title, .deny, isEnabled: isEnabled, perform: perform) }
    public static func denySecondary(_ title: String, isEnabled: Bool = true, perform: @escaping () -> Void) -> Self { .init(title, .denySecondary, isEnabled: isEnabled, perform: perform) }
    public static func destructive(_ title: String, isEnabled: Bool = true, perform: @escaping () -> Void) -> Self { .init(title, .destructive, isEnabled: isEnabled, perform: perform) }
    public static func plain(_ title: String, isEnabled: Bool = true, perform: @escaping () -> Void) -> Self { .init(title, .plain, isEnabled: isEnabled, perform: perform) }
    public static func link(_ title: String, isEnabled: Bool = true, perform: @escaping () -> Void) -> Self { .init(title, .link, isEnabled: isEnabled, perform: perform) }
    public static func approveLink(_ title: String, isEnabled: Bool = true, perform: @escaping () -> Void) -> Self { .init(title, .approveLink, isEnabled: isEnabled, perform: perform) }
    public static func denyLink(_ title: String, isEnabled: Bool = true, perform: @escaping () -> Void) -> Self { .init(title, .denyLink, isEnabled: isEnabled, perform: perform) }
}

extension EnvironmentValues {
    /// Set by the part a button sits in: a page's or card's buttons on iPhone and Watch take the full width.
    @Entry public var keyringButtonsFill = false
    /// Set by ApprovalCard on macOS so Deny, Approve and the reply input share one matched height.
    @Entry public var keyringButtonTall = false
}

/// A system button for one `KeyringAction`.
public struct KeyringButton: View {
    let action: KeyringAction

    @Environment(\.keyringAudit) private var audit
    @Environment(\.keyringButtonsFill) private var fills
    @Environment(\.keyringButtonTall) private var tall
    @State private var id = UUID()

    public init(_ action: KeyringAction) { self.action = action }

    public init(_ title: String, _ kind: KeyringActionKind = .plain, isEnabled: Bool = true, perform: @escaping () -> Void) {
        self.action = KeyringAction(title, kind, isEnabled: isEnabled, perform: perform)
    }

    public var body: some View {
        control
            .disabled(!action.isEnabled)
            .reportsPlacement(.init(id: id, kind: .button, label: action.title, owner: nil), to: audit)
    }

    @ViewBuilder private var control: some View {
        #if os(watchOS)
        if let words = action.words {
            TextFieldLink(prompt: Text(words.prompt)) { label } onSubmit: { said in
                let trimmed = said.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { words.send(trimmed) }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        } else {
            styled(Button(action: action.perform) { label })
        }
        #else
        styled(Button(action: action.perform) { label })
        #endif
    }

    private var label: some View {
        HStack(spacing: 6) {
            if let symbol = action.symbol {
                Image(systemName: symbol)
                    .font(.system(size: Self.symbolSize, weight: .medium))
                    .accessibilityHidden(true)
            }
            KeyringText(action.title, as: .label)
                .multilineTextAlignment(.center)
        }
        #if os(macOS)
        .padding(.vertical, tall && !isTextOnly ? 5 : 0)
        #endif
        .frame(maxWidth: fills && !isTextOnly ? .infinity : nil)
        .environment(\.keyringAuditOwner, id)
    }

    @ViewBuilder private func styled(_ button: Button<some View>) -> some View {
        switch action.kind {
        case .advance: prominent(button, KeyringPalette.brand)
        case .approve: prominent(button, KeyringPalette.approve)
        case .deny: prominent(button, KeyringPalette.deny)
        case .denySecondary:
            // High-contrast bordered red circular pill (WCAG AA >= 5.5:1 in both light and dark).
            // Uses `.circular` Capsule with `.inset(by:)` to avoid macOS 27 continuous-squircle stroke artifacts.
            Button(action: action.perform) {
                label
                    .foregroundStyle(KeyringPalette.denyText)
                    .padding(.horizontal, Self.borderedHorizontalPadding)
                    .padding(.vertical, Self.borderedVerticalPadding)
                    .background(Capsule(style: .circular).fill(KeyringPalette.surface))
                    .overlay(
                        Capsule(style: .circular)
                            .inset(by: 0.75)
                            .stroke(KeyringPalette.deny.opacity(0.75), lineWidth: 1.25)
                    )
                    .contentShape(Capsule(style: .circular))
            }
            .buttonStyle(.plain)
        case .destructive:
            Button(role: .destructive, action: action.perform) {
                label
                    .foregroundStyle(KeyringPalette.denyText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule(style: .circular).fill(KeyringPalette.surface))
                    .overlay(
                        Capsule(style: .circular)
                            .inset(by: 0.6)
                            .stroke(KeyringPalette.deny.opacity(0.65), lineWidth: 1)
                    )
                    .contentShape(Capsule(style: .circular))
            }
            .buttonStyle(.plain)
        case .plain: button.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(controlSize)
        case .link: textOnly(button, KeyringPalette.brand)
        case .approveLink: textOnly(button, KeyringPalette.approve)
        case .denyLink: textOnly(button, KeyringPalette.denyText)
        }
    }

    @ViewBuilder private func textOnly(_ button: Button<some View>, _ colour: Color) -> some View {
        #if os(watchOS)
        button.buttonStyle(.plain).foregroundStyle(colour)
        #else
        button.buttonStyle(.borderless).tint(colour).controlSize(controlSize)
        #endif
    }

    private func prominent(_ button: Button<some View>, _ colour: Color) -> some View {
        button.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(colour).controlSize(controlSize)
        #if os(macOS)
            // macOS greys a prominent button in a window that is not key, and
            // the approval panel never takes key on its own: keep the colour,
            // which is the answer's meaning.
            .environment(\.controlActiveState, .key)
        #endif
    }

    private var isTextOnly: Bool { [.link, .approveLink, .denyLink].contains(action.kind) }

    private var controlSize: ControlSize {
        #if os(watchOS)
        .regular
        #elseif os(macOS)
        tall ? .large : .regular
        #else
        .large
        #endif
    }

    private static var symbolSize: CGFloat {
        #if os(macOS)
        13
        #elseif os(watchOS)
        14
        #else
        16
        #endif
    }

    private static var borderedHorizontalPadding: CGFloat {
        #if os(macOS)
        14
        #else
        16
        #endif
    }

    private static var borderedVerticalPadding: CGFloat {
        #if os(macOS)
        5
        #else
        13
        #endif
    }

    private static var borderedCornerRadius: CGFloat {
        #if os(macOS)
        16
        #else
        24
        #endif
    }
}
