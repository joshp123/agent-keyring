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
    let trailing: Trailing
    @Environment(\.dynamicTypeSize) private var textSize

    /// - Parameters:
    ///   - prompt: shown in the empty box, such as "What should the agent do instead?".
    ///   - note: the microphone's state: `.listening`, `.waiting` while the speech model downloads, `.problem` if it is off.
    ///   - noteAction: the way to fix the note, such as Open Settings.
    ///   - trailing: the microphone button, at the box's bottom right.
    public init(text: Binding<String>, prompt: String, note: KeyringStatus? = nil, noteAction: KeyringAction? = nil,
                @ViewBuilder trailing: () -> Trailing) {
        self.text = text
        self.prompt = prompt
        self.note = note
        self.noteAction = noteAction
        self.trailing = trailing()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: KeyringSpace.s2) {
            // At accessibility text sizes the microphone goes under the words, so neither is squeezed.
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .trailing, spacing: KeyringSpace.s2)) : AnyLayout(HStackLayout(alignment: .bottom, spacing: KeyringSpace.s2))
            layout {
                TextField("", text: text, prompt: Text(prompt), axis: .vertical)
                    .lineLimit(3...10)
                    .textFieldStyle(.plain)
                    .font(KeyringTextRole.body.font)
                    .foregroundStyle(KeyringPalette.ink)
                    .multilineTextAlignment(.leading)
                trailing
            }
            .padding(KeyringSpace.s4)
            .background(KeyringPalette.fill, in: .rect(cornerRadius: KeyringRadius.card))
            if let note { KeyringStatusLine(note, action: noteAction) }
        }
    }
}

extension KeyringReplyBox where Trailing == EmptyView {
    public init(text: Binding<String>, prompt: String, note: KeyringStatus? = nil, noteAction: KeyringAction? = nil) {
        self.init(text: text, prompt: prompt, note: note, noteAction: noteAction) { EmptyView() }
    }
}
#endif
