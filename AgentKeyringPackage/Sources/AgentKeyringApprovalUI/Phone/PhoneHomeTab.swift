// Written by AI on 2026.11.18 by model Claude Opus 5.5; rebuilt on 2026.11.26
// by model gemini-4-neon; split into its own file on 2026.11.27 by model claude opus 5.5.
//
// Home tab: the shared approval card for waiting requests + airy 2-line settled
// rows identical to the Mac menu bar.

#if os(iOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

/// Activity: unified approval card for waiting requests + airy 2-line settled rows identical to Mac Menu Bar.
/// Tapping a settled row's chevron opens PhoneRequestView in read-only .settled mode (full reason, account, reply).
struct PhoneHomeView: View {
    let model: PhoneModel

    var body: some View {
        PhoneList(title: PhoneCopy.home) {
            if let stale = model.sheet.staleNotice {
                Section {
                    KeyringStatusLine(.done(stale), action: .link(PhoneCopy.ok) { model.dismissStaleNotice() })
                }
                .listRowBackground(KeyringPalette.surface)
            }
            if let join = model.snapshot.deviceJoin {
                Section { deviceJoinCard(join) }
                    .listRowBackground(KeyringPalette.surface)
            }
            if let problem = model.snapshot.notices.first {
                Section { KeyringStatusLine(.problem(PhoneCopy.notice(problem))) }
                    .listRowBackground(KeyringPalette.surface)
            }
            if !model.waiting.isEmpty {
                Section {
                    ForEach(model.waiting) { request in
                        waitingCard(request)
                    }
                } header: {
                    KeyringText(PhoneCopy.waitingForYou, as: .sectionName)
                }
                .listRowBackground(KeyringPalette.surface)
            }
            if !earlier.isEmpty {
                Section {
                    ForEach(earlier) { request in
                        Button {
                            model.openSettled(request.id)
                        } label: {
                            KeyringSettledActivityRow(
                                site: request.login.site,
                                subtitle: "\(request.agent.name) · \(request.agent.isLocal ? "This Mac" : request.agent.machine)",
                                time: AccessRequestCopy.clock(request.askedAt),
                                outcome: Self.outcomeStyle(request),
                                showChevron: true
                            ) {
                                SiteIconView(host: request.login.site, size: 24)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    KeyringText(PhoneCopy.earlierToday, as: .sectionName)
                }
                .listRowBackground(KeyringPalette.surface)
            } else if model.waiting.isEmpty {
                Section {
                    HStack(spacing: KeyringSpace.s3) {
                        KeyringMascot(.calm)
                            .frame(width: 40, height: 40)
                        KeyringText(PhoneCopy.nothingWaiting, as: .meta)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 2)
                }
                .listRowBackground(KeyringPalette.surface)
            }
        }
    }

    private func waitingCard(_ request: AccessRequest) -> some View {
        let busy = model.answering != nil
        return KeyringUnifiedApprovalCard(
            site: request.login.site,
            account: request.login.account.isEmpty ? nil : request.login.account,
            agent: request.agent.name,
            machine: request.agent.isLocal ? "This Mac" : request.agent.machine,
            reason: request.agentReason.isEmpty ? nil : request.agentReason,
            footer: model.snapshot.undelivered.contains(request.id) ? PhoneCopy.notDeliveredYet : nil,
            showBrandBar: false,
            compact: true,
            approve: .approve(PhoneCopy.approve, symbol: "faceid", isEnabled: !busy) { Task { await model.approveAccessRequest(request.id) } },
            deny: .deny(PhoneCopy.deny, isEnabled: !busy) { Task { await model.denyAccessRequest(request.id, withDraft: false) } },
            denyAndReply: .denySecondary(PhoneCopy.denyAndExplain, isEnabled: !busy) { model.explain(request.id) },
            busy: busy
        ) {
            SiteIconView(host: request.login.site, size: 28)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func deviceJoinCard(_ join: PhoneDeviceJoin) -> some View {
        switch join {
        case let .asked(name, isMac):
            let busy = model.isChangingRuleOrDevice
            VStack(alignment: .leading, spacing: KeyringSpace.s3) {
                HStack(alignment: .top, spacing: KeyringSpace.s3) {
                    Image(systemName: isMac ? "laptopcomputer" : "iphone")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(KeyringPalette.brand)
                        .frame(width: 36, height: 36)
                        .background(KeyringPalette.brandTint, in: .rect(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        KeyringText(PhoneCopy.addDeviceLead(isMac: isMac), as: .heading)
                        KeyringText(name, as: .meta, colour: KeyringPalette.ink)
                        KeyringText(PhoneCopy.addDeviceBody(isMac: isMac), as: .meta)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(spacing: KeyringSpace.s2) {
                    KeyringButton(.plain(PhoneCopy.dontAdd, isEnabled: !busy) { Task { await model.answerDeviceJoin(add: false) } })
                    KeyringButton(.approve(PhoneCopy.add, symbol: "faceid", isEnabled: !busy) { Task { await model.answerDeviceJoin(add: true) } })
                }
                .environment(\.keyringButtonsFill, true)
                .environment(\.keyringButtonTall, true)
            }
            .padding(.vertical, 4)
        case let .adding(name):
            KeyringStatusLine(.waiting(PhoneCopy.adding(name)))
        }
    }

    private var earlier: [AccessRequest] {
        model.snapshot.requests
            .filter { !$0.state.isWaitingForYou && !$0.state.isSending && Calendar.current.isDateInToday($0.askedAt) }
            .sorted { $0.askedAt > $1.askedAt }
    }

    static func outcomeStyle(_ request: AccessRequest) -> KeyringOutcomeStyle {
        if request.byAutomaticRule {
            return KeyringOutcomeStyle(word: "Auto-approved", symbol: "bolt.circle.fill", colour: KeyringPalette.approve)
        }
        let (outcome, word) = PhoneCopy.outcome(request.state)
        return switch outcome {
        case .approved:
            KeyringOutcomeStyle(word: word, symbol: "checkmark.circle.fill", colour: KeyringPalette.approve)
        case .denied:
            KeyringOutcomeStyle(word: word, symbol: "xmark.circle.fill", colour: KeyringPalette.deny)
        case .noAnswer:
            KeyringOutcomeStyle(word: word, symbol: "clock", colour: KeyringPalette.ink2)
        }
    }
}
#endif
