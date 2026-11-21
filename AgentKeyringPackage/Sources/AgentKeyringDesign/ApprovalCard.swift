// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// The one approval card, for a password request, a practice request and a
// device asking to join. On the Mac it floats beside the window; on iPhone
// it sits in Home; on the Watch the buttons come before the reason, so a
// long reason never pushes them off the screen.

import SwiftUI

public struct KeyringApprovalCard: View {
    let lead: String
    let subject: String
    let detail: String?
    let reason: String?
    let explanation: String?
    let reply: Binding<String>?
    let replyPrompt: String
    let approve: KeyringAction
    let deny: KeyringAction
    let explain: KeyringAction?
    let footer: String?
    let header: String?

    /// - Parameters:
    ///   - lead: "Practice request: an agent wants", "Add this iPhone to Agent Keyring?"
    ///   - subject: the site, or the device's name. Never cut: shrinks a step, then wraps at its dots.
    ///   - detail: the account.
    ///   - reason: the agent's own words, shown in quotes.
    ///   - explanation: what approving a device means.
    ///   - reply: the Mac's reply box, sent with Deny.
    ///   - explain: Deny and Explain, on iPhone and Watch.
    ///   - header: the app's name above the card, on the Mac.
    public init(lead: String, subject: String, detail: String? = nil, reason: String? = nil, explanation: String? = nil,
                reply: Binding<String>? = nil, replyPrompt: String = "", approve: KeyringAction, deny: KeyringAction,
                explain: KeyringAction? = nil, footer: String? = nil, header: String? = nil) {
        self.lead = lead
        self.subject = subject
        self.detail = detail
        self.reason = reason
        self.explanation = explanation
        self.reply = reply
        self.replyPrompt = replyPrompt
        self.approve = approve
        self.deny = deny
        self.explain = explain
        self.footer = footer
        self.header = header
    }

    public var body: some View {
        VStack(spacing: KeyringSpace.s3) {
            if let header {
                HStack(spacing: KeyringSpace.s2) {
                    KeyringMascot(.calm).frame(width: 18, height: 18)
                    KeyringText(header, as: .heading)
                    Spacer(minLength: 0)
                }
            }
            VStack(spacing: KeyringSpace.s1) {
                KeyringText(lead, as: .meta)
                KeyringText(subject, as: .site, fit: .siteName)
                if let detail { KeyringText(detail, as: .meta) }
            }
            #if os(watchOS)
            buttons
            words
            #else
            words
            buttons
            #endif
            if let footer {
                Divider()
                KeyringText(footer, as: .caption)
            }
        }
        .multilineTextAlignment(.center)
        .environment(\.keyringButtonsFill, true)
    }

    @ViewBuilder private var words: some View {
        if let reason { KeyringText("“\(reason)”", as: .body) }
        if let explanation { KeyringText(explanation, as: .meta) }
    }

    @ViewBuilder private var buttons: some View {
        #if os(macOS)
        if let reply {
            HStack(spacing: KeyringSpace.s2) {
                TextField("", text: reply, prompt: Text(replyPrompt), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(KeyringTextRole.body.font)
                    .padding(.horizontal, KeyringSpace.s4).padding(.vertical, KeyringSpace.s2)
                    .frame(minHeight: 36)
                    .background(KeyringPalette.fill, in: .capsule)
                KeyringButton(deny).environment(\.keyringButtonsFill, false)
            }
            KeyringButton(approve)
        } else {
            KeyringButton(approve)
            KeyringButton(deny)
        }
        #else
        VStack(spacing: KeyringSpace.s2) {
            HStack(spacing: KeyringSpace.s2) {
                KeyringButton(deny)
                KeyringButton(approve)
            }
            if let explain { KeyringButton(explain) }
        }
        #endif
    }
}
