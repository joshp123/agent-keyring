// Written by AI on 2026.11.26 by model gemini-4-neon.
//
// Shared cross-device UI primitives imported by Mac, iPhone, and Watch views:
// - KeyringKeyholeMark: brand mark for floating panels and notification headers
// - KeyringUnifiedApprovalCard: one approval card across Mac Float, Mac Menu Bar, and iPhone
// - KeyringHorizontalApprovalBanner: wide Mac Activity waiting banner (stacks cleanly for 1 or 2+)
// - KeyringSettledActivityRow: identical airy 2-line settled row for Mac Menu Bar and iPhone Activity
// - KeyringRuleVisual / KeyringRulePill / KeyringFilterPill: Option A semantic rule styling with circular capsule strokes

import SwiftUI

/// Subtle Agent Keyring keyhole glyph (works identically on macOS, iOS, and watchOS).
public struct KeyringKeyholeMark: View {
    public var size: CGFloat
    public var colour: Color

    public init(size: CGFloat = 16, colour: Color = KeyringPalette.brand) {
        self.size = size
        self.colour = colour
    }

    public var body: some View {
        Canvas { ctx, canvasSize in
            let s = min(canvasSize.width, canvasSize.height) / 80
            let ox = (canvasSize.width - 80 * s) / 2
            let oy = (canvasSize.height - 80 * s) / 2
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: ox + (x - 10) * s, y: oy + (y - 12) * s)
            }
            let circle = Path(ellipseIn: CGRect(
                x: ox + (50 - 21.5 - 10) * s,
                y: oy + (38.5 - 21.5 - 12) * s,
                width: 43 * s,
                height: 43 * s
            ))
            ctx.fill(circle, with: .color(colour))
            var body = Path()
            body.move(to: pt(40.2, 51.5))
            body.addLine(to: pt(59.8, 51.5))
            body.addLine(to: pt(67.2, 81.9))
            body.addLine(to: pt(64.1, 85.9))
            body.addLine(to: pt(35.9, 85.9))
            body.addLine(to: pt(32.8, 81.9))
            body.closeSubpath()
            ctx.fill(body, with: .color(colour))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Semantic Option A rule styling shared across Mac and iPhone.
public enum KeyringRuleVisual: String, CaseIterable, Sendable {
    case ask
    case automatic
    case blocked

    public var symbol: String {
        switch self {
        case .ask: "hand.raised.fill"
        case .automatic: "bolt.fill"
        case .blocked: "nosign"
        }
    }

    public var tint: Color {
        switch self {
        case .ask: KeyringPalette.brand
        case .automatic: KeyringPalette.stalled
        case .blocked: KeyringPalette.deny
        }
    }

    public var tintBackground: Color {
        switch self {
        case .ask: KeyringPalette.brandTint
        case .automatic: KeyringPalette.stalledTint
        case .blocked: KeyringPalette.denyTint
        }
    }
}

/// Read-only semantic rule pill (Option A).
public struct KeyringRulePill: View {
    let title: String
    let visual: KeyringRuleVisual

    public init(title: String, visual: KeyringRuleVisual) {
        self.title = title
        self.visual = visual
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: visual.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(visual.tint)
                .accessibilityHidden(true)
            KeyringText(title, as: .meta, colour: visual.tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        .background(visual.tintBackground, in: Capsule(style: .circular))
        .fixedSize()
    }
}

/// Filter pill button with consistent height and circular capsule border (avoids continuous-capsule stroke artifacts at 2x).
public struct KeyringFilterPill: View {
    let title: String
    let count: Int?
    let symbol: String?
    let tint: Color
    let active: Bool
    let action: () -> Void

