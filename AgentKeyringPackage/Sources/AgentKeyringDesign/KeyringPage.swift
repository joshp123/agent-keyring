// Written by AI on 2026.11.21 by model claude opus 5.5, from boards 1 to 3
// of the Paper file "Agent Keyring".
//
// The page every first-run screen and device flow is built from. The page
// owns every margin and gap; what goes inside it brings none of its own.
// Mac: inside the setup window, buttons along the bottom. iPhone: scrolls,
// with its buttons pinned to the bottom. Watch: one scrolling column.

import SwiftUI

public enum KeyringPageAlignment: Sendable { case leading, centre }

public struct KeyringPage<Content: View>: View {

    let step: (Int, Int)?
    let title: String?
    let sentence: String?
    let sentenceColour: Color?
    let alignment: KeyringPageAlignment
    let mascot: KeyringMascotMood?
    let status: KeyringStatus?
    let primary: KeyringAction?
    let secondary: KeyringAction?
    let aside: KeyringAction?
    let content: Content

    @Environment(\.keyringUnrollsScrolling) private var unrolls

    /// - Parameters:
    ///   - step: (2, 4) shows "Step 2 of 4" above the title.
    ///   - title: none for a page whose body says what it is about (the Deny and Explain sheet starts with the request).
    ///   - mascot: a mascot above a centred title (iPhone and Watch; the Mac's is in the setup window).
    ///   - status: one line under the body: waiting, taking long, done, or a problem.
    ///   - primary: the page's main button. Blue to move on; green or red only to approve or deny.
    ///   - secondary: Back on the Mac; on iPhone and Watch, the way out under the main button.
    ///   - aside: the Mac's quiet button at the bottom left (Use Test Password Only, Skip the Test).
    public init(step: (Int, Int)? = nil, title: String? = nil, sentence: String? = nil, sentenceColour: Color? = nil,
                alignment: KeyringPageAlignment = .leading, mascot: KeyringMascotMood? = nil, status: KeyringStatus? = nil,
                primary: KeyringAction? = nil, secondary: KeyringAction? = nil, aside: KeyringAction? = nil,
                @ViewBuilder content: () -> Content) {
        self.step = step
        self.title = title
        self.sentence = sentence
        self.sentenceColour = sentenceColour
        self.alignment = alignment
        self.mascot = mascot
        self.status = status
        self.primary = primary
        self.secondary = secondary
        self.aside = aside
        self.content = content()
    }

    private var horizontal: HorizontalAlignment { alignment == .centre ? .center : .leading }
    private var frameAlignment: SwiftUI.Alignment { alignment == .centre ? .top : .topLeading }

    private var hasHeading: Bool { step != nil || title != nil || sentence != nil || mascot != nil }

    private var heading: some View {
        VStack(alignment: horizontal, spacing: Self.headingGap) {
            if let mascot { KeyringMascot(mascot).frame(width: Self.mascotSize, height: Self.mascotSize).padding(.bottom, Self.mascotGap) }
            if let step { KeyringText(PartsCopy.step(step.0, of: step.1), as: .stepMarker) }
            if let title { KeyringText(title, as: mascot == nil ? .title : .heroTitle) }
            if let sentence {
                KeyringText(sentence, as: .sentence, colour: sentenceColour)
                    .frame(maxWidth: KeyringSize.measure, alignment: alignment == .centre ? .center : .leading)
            }
        }
        .multilineTextAlignment(alignment == .centre ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: alignment == .centre ? .center : .leading)
    }

    private var bodyAndStatus: some View {
        VStack(alignment: horizontal, spacing: Self.gap) {
            content
            if let status { KeyringStatusLine(status) }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .centre ? .center : .leading)
    }

