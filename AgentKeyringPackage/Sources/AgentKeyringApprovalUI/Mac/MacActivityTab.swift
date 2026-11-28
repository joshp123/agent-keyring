// Written by AI on 2026.11.18 by model claude opus 5.5; rebuilt on 2026.11.26
// by model gemini-4-neon; split into its own file on 2026.11.27 by model claude opus 5.5.
//
// Mac Activity: full-width horizontal waiting banners matching table width + 7-column TODAY/EARLIER table.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

/// Mac Activity: full-width horizontal waiting banner(s) matching table width + 7 atomic columns (TODAY & EARLIER).
public struct MacActivityTab: View {
    private enum InlineReplyState: Equatable {
        case idle
        case composing(requestID: String, draft: String)
    }

    @Bindable var model: MacMainModel
    @State private var inlineReply: InlineReplyState = .idle

    public init(model: MacMainModel, initialReplyingRequestID: String? = nil, initialReplyDraft: String = "") {
        self.model = model
        if let initialReplyingRequestID {
            _inlineReply = State(initialValue: .composing(requestID: initialReplyingRequestID, draft: initialReplyDraft))
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KeyringSpace.s5) {
                if model.waitingCount == 0 && model.todayRequests.isEmpty && model.earlierRequests.isEmpty {
                    VStack(spacing: KeyringSpace.s3) {
                        KeyringMascot(.calm)
                            .frame(width: 64, height: 64)
                        KeyringText(
                            model.activitySearch.isEmpty ? MainWindowCopy.noActivityYet : "No activity matching “\(model.activitySearch)”",
                            as: .heading
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, KeyringSpace.s10)
                } else {
                    if model.waitingCount > 0 {
                        VStack(alignment: .leading, spacing: KeyringSpace.s2) {
                            KeyringText(
                                model.waitingCount == 1 ? MenuBarCopy.waitingForYou : "\(MenuBarCopy.waitingForYou) (\(model.waitingCount))",
                                as: .sectionName
                            )
                            VStack(spacing: 0) {
                                ForEach(Array(model.snapshot.enrolments.enumerated()), id: \.element.id) { index, enrolment in
                                    if index > 0 { Divider() }
                                    KeyringDeviceRow(
                                        symbol: enrolment.kind == .machine ? "desktopcomputer" : "iphone",
                                        name: enrolment.name,
                                        detail: SetupCopy.joiningDetail(enrolment)
                                    ) {
                                        HStack(spacing: KeyringSpace.s2) {
                                            KeyringButton(.plain(MenuBarCopy.dontAdd, isEnabled: !model.isWorking) {
                                                model.denyEnrolment(enrolment.id)
                                            })
                                            KeyringButton(.approve(MenuBarCopy.add, symbol: MacApprover.symbol, isEnabled: !model.isWorking) {
                                                model.approveEnrolment(enrolment.id)
                                            })
                                        }
                                        .fixedSize()
                                    }
                                    .padding(.horizontal, KeyringSpace.s4)
                                    .padding(.vertical, KeyringSpace.s3)
                                }
                                ForEach(Array(model.waitingRequests.enumerated()), id: \.element.id) { index, request in
                                    if index > 0 || !model.snapshot.enrolments.isEmpty { Divider() }
                                    waitingBanner(request)
                                        .padding(.horizontal, KeyringSpace.s4)
                                        .padding(.vertical, KeyringSpace.s3 + 2)
                                }
                            }
                            .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card, style: .continuous))
                            .clipShape(.rect(cornerRadius: KeyringRadius.card, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card, style: .continuous).strokeBorder(KeyringPalette.line))
                        }
                    }

                    if !model.todayRequests.isEmpty {
                        activitySection("TODAY", items: model.todayRequests, isEarlier: false)
                    }
                    if !model.earlierRequests.isEmpty {
                        activitySection("EARLIER", items: model.earlierRequests, isEarlier: true)
                    }
                }
            }
            .padding(.horizontal, KeyringSpace.s6)
            .padding(.vertical, KeyringSpace.s5)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(KeyringPalette.canvas)
        .searchable(text: $model.activitySearch, placement: .toolbar, prompt: Text("Search activity"))
    }

    private func waitingBanner(_ request: AccessRequest) -> some View {
        let isReplying: Bool = if case let .composing(id, _) = inlineReply { id == request.id } else { false }
        let busy = model.workState == .answeringRequest(request.id)
        let draftBinding = Binding<String>(
            get: { if case let .composing(id, text) = inlineReply, id == request.id { return text }; return "" },
            set: { inlineReply = .composing(requestID: request.id, draft: $0) }
        )
        let approveSymbol = ReviewRendering.isOn
            ? MacApprover.symbol
            : (AccessRequestCopy.approveSymbol(MacApprover.shared.approver) ?? MacApprover.symbol)
        return KeyringHorizontalApprovalBanner(
            site: request.login.site,
            account: request.login.account.isEmpty ? nil : request.login.account,
            agent: request.agent.name,
            machine: request.agent.isLocal ? "This Mac" : request.agent.machine,
            reason: request.agentReason.isEmpty ? nil : request.agentReason,
            approve: .approve(MenuBarCopy.approve, symbol: approveSymbol, isEnabled: !busy) {
                model.approveAccessRequest(request.id)
            },
            deny: .deny(MenuBarCopy.deny, isEnabled: !busy) {
                model.denyAccessRequest(request.id, reply: nil)
            },
            denyAndReply: .denySecondary(MenuBarCopy.denyAndReply, isEnabled: !busy) {
                inlineReply = .composing(requestID: request.id, draft: "")
            },
            replyDraft: isReplying ? draftBinding : nil,
            replyPrompt: MenuBarCopy.replyPrompt,
            onCancelReply: { inlineReply = .idle },
            onSendReply: {
                let text = draftBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                inlineReply = .idle
                model.denyAccessRequest(request.id, reply: text.isEmpty ? nil : text)
            },
            sendReplyTitle: MenuBarCopy.sendReply,
            busy: busy
        ) {
            SiteIconView(host: request.login.site, size: 28)
        }
    }

    /// 7 atomic columns: Time | Website | Account | Agent | Computer | Reason (agent reason ONLY!) | Outcome.
    private func activitySection(_ title: String, items: [AccessRequest], isEarlier: Bool) -> some View {
        VStack(alignment: .leading, spacing: KeyringSpace.s2) {
            KeyringText(title, as: .sectionName)
            VStack(spacing: 0) {
                HStack(spacing: KeyringSpace.s3) {
                    KeyringText(MainWindowCopy.timeColumn, as: .meta).frame(width: 68, alignment: .leading)
                    KeyringText(MainWindowCopy.website, as: .meta).frame(width: 170, alignment: .leading)
                    KeyringText("Account", as: .meta).frame(width: 164, alignment: .leading)
                    KeyringText(MainWindowCopy.agentColumn, as: .meta).frame(width: 92, alignment: .leading)
                    KeyringText("Computer", as: .meta).frame(width: 92, alignment: .leading)
                    KeyringText(MainWindowCopy.reasonColumn, as: .meta).frame(maxWidth: .infinity, alignment: .leading)
                    KeyringText(MainWindowCopy.outcomeColumn, as: .meta).frame(width: 114, alignment: .leading)
                }
                .padding(.horizontal, KeyringSpace.s3)
                .padding(.vertical, 8)
                .background(KeyringPalette.fill.opacity(0.65))

                ForEach(items) { req in
                    Divider()
                    HStack(alignment: .top, spacing: KeyringSpace.s3) {
                        KeyringText(Self.timeLabel(req.askedAt, isEarlier: isEarlier), as: .meta)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(width: 68, alignment: .leading)

                        HStack(alignment: .top, spacing: 6) {
                            SiteIconView(host: req.login.site, size: 18)
                                .padding(.top, 1)
                            // Full dot-wrapped host: never truncates distinguishing subdomains!
                            KeyringText(req.login.site, as: .heading, fit: .siteName)
                        }
                        .frame(width: 170, alignment: .leading)

                        KeyringText(
                            req.login.account.isEmpty ? "No username" : req.login.account,
                            as: .meta,
                            colour: req.login.account.isEmpty ? KeyringPalette.ink3 : KeyringPalette.ink2
                        )
                        .lineLimit(1)
                        .frame(width: 164, alignment: .leading)

                        KeyringText(req.agent.name, as: .body)
                            .lineLimit(1)
                            .frame(width: 92, alignment: .leading)

                        KeyringText(req.agent.isLocal ? "This Mac" : req.agent.machine, as: .meta)
                            .lineLimit(1)
                            .frame(width: 92, alignment: .leading)

                        // One field per cell: agent reason only (no denial replies jammed in!).
                        KeyringText(req.agentReason.isEmpty ? "-" : req.agentReason, as: .body, colour: req.agentReason.isEmpty ? KeyringPalette.ink3 : KeyringPalette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        KeyringOutcomeBadge(MacMenuBarView.outcomeStyle(req))
                            .frame(width: 114, alignment: .leading)
                    }
                    .padding(.horizontal, KeyringSpace.s3)
                    .padding(.vertical, 9)
                }
            }
            .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card, style: .continuous))
            .clipShape(.rect(cornerRadius: KeyringRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card, style: .continuous).strokeBorder(KeyringPalette.line))
        }
    }

    private static func timeLabel(_ date: Date, isEarlier: Bool) -> String {
        if !isEarlier { return AccessRequestCopy.clock(date) }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
#endif
