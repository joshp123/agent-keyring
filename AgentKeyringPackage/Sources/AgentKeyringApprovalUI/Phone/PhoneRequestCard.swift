// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The request as the iPhone shows it: who asks and for what project, the
// site, the account, and the agent's sentence. The app's request screen and
// the held notification both draw it.

#if os(iOS)
import SwiftUI

/// The top line: the keyhole and "Agent Keyring", and the project at the right.
public struct PhoneRequestHeader: View {
    let agent: RequestingAgent
    /// In place of the project: "Practice" on first run's practice request.
    var badge: String?
    var textStyle: Font = .subheadline
    var iconSize: CGFloat = 22

    public init(agent: RequestingAgent, badge: String? = nil, compact: Bool = false) {
        self.agent = agent; self.badge = badge
        if compact { textStyle = .footnote; iconSize = 20 }
    }

    public var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                KeyholeIcon(size: iconSize)
                Text(PhoneCopy.appName).fontWeight(.semibold).foregroundStyle(Phone.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let badge {
                Text(badge).fontWeight(.semibold).foregroundStyle(Phone.ink)
            } else if let scope = PhoneCopy.scope(agent) {
                HStack(spacing: 5) {
                    Text(scope.label).foregroundStyle(Phone.ink2)
                    Text(scope.name).fontWeight(.semibold).foregroundStyle(Phone.ink)
                        .lineLimit(1).truncationMode(.middle)
                }
                .layoutPriority(1)
            }
        }
        .font(textStyle)
    }
}

/// "Codex on Mac mini wants", the site, the account, then the reason.
public struct PhoneRequestBody: View {
    let request: AccessRequest

    public init(request: AccessRequest) { self.request = request }

    public var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 1) {
                Text(PhoneCopy.wants(request.agent))
                    .font(.subheadline).foregroundStyle(Phone.ink2)
                // One line each: a long site shrinks rather than breaking mid-name.
                Text(request.login.site)
                    .font(.largeTitle.bold()).tracking(-0.75).foregroundStyle(Phone.ink)
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text(request.login.account)
                    .font(.subheadline).foregroundStyle(Phone.ink2)
                    .lineLimit(1).truncationMode(.middle)
            }
            Text(PhoneCopy.quoted(request.agentReason))
                .font(.title3).foregroundStyle(Phone.ink)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

/// The held notification's layout: the card iOS puts above its own buttons.
public struct PhoneNotificationCard: View {
    let request: AccessRequest

    public init(request: AccessRequest) { self.request = request }

    public var body: some View {
        VStack(spacing: 16) {
            PhoneRequestHeader(agent: request.agent, compact: true)
            PhoneRequestBody(request: request)
            Text(PhoneCopy.lasts(request.agent))
                .font(.footnote).foregroundStyle(Phone.ink2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .background(Phone.surface)
    }
}
/// The held notification when the request's words could not be opened: iOS's own title and text, never a blank card.
public struct PhoneNotificationFallbackCard: View {
    let title: String
    let text: String

    public init(title: String, text: String) { self.title = title; self.text = text }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).foregroundStyle(Phone.ink)
            Text(text).font(.body).foregroundStyle(Phone.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Phone.surface)
    }
}
#endif
