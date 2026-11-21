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
    let approve: KeyringAction?
    let inPlaceOfApprove: String?
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
    ///   - approve: none when approving is not possible here (the lid is shut); `inPlaceOfApprove` then says why, where the button would be.
    public init(lead: String, subject: String, detail: String? = nil, reason: String? = nil, explanation: String? = nil,
                reply: Binding<String>? = nil, replyPrompt: String = "", approve: KeyringAction?, inPlaceOfApprove: String? = nil,
                deny: KeyringAction, explain: KeyringAction? = nil, footer: String? = nil, header: String? = nil) {
        self.lead = lead
        self.subject = subject
        self.detail = detail
        self.reason = reason
        self.explanation = explanation
        self.reply = reply
        self.replyPrompt = replyPrompt
        self.approve = approve
        self.inPlaceOfApprove = inPlaceOfApprove
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
            #if os(watchOS)
            KeyringRequestHeader(lead: lead, subject: subject, detail: detail)
            buttons
            KeyringRequestHeader.Words(reason: reason, explanation: explanation)
            #else
            KeyringRequestHeader(lead: lead, subject: subject, detail: detail, reason: reason, explanation: explanation)
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

    /// Approve, or the line that says why it cannot be done here.
    @ViewBuilder private var approveSlot: some View {
        if let approve {
            KeyringButton(approve)
        } else if let inPlaceOfApprove {
            KeyringText(inPlaceOfApprove, as: .meta).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var buttons: some View {
        #if os(macOS)
        if let reply {
            HStack(spacing: KeyringSpace.s2) {
                ZStack(alignment: .leading) {
                    KeyringPrompt(replyPrompt, showing: reply.wrappedValue.isEmpty)
                    TextField("", text: reply, axis: .vertical)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        .font(KeyringTextRole.body.font)
                        .accessibilityLabel(replyPrompt)
                }
                    .padding(.horizontal, KeyringSpace.s4).padding(.vertical, KeyringSpace.s2)
                    .frame(minHeight: 36)
                    .background(KeyringPalette.fill, in: .capsule)
                KeyringButton(deny).environment(\.keyringButtonsFill, false)
            }
            approveSlot
        } else {
            approveSlot
            KeyringButton(deny)
        }
        #else
        VStack(spacing: KeyringSpace.s2) {
            // Side by side while both labels fit on one line; else Approve above Deny.
            if let approve {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: KeyringSpace.s2) {
                        KeyringButton(deny)
                        KeyringButton(approve)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: KeyringSpace.s2) {
                        KeyringButton(approve)
                        KeyringButton(deny)
                    }
                }
            } else {
                approveSlot
                KeyringButton(deny)
            }
            if let explain { KeyringButton(explain) }
        }
        #endif
    }
}

/// What is asked, centred: who asks (small), the site (big), the account, then
/// the agent's reason in quotes. The top of every approval card, and the
/// body of a page about one request (iPhone's Deny and Explain sheet).
public struct KeyringRequestHeader: View {
    let lead: String
    let subject: String
    let detail: String?
    let reason: String?
    let explanation: String?

    public init(lead: String, subject: String, detail: String? = nil, reason: String? = nil, explanation: String? = nil) {
        self.lead = lead
        self.subject = subject
        self.detail = detail
        self.reason = reason
        self.explanation = explanation
    }

    public var body: some View {
        VStack(spacing: KeyringSpace.s3) {
            VStack(spacing: KeyringSpace.s1) {
                KeyringText(lead, as: .meta)
                KeyringText(subject, as: .site, fit: .siteName)
                if let detail { KeyringText(detail, as: .meta) }
            }
            Words(reason: reason, explanation: explanation)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    /// The reason and the explanation alone, for the Watch, where they come after the buttons.
    public struct Words: View {
        let reason: String?
        let explanation: String?
        public init(reason: String?, explanation: String? = nil) { self.reason = reason; self.explanation = explanation }
        public var body: some View {
            if let reason { KeyringText("“\(reason)”", as: .body) }
            if let explanation { KeyringText(explanation, as: .meta) }
        }
    }
}
