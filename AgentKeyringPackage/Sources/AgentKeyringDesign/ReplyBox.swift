// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// The box he types or speaks his reply into (iPhone's Deny and Explain). It
// grows with the words to about ten lines, has room for the microphone
// button inside it, and says under it what the microphone is doing.

#if os(iOS) || os(macOS)
import SwiftUI

public struct KeyringReplyBox<Trailing: View>: View {
    let text: Binding<String>
    let prompt: String
    let note: KeyringStatus?
    let noteAction: KeyringAction?
    let focus: FocusState<Bool>.Binding?
    let trailing: Trailing

    /// - Parameters:
    ///   - prompt: shown in the empty box, such as "What should the agent do instead?".
    ///   - note: the microphone's state: `.listening`, `.waiting` while the speech model downloads, `.problem` if it is off.
    ///   - noteAction: the way to fix the note, such as Open Settings.
    ///   - focus: optional FocusState binding applied directly to the inner TextField.
    ///   - trailing: the microphone button, at the box's bottom right.
    public init(text: Binding<String>, prompt: String, note: KeyringStatus? = nil, noteAction: KeyringAction? = nil,
                focus: FocusState<Bool>.Binding? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.text = text
        self.prompt = prompt
        self.note = note
        self.noteAction = noteAction
        self.focus = focus
        self.trailing = trailing()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: KeyringSpace.s2) {
            TrailingOrBelow(spacing: KeyringSpace.s2, belowAlignment: .trailing, besideAtBottom: true) {
                // The prompt sits under the field, in the layout, so a long one makes the box taller.
                ZStack(alignment: .topLeading) {
                    KeyringPrompt(prompt, showing: text.wrappedValue.isEmpty)
                    field
                }
                trailing
            }
            .padding(KeyringSpace.s4)
            .background(KeyringPalette.fill, in: .rect(cornerRadius: KeyringRadius.card))
            if let note { KeyringStatusLine(note, action: noteAction) }
        }
    }

    @ViewBuilder private var field: some View {
        let base = TextField("", text: text, axis: .vertical)
            .lineLimit(2...6)
            .textFieldStyle(.plain)
            .font(KeyringTextRole.body.font)
            .foregroundStyle(KeyringPalette.ink)
            .multilineTextAlignment(.leading)
            .accessibilityLabel(prompt)
        if let focus {
            base.focused(focus)
        } else {
            base
        }
    }
}

/// The empty box's prompt, drawn by the parts: a text field's own placeholder
/// is cut off at large text sizes, where the check cannot see it.
struct KeyringPrompt: View {
    let words: String
    let showing: Bool
    init(_ words: String, showing: Bool) { self.words = words; self.showing = showing }

    var body: some View {
        if showing {
            KeyringText(words, as: .body, colour: KeyringPalette.ink3)
                .multilineTextAlignment(.leading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension KeyringReplyBox where Trailing == EmptyView {
    public init(text: Binding<String>, prompt: String, note: KeyringStatus? = nil, noteAction: KeyringAction? = nil) {
        self.init(text: text, prompt: prompt, note: note, noteAction: noteAction) { EmptyView() }
    }
}
#endif