    public init(
        title: String,
        count: Int? = nil,
        symbol: String? = nil,
        tint: Color = KeyringPalette.brand,
        active: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.count = count
        self.symbol = symbol
        self.tint = tint
        self.active = active
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(active ? KeyringPalette.brand : tint)
                        .accessibilityHidden(true)
                }
                KeyringText(title, as: .meta, colour: active ? KeyringPalette.brand : KeyringPalette.ink)
                    .lineLimit(1)
                if let count {
                    KeyringText(count.formatted(), as: .meta, colour: active ? KeyringPalette.brand : KeyringPalette.ink2)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(active ? KeyringPalette.brandTint : KeyringPalette.surface, in: Capsule(style: .circular))
            .overlay(
                Capsule(style: .circular)
                    .strokeBorder(active ? KeyringPalette.brand.opacity(0.45) : KeyringPalette.line, lineWidth: 1)
            )
            .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// Semantic outcome presentation shared across Mac Activity, Mac Menu Bar, and iPhone Activity.
public struct KeyringOutcomeStyle: Sendable {
    public let word: String
    public let symbol: String
    public let colour: Color

    public init(word: String, symbol: String, colour: Color) {
        self.word = word
        self.symbol = symbol
        self.colour = colour
    }
}

/// Unified outcome label: one consistent symbol + word + colour everywhere.
public struct KeyringOutcomeBadge: View {
    let style: KeyringOutcomeStyle

    public init(_ style: KeyringOutcomeStyle) {
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: style.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(style.colour)
                .accessibilityHidden(true)
            KeyringText(style.word, as: .meta, colour: style.colour)
                .lineLimit(1)
        }
        .fixedSize()
    }
}

/// The ONE airy 2-line settled Activity row shared identically by Mac Menu Bar and iPhone Activity:
/// Line 1: [Site icon] Site (left) ... Outcome (right)
/// Line 2: Agent · Computer (left, muted) ... Time (right)
public struct KeyringSettledActivityRow<Icon: View>: View {
    let site: String
    let subtitle: String
    let time: String
    let outcome: KeyringOutcomeStyle
    let showChevron: Bool
    @ViewBuilder let icon: () -> Icon

    public init(
        site: String,
        subtitle: String,
        time: String,
        outcome: KeyringOutcomeStyle,
        showChevron: Bool = false,
        @ViewBuilder icon: @escaping () -> Icon
    ) {
        self.site = site
        self.subtitle = subtitle
        self.time = time
        self.outcome = outcome
        self.showChevron = showChevron
        self.icon = icon
    }

