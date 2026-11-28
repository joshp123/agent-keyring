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
    /// Words inside a picture of another app's screen, such as Apple's dialogs in the export guide.
    case pictureText
    /// A title inside such a picture.
    case pictureTitle

    /// Strict 4-step Apple HIG type hierarchy in Allo:
    /// 1. Title / Subject (DisplayBold: 22 to 26pt Mac, 28 to 30pt iPhone)
    /// 2. Primary row / body / button (13pt Mac, 16pt iPhone: Medium for titles/buttons, Regular for body/numbers)
    /// 3. Secondary / meta / caption (12pt Mac, 13pt iPhone: Regular, ink2)
    /// 4. Section micro-label (11pt Mac, 12pt iPhone: Medium, uppercase tracked)
    var font: Font {
        #if os(macOS)
        switch self {
        case .title: KeyringFont.fixed(KeyringFont.PostScript.displayBold, size: 22)
        case .heroTitle: KeyringFont.fixed(KeyringFont.PostScript.displayBold, size: 24)
        case .site: KeyringFont.fixed(KeyringFont.PostScript.displayBold, size: 26)
        case .heading, .label: KeyringFont.fixed(KeyringFont.PostScript.medium, size: 13)
        case .sentence, .body: KeyringFont.fixed(KeyringFont.PostScript.regular, size: 13)
        case .meta, .caption: KeyringFont.fixed(KeyringFont.PostScript.regular, size: 12)
        case .sectionName, .stepMarker: KeyringFont.fixed(KeyringFont.PostScript.medium, size: 11)
        case .code: .system(size: 12, design: .monospaced)
        case .pictureText: KeyringFont.fixed(KeyringFont.PostScript.regular, size: 10)
        case .pictureTitle: KeyringFont.fixed(KeyringFont.PostScript.medium, size: 11)
        }
        #elseif os(watchOS)
        switch self {
        case .title, .heroTitle: KeyringFont.scaled(KeyringFont.PostScript.displayBold, size: 17, relativeTo: .headline)
        case .site: KeyringFont.scaled(KeyringFont.PostScript.displayBold, size: 19, relativeTo: .title3)
        case .heading, .label: KeyringFont.scaled(KeyringFont.PostScript.medium, size: 15, relativeTo: .body)
        case .body: KeyringFont.scaled(KeyringFont.PostScript.regular, size: 15, relativeTo: .body)
        case .sentence, .meta, .caption: KeyringFont.scaled(KeyringFont.PostScript.regular, size: 13, relativeTo: .footnote)
        case .sectionName, .stepMarker: KeyringFont.scaled(KeyringFont.PostScript.medium, size: 12, relativeTo: .caption2)
        case .code: .footnote.monospaced()
        case .pictureText: KeyringFont.scaled(KeyringFont.PostScript.regular, size: 11, relativeTo: .caption2)
        case .pictureTitle: KeyringFont.scaled(KeyringFont.PostScript.medium, size: 11, relativeTo: .caption2)
        }
        #else
        switch self {
        case .title, .heroTitle: KeyringFont.scaled(KeyringFont.PostScript.displayBold, size: 28, relativeTo: .title)
        case .site: KeyringFont.scaled(KeyringFont.PostScript.displayBold, size: 30, relativeTo: .largeTitle)
        case .heading, .label: KeyringFont.scaled(KeyringFont.PostScript.medium, size: 16, relativeTo: .body)
        case .sentence, .body: KeyringFont.scaled(KeyringFont.PostScript.regular, size: 16, relativeTo: .body)
        case .meta: KeyringFont.scaled(KeyringFont.PostScript.regular, size: 14, relativeTo: .subheadline)
        case .caption: KeyringFont.scaled(KeyringFont.PostScript.regular, size: 13, relativeTo: .footnote)
        case .sectionName, .stepMarker: KeyringFont.scaled(KeyringFont.PostScript.medium, size: 12, relativeTo: .caption)
        case .code: .callout.monospaced()
        case .pictureText: KeyringFont.scaled(KeyringFont.PostScript.regular, size: 11, relativeTo: .caption2)
        case .pictureTitle: KeyringFont.scaled(KeyringFont.PostScript.medium, size: 12, relativeTo: .caption)
        }
        #endif
    }

    /// The same text one type step down, for `TextFit.siteName`.
    var smallerFont: Font {
        #if os(macOS)
        self == .site
            ? KeyringFont.fixed(KeyringFont.PostScript.displayBold, size: 20)
            : KeyringFont.fixed(KeyringFont.PostScript.medium, size: 12)
        #elseif os(watchOS)
        self == .site
            ? KeyringFont.scaled(KeyringFont.PostScript.displayBold, size: 16, relativeTo: .headline)
            : KeyringFont.scaled(KeyringFont.PostScript.medium, size: 13, relativeTo: .footnote)
        #else
        self == .site
            ? KeyringFont.scaled(KeyringFont.PostScript.displayBold, size: 24, relativeTo: .title)
            : KeyringFont.scaled(KeyringFont.PostScript.medium, size: 14, relativeTo: .subheadline)
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
    @Environment(\.keyringButtonsFill) private var buttonFills
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
            line(role.font, role == .code ? Self.breakingAnywhere(words) : Self.breakingAtDots(words))
                .fixedSize(horizontal: false, vertical: true)
        case .siteName:
            ViewThatFits(in: .horizontal) {
                line(role.font, words).lineLimit(1)
                line(role.smallerFont, words).lineLimit(1)
                line(role.smallerFont, Self.breakingAtDots(words)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func line(_ font: Font, _ shown: String) -> some View {
        Text(role == .code ? AttributedString(shown) : Self.markdown(shown))
            .font(font)
            .modifier(Colouring(colour: colour ?? role.colour))
            .textCase(role == .sectionName ? .uppercase : nil)
            .modifier(Reporting(id: id, label: words, shown: Array(String((role == .code ? AttributedString(shown) : Self.markdown(shown)).characters)),
                                mustStayOnOneLine: owner != nil && !buttonFills, audit: audit))
            .reportsPlacement(.init(id: id, kind: .text, label: words, owner: owner), to: audit)
    }

    /// Bold and italics only: no links, so an address or a site is never turned blue.
    static func markdown(_ words: String) -> AttributedString {
        guard words.contains("*"), var parsed = try? AttributedString(markdown: words, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(words) }
        parsed.link = nil
        return parsed
    }

    /// A command or link may break between any two characters, as a terminal
    /// shows it: a 250-character invite is shown whole, never cut.
    static func breakingAnywhere(_ code: String) -> String {
        code.map(String.init).joined(separator: "\u{200B}")
    }

    /// A zero-width space after each dot or @ inside a word, so a site or an
    /// address too long for its line wraps there ("you@ / example.com"), not
    /// mid-word ("you@exam- / ple.com"). Sentences are untouched: their dots
    /// are followed by a space.
    static func breakingAtDots(_ words: String) -> String {
        var out = ""
        let characters = Array(words)
        for (index, character) in characters.enumerated() {
            out.append(character)
            if character == "." || character == "@", index + 1 < characters.count, characters[index + 1].isLetter || characters[index + 1].isNumber {
                out.append("\u{200B}")
            }
        }
        return out
    }
}

private struct Reporting: ViewModifier {
    let id: UUID
    let label: String
    let shown: [Character]
    let mustStayOnOneLine: Bool
    let audit: KeyringAudit?

    func body(content: Content) -> some View {
        if let audit {
            content.textRenderer(TruncationReporter(id: id, label: label, shown: shown, mustStayOnOneLine: mustStayOnOneLine, audit: audit))
        } else {
            content
        }
    }
}

private struct Colouring: ViewModifier {
    let colour: Color?
    func body(content: Content) -> some View {
        if let colour { content.foregroundStyle(colour) } else { content }
    }
}
