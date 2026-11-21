// Written by AI on 2026.11.18 by model Claude Opus 5.5; rebuilt from the shared page parts on 2026.11.21.
//
// The card iOS shows above its own buttons when a request's notification is
// touched and held: who asks, the site, the account, and the agent's words.

#if os(iOS)
import AgentKeyringDesign
import SwiftUI

public struct PhoneNotificationCard: View {
    let request: AccessRequest

    public init(request: AccessRequest) { self.request = request }

    public var body: some View {
        VStack(spacing: KeyringSpace.s3) {
            VStack(spacing: KeyringSpace.s1) {
                KeyringText(PhoneCopy.wants(request.agent), as: .meta)
                KeyringText(request.login.site, as: .site, fit: .siteName)
                if !request.login.account.isEmpty { KeyringText(request.login.account, as: .meta) }
            }
            if !request.agentReason.isEmpty { KeyringText(PhoneCopy.quoted(request.agentReason), as: .body) }
            KeyringText(request.isPractice ? PhoneCopy.practiceLasts : PhoneCopy.lasts(request.agent), as: .caption)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(KeyringSpace.s4)
    }
}

/// The held notification when the request's words could not be opened: iOS's own title and text, never a blank card.
public struct PhoneNotificationFallbackCard: View {
    let title: String
    let text: String

    public init(title: String, text: String) { self.title = title; self.text = text }

    public var body: some View {
        VStack(alignment: .leading, spacing: KeyringSpace.s1) {
            KeyringText(title, as: .heading)
            KeyringText(text, as: .meta)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(KeyringSpace.s4)
    }
}
#endif
