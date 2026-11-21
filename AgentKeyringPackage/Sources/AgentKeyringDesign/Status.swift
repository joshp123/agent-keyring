// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// One line that says where things are: waiting, waiting too long, done, or
// what went wrong. A page has at most one.

import SwiftUI

public enum KeyringStatus: Sendable, Equatable {
    /// A spinner and what we are waiting for.
    case waiting(String)
    /// The same wait gone on too long: what to check, in the stalled colour.
    case takingLong(String)
    /// A green tick and what happened.
    case done(String)
    /// What went wrong, in red.
    case problem(String)
}

public struct KeyringStatusLine: View {
    let status: KeyringStatus

    public init(_ status: KeyringStatus) { self.status = status }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: KeyringSpace.s2) {
            switch status {
            case let .waiting(words):
                ProgressView().controlSize(.small).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                KeyringText(words, as: .meta)
            case let .takingLong(words):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(KeyringPalette.stalled)
                KeyringText(words, as: .meta, colour: KeyringPalette.stalled)
            case let .done(words):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(KeyringPalette.approve)
                KeyringText(words, as: .meta, colour: KeyringPalette.ink)
            case let .problem(words):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(KeyringPalette.deny)
                KeyringText(words, as: .meta, colour: KeyringPalette.deny)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A result that closes a step: "You approved it", "Agent Keyring is ready on this Mac".
public struct KeyringConfirmation: View {
    public enum Tone: Sendable { case approved, denied }
    let title: String
    let detail: String?
    let tone: Tone

    public init(_ title: String, detail: String? = nil, tone: Tone = .approved) {
        self.title = title
        self.detail = detail
        self.tone = tone
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: KeyringSpace.s3) {
            Image(systemName: tone == .approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(KeyringTextRole.heading.font)
                .foregroundStyle(tone == .approved ? KeyringPalette.approve : KeyringPalette.deny)
            VStack(alignment: .leading, spacing: KeyringSpace.s1) {
                KeyringText(title, as: .heading)
                if let detail { KeyringText(detail, as: .meta) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(KeyringSpace.s4)
        .background(tone == .approved ? KeyringPalette.approveTint : KeyringPalette.denyTint, in: .rect(cornerRadius: KeyringRadius.card))
    }
}

/// A tinted card with a symbol: the Focus hint, "Not showing up on your Watch?", the trust card.
public struct KeyringHint: View {
    public enum Tone: Sendable { case info, focus, stalled, plain }
    let symbol: String
    let title: String?
    let words: String
    let tone: Tone

    public init(symbol: String, title: String? = nil, _ words: String, tone: Tone = .info) {
        self.symbol = symbol
        self.title = title
        self.words = words
        self.tone = tone
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: KeyringSpace.s3) {
            Image(systemName: symbol).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: KeyringSpace.s1) {
                if let title { KeyringText(title, as: .heading, colour: tone == .stalled ? KeyringPalette.stalled : nil) }
                KeyringText(words, as: .meta, colour: KeyringPalette.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(KeyringSpace.s4)
        .background(tint, in: .rect(cornerRadius: KeyringRadius.card))
    }

    private var accent: Color {
        switch tone {
        case .info: KeyringPalette.brand
        case .focus: KeyringPalette.focus
        case .stalled: KeyringPalette.stalled
        case .plain: KeyringPalette.ink2
        }
    }

    private var tint: Color {
        switch tone {
        case .info: KeyringPalette.brandTint
        case .focus: KeyringPalette.focusTint
        case .stalled: KeyringPalette.stalledTint
        case .plain: KeyringPalette.fill
        }
    }
}