    public var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: KeyringSpace.s6) {
            if hasHeading { heading }
            bodyAndStatus
            Spacer(minLength: 0)
            HStack(spacing: KeyringSpace.s3) {
                if let aside { KeyringButton(aside) }
                Spacer(minLength: KeyringSpace.s3)
                if let secondary { KeyringButton(secondary) }
                if let primary { KeyringButton(primary) }
            }
        }
        .padding(.horizontal, KeyringSize.macPageMargin)
        .padding(.top, KeyringSpace.s8)
        .padding(.bottom, KeyringSpace.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KeyringPalette.canvas)
        #else
        #if os(watchOS)
        // The Watch has no room to pin buttons: keep spacing tight so the primary button fits above the fold.
        let page = VStack(spacing: KeyringSpace.s2) { column; buttons }
        if unrolls { page } else { ScrollView { page } }
        #else
        if unrolls {
            VStack(spacing: KeyringSpace.s6) {
                column
                Spacer(minLength: 0)
                buttons
            }
            .padding(.bottom, KeyringSpace.s3)
            .background(KeyringPalette.canvas)
        } else {
            ScrollView { column }
                .scrollBounceBehavior(.basedOnSize)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    buttons
                        .padding(.bottom, KeyringSpace.s2)
                        .background(KeyringPalette.canvas)
                }
                .background(KeyringPalette.canvas.ignoresSafeArea())
        }
        #endif
        #endif
    }

    #if !os(macOS)
    private var column: some View {
        VStack(alignment: horizontal, spacing: Self.gap) {
            if hasHeading { heading }
            bodyAndStatus
        }
        .padding(.horizontal, Self.margin)
        .padding(.top, Self.columnTopPadding(centre: alignment == .centre))
        .padding(.bottom, Self.columnBottomPadding)
    }

    @ViewBuilder private var buttons: some View {
        if primary != nil || secondary != nil || aside != nil {
            VStack(spacing: Self.buttonGap) {
                if let primary { KeyringButton(primary) }
                if let secondary { KeyringButton(secondary) }
                if let aside { KeyringButton(aside) }
            }
            .environment(\.keyringButtonsFill, true)
            .padding(.horizontal, Self.margin)
            .padding(.top, Self.buttonsTopPadding)
        }
    }
    #endif

    static var margin: CGFloat {
        #if os(watchOS)
        KeyringSpace.s1
        #else
        KeyringSize.phoneMargin
        #endif
    }

    static var gap: CGFloat {
        #if os(watchOS)
        KeyringSpace.s2
        #else
        KeyringSpace.s6
        #endif
    }

    static var headingGap: CGFloat {
        #if os(watchOS)
        KeyringSpace.s1
        #else
        KeyringSpace.s2
        #endif
    }

    static var mascotGap: CGFloat {
        #if os(watchOS)
        0
        #else
        KeyringSpace.s2
        #endif
    }

    static var buttonGap: CGFloat {
        #if os(watchOS)
        KeyringSpace.s2
        #else
        KeyringSpace.s3
        #endif
    }

    static func columnTopPadding(centre: Bool) -> CGFloat {
        #if os(watchOS)
        0
        #else
        centre ? KeyringSpace.s8 : Self.margin
        #endif
    }

    static var columnBottomPadding: CGFloat {
        #if os(watchOS)
        0
        #else
        KeyringSpace.s4
        #endif
    }

    static var buttonsTopPadding: CGFloat {
        #if os(watchOS)
        0
        #else
        KeyringSpace.s3
        #endif
    }

    static var mascotSize: CGFloat {
        #if os(watchOS)
        28
        #else
        64
        #endif
    }
}

extension KeyringPage where Content == EmptyView {
    public init(step: (Int, Int)? = nil, title: String? = nil, sentence: String? = nil, alignment: KeyringPageAlignment = .leading,
                mascot: KeyringMascotMood? = nil, status: KeyringStatus? = nil,
                primary: KeyringAction? = nil, secondary: KeyringAction? = nil, aside: KeyringAction? = nil) {
        self.init(step: step, title: title, sentence: sentence, alignment: alignment, mascot: mascot, status: status,
                  primary: primary, secondary: secondary, aside: aside) { EmptyView() }
    }
}
