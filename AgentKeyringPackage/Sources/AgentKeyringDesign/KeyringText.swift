// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// The only way a page puts words on screen. A role picks the type from the
// design tokens; a fit says what the text may do when space is short. By
// default it wraps and never shrinks. The few places where shrinking is
// intended are named here, so a reviewer sees every exception in one file.

import SwiftUI

/// What a text is on the page. Sizes are Paper's; on iPhone and Watch they
/// are Dynamic Type styles, so they grow with the person's text size.
public enum KeyringTextRole: Sendable {
    /// "Step 2 of 4", above a page's title.
    case stepMarker
    /// A page's title.
    case title
    /// A centred title over a mascot or icon: Welcome, Ready.
    case heroTitle
    /// The one sentence under a title.
    case sentence
    /// Body text in a card or step.
    case body
    /// Bold body text: a row's or card's own title.
    case heading
    /// Who is asking, the account, a row's detail.
    case meta
    /// The website in a request.
    case site
    /// A small caption under a block.
    case caption
    /// A section's name over a group of rows.
    case sectionName
    /// A command or note to copy.
    case code
    /// A button's label.
    case label

    var font: Font {
        #if os(macOS)
        switch self {
        case .stepMarker: .system(size: 13, weight: .semibold)
        case .title: .system(size: 24, weight: .bold)
        case .heroTitle: .system(size: 26, weight: .bold)
        case .sentence, .body: .system(size: 15)
        case .heading: .system(size: 15, weight: .semibold)
        case .meta: .system(size: 13)
        case .site: .system(size: 32, weight: .bold)
        case .caption: .system(size: 12)
        case .sectionName: .system(size: 11, weight: .semibold)
        case .code: .system(size: 13, design: .monospaced)
        case .label: .system(size: 13, weight: .semibold)
        }
        #elseif os(watchOS)
        switch self {
        case .stepMarker: .footnote.weight(.semibold)
        case .title, .heroTitle: .headline
        case .sentence, .meta, .caption, .sectionName: .footnote
        case .body: .body
        case .heading: .body.weight(.semibold)
        case .site: .title3.weight(.bold)
        case .code: .footnote.monospaced()
        case .label: .body.weight(.semibold)
        }
        #else
        switch self {
        case .stepMarker: .footnote.weight(.semibold)
        case .title: .title.weight(.bold)
        case .heroTitle: .title.weight(.bold)
        case .sentence, .body: .body
        case .heading: .body.weight(.semibold)
        case .meta: .subheadline
        case .site: .largeTitle.weight(.bold)
        case .caption: .footnote
        case .sectionName: .footnote.weight(.semibold)
        case .code: .callout.monospaced()
        case .label: .body.weight(.semibold)
        }
        #endif
    }

    /// The same text one type step down, for `TextFit.siteName`.
    var smallerFont: Font {
        #if os(macOS)
        .system(size: 24, weight: .bold)
        #elseif os(watchOS)
        .headline
        #else
        .title.weight(.bold)
        #endif
    }

    /// None for a label: the button's style colours it.
    var colour: Color? {
        switch self {
        case .stepMarker: KeyringPalette.brand
        case .sentence, .meta, .caption, .sectionName: KeyringPalette.ink2
        case .label: nil
        default: KeyringPalette.ink
        }
    }
}

/// What a text may do when its space is short. Wrapping is the only default;
/// every other way is named here and nowhere else.
public struct TextFit: Sendable, Equatable {
    enum Way: Sendable, Equatable { case wraps, siteName }
    let way: Way

    /// As many lines as the words need. Never shrinks, never cut.
    public static let wraps = TextFit(way: .wraps)
    /// A website: one line at full size, else one line a type step smaller,
    /// else wrapped at its dots at that smaller size (a long site on the Watch).
    public static let siteName = TextFit(way: .siteName)
}

/// Words on a page. Accepts the copy tables' inline Markdown (`**bold**`).
public struct KeyringText: View {
    let words: String
    let role: KeyringTextRole
    let fit: TextFit
    let colour: Color?

    @Environment(\.keyringAudit) private var audit
    @Environment(\.keyringAuditOwner) private var owner
    @State private var id = UUID()

    public init(_ words: String, as role: KeyringTextRole = .body, fit: TextFit = .wraps, colour: Color? = nil) {
        self.words = words
        self.role = role
        self.fit = fit
        self.colour = colour
    }

    public var body: some View {
        switch fit.way {
        case .wraps:
            line(role.font, words).fixedSize(horizontal: false, vertical: true)
        case .siteName:
            ViewThatFits(in: .horizontal) {
                line(role.font, words).lineLimit(1)
                line(role.smallerFont, words).lineLimit(1)
                line(role.smallerFont, Self.breakingAtDots(words)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func line(_ font: Font, _ shown: String) -> some View {
        Text(Self.markdown(shown))
            .font(font)
            .modifier(Colouring(colour: colour ?? role.colour))
            .textCase(role == .sectionName ? .uppercase : nil)
            .modifier(Reporting(id: id, label: words, shown: Array(String(Self.markdown(shown).characters)), audit: audit))
            .reportsPlacement(.init(id: id, kind: .text, label: words, owner: owner), to: audit)
    }

    /// Bold and italics only: no links, so an address or a site is never turned blue.
    static func markdown(_ words: String) -> AttributedString {
        guard words.contains("*"), var parsed = try? AttributedString(markdown: words, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(words) }
        parsed.link = nil
        return parsed
    }

    /// A zero-width space after each dot, so a long site wraps at a dot, not mid-word.
    static func breakingAtDots(_ site: String) -> String {
        site.replacingOccurrences(of: ".", with: ".\u{200B}")
    }
}

private struct Reporting: ViewModifier {
    let id: UUID
    let label: String
    let shown: [Character]
    let audit: KeyringAudit?

    func body(content: Content) -> some View {
        if let audit { content.textRenderer(TruncationReporter(id: id, label: label, shown: shown, audit: audit)) } else { content }
    }
}

private struct Colouring: ViewModifier {
    let colour: Color?
    func body(content: Content) -> some View {
        if let colour { content.foregroundStyle(colour) } else { content }
    }
}