    public var body: some View {
        HStack(alignment: .center, spacing: KeyringSpace.s3) {
            icon()
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: KeyringSpace.s2) {
                    KeyringText(site, as: .heading, fit: .siteName)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    KeyringOutcomeBadge(outcome)
                }
                HStack(alignment: .firstTextBaseline, spacing: KeyringSpace.s2) {
                    KeyringText(subtitle, as: .meta)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    KeyringText(time, as: .meta)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(KeyringPalette.ink3)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#if os(iOS) || os(macOS)
/// Unified Approval Card used on Mac Floating Panel, Mac Menu Bar, iPhone Activity, and iPhone Request Sheet.
/// Identical anatomy everywhere: site + account left, agent + computer right, quoted reason well,
/// Deny + Deny & Reply on row 1, full-width biometric Approve on row 2.
public struct KeyringUnifiedApprovalCard<Icon: View>: View {
    let site: String
    let account: String?
    let agent: String
    let machine: String
    let reason: String?
    let footer: String?
    let showBrandBar: Bool
    let onDismiss: (() -> Void)?
    let compact: Bool
    let approve: KeyringAction?
    let inPlaceOfApprove: String?
    let deny: KeyringAction
    let denyAndReply: KeyringAction?
    let replyDraft: Binding<String>?
    let replyPrompt: String
    let onCancelReply: (() -> Void)?
    let onSendReply: (() -> Void)?
    let sendReplyTitle: String
    let busy: Bool
    @ViewBuilder let icon: () -> Icon

    public init(
        site: String,
        account: String? = nil,
        agent: String,
        machine: String,
        reason: String? = nil,
        footer: String? = nil,
        showBrandBar: Bool = false,
        onDismiss: (() -> Void)? = nil,
        compact: Bool = false,
        approve: KeyringAction?,
        inPlaceOfApprove: String? = nil,
        deny: KeyringAction,
        denyAndReply: KeyringAction? = nil,
        replyDraft: Binding<String>? = nil,
        replyPrompt: String = "Tell the agent what to do instead…",
        onCancelReply: (() -> Void)? = nil,
        onSendReply: (() -> Void)? = nil,
        sendReplyTitle: String = "Deny & Send",
        busy: Bool = false,
        @ViewBuilder icon: @escaping () -> Icon
    ) {
        self.site = site
        self.account = account
        self.agent = agent
        self.machine = machine
        self.reason = reason
        self.footer = footer
        self.showBrandBar = showBrandBar
        self.onDismiss = onDismiss
        self.compact = compact
        self.approve = approve
        self.inPlaceOfApprove = inPlaceOfApprove
        self.deny = deny
        self.denyAndReply = denyAndReply
        self.replyDraft = replyDraft
        self.replyPrompt = replyPrompt
        self.onCancelReply = onCancelReply
        self.onSendReply = onSendReply
        self.sendReplyTitle = sendReplyTitle
        self.busy = busy
        self.icon = icon
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? KeyringSpace.s3 : KeyringSpace.s4) {
            if showBrandBar {
                HStack(spacing: KeyringSpace.s2) {
                    KeyringKeyholeMark(size: 16, colour: KeyringPalette.brand)
                    KeyringText("Agent Keyring", as: .meta, colour: KeyringPalette.ink)
                    Spacer(minLength: 0)
                    if let onDismiss {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(KeyringPalette.ink2)
                                .frame(width: 22, height: 22)
                                .background(KeyringPalette.fill, in: .circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                    }
                }
            }

            HStack(alignment: .top, spacing: KeyringSpace.s3) {
                icon()
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    KeyringText(site, as: .heading, fit: .siteName)
                    if let account, !account.isEmpty {
                        KeyringText(account, as: .meta, fit: .siteName)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    KeyringText(agent, as: .meta, colour: KeyringPalette.ink)
                        .multilineTextAlignment(.trailing)
                    if !machine.isEmpty {
                        KeyringText(machine, as: .meta, colour: KeyringPalette.ink2)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .fixedSize(horizontal: true, vertical: true)
            }

            if let reason, !reason.isEmpty {
                KeyringText("“\(reason)”", as: .body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, KeyringSpace.s3)
                    .padding(.vertical, KeyringSpace.s2 + 2)
                    .background(KeyringPalette.fill, in: .rect(cornerRadius: 10, style: .continuous))
            }

            if let replyDraft {
                VStack(alignment: .leading, spacing: KeyringSpace.s2) {
                    KeyringReplyBox(text: replyDraft, prompt: replyPrompt)
                    HStack(spacing: KeyringSpace.s2) {
                        if let onCancelReply {
                            KeyringButton(.plain("Cancel", isEnabled: !busy, perform: onCancelReply))
                        }
                        if let onSendReply {
                            KeyringButton(.deny(sendReplyTitle, isEnabled: !busy, perform: onSendReply))
                        }
                    }
                    .environment(\.keyringButtonsFill, true)
                    .environment(\.keyringButtonTall, true)
                }
            } else {
                VStack(spacing: KeyringSpace.s2) {
                    if let denyAndReply {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: KeyringSpace.s2) {
                                KeyringButton(deny)
                                KeyringButton(denyAndReply)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            VStack(spacing: KeyringSpace.s2) {
                                KeyringButton(deny)
                                KeyringButton(denyAndReply)
                            }
                        }
                    } else {
                        KeyringButton(deny)
                    }
                    if let approve {
                        KeyringButton(approve)
                    } else if let inPlaceOfApprove {
                        KeyringText(inPlaceOfApprove, as: .meta)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .environment(\.keyringButtonsFill, true)
                .environment(\.keyringButtonTall, true)
            }

            if let footer, !footer.isEmpty {
                KeyringText(footer, as: .caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Wide horizontal waiting banner for Mac Activity: matches the full width of the Activity table
/// (~108 pt tall per request) so 1 request has zero dead space and 2–3 requests stack cleanly inside one grouped card.
public struct KeyringHorizontalApprovalBanner<Icon: View>: View {
    let site: String
    let account: String?
    let agent: String
    let machine: String
    let reason: String?
    let approve: KeyringAction
    let deny: KeyringAction
    let denyAndReply: KeyringAction
    let replyDraft: Binding<String>?
    let replyPrompt: String
    let onCancelReply: (() -> Void)?
    let onSendReply: (() -> Void)?
    let sendReplyTitle: String
    let busy: Bool
    @ViewBuilder let icon: () -> Icon

    public init(
        site: String,
        account: String? = nil,
        agent: String,
        machine: String,
        reason: String? = nil,
        approve: KeyringAction,
        deny: KeyringAction,
        denyAndReply: KeyringAction,
        replyDraft: Binding<String>? = nil,
        replyPrompt: String = "Tell the agent what to do instead…",
        onCancelReply: (() -> Void)? = nil,
        onSendReply: (() -> Void)? = nil,
        sendReplyTitle: String = "Deny & Send",
        busy: Bool = false,
        @ViewBuilder icon: @escaping () -> Icon
    ) {
        self.site = site
        self.account = account
        self.agent = agent
        self.machine = machine
        self.reason = reason
        self.approve = approve
        self.deny = deny
        self.denyAndReply = denyAndReply
        self.replyDraft = replyDraft
        self.replyPrompt = replyPrompt
        self.onCancelReply = onCancelReply
        self.onSendReply = onSendReply
        self.sendReplyTitle = sendReplyTitle
        self.busy = busy
        self.icon = icon
    }

    public var body: some View {
        HStack(alignment: .center, spacing: KeyringSpace.s5) {
            // Left zone: identity + requester + quoted reason well (uses full available horizontal width)
            VStack(alignment: .leading, spacing: KeyringSpace.s2) {
                HStack(alignment: .center, spacing: KeyringSpace.s3) {
                    icon()
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: KeyringSpace.s2) {
                            KeyringText(site, as: .heading, fit: .siteName)
                            if let account, !account.isEmpty {
                                KeyringText(account, as: .meta)
                                    .lineLimit(1)
                            }
                        }
                        KeyringText(machine.isEmpty ? agent : "\(agent) · \(machine)", as: .meta, colour: KeyringPalette.ink2)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let reason, !reason.isEmpty {
                    KeyringText("“\(reason)”", as: .body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, KeyringSpace.s3)
                        .padding(.vertical, 7)
                        .background(KeyringPalette.fill, in: .rect(cornerRadius: 10, style: .continuous))
                }

                if let replyDraft {
                    KeyringReplyBox(text: replyDraft, prompt: replyPrompt)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right zone: compact fixed-width action stack (never stretched across 1000 pt!)
            if replyDraft != nil {
                VStack(spacing: KeyringSpace.s2) {
                    if let onSendReply {
                        KeyringButton(.deny(sendReplyTitle, isEnabled: !busy, perform: onSendReply))
                    }
                    if let onCancelReply {
                        KeyringButton(.plain("Cancel", isEnabled: !busy, perform: onCancelReply))
                    }
                }
                .environment(\.keyringButtonsFill, true)
                .frame(width: 224)
            } else {
                VStack(spacing: KeyringSpace.s2) {
                    HStack(spacing: KeyringSpace.s2) {
                        KeyringButton(deny)
                        KeyringButton(denyAndReply)
                    }
                    KeyringButton(approve)
                }
                .environment(\.keyringButtonsFill, true)
                .frame(width: 248)
            }
        }
    }
}
#endif
