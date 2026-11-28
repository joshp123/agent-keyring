// Written by AI on 2026.11.18 by model Claude Opus 5.5; rebuilt on 2026.11.26
// by model gemini-4-neon; split into its own file on 2026.11.27 by model claude opus 5.5.
//
// One password's detail page and the Face ID rule-change confirmation sheet.

#if os(iOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

/// Face ID confirmation sheet listing the exact rule changes before applying immediately.
struct PhoneRuleConfirmSheet: View {
    let confirmation: PhoneModel.RuleConfirmation
    let isWorking: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var count: Int { confirmation.logins.count }
    private var hasMixedSourceRules: Bool { Set(confirmation.logins.map(\.rule)).count > 1 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(confirmation.logins) { login in
                        HStack(spacing: KeyringSpace.s3) {
                            SiteIconView(host: login.site, size: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                KeyringText(login.site, as: .heading, fit: .siteName)
                                if !login.account.isEmpty {
                                    KeyringText(login.account, as: .meta)
                                }
                                if hasMixedSourceRules {
                                    KeyringText("Was \(PhoneCopy.rule(login.rule))", as: .caption, colour: KeyringPalette.ink2)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    KeyringText("CHANGES (\(count))", as: .sectionName)
                } footer: {
                    KeyringText(PhoneCopy.ruleExplanation(confirmation.targetRule), as: .caption)
                }
                .listRowBackground(KeyringPalette.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(KeyringPalette.canvas)
            .navigationTitle("Set to \(PhoneCopy.rule(confirmation.targetRule))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(PhoneCopy.cancel, action: onCancel)
                        .disabled(isWorking)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    KeyringButton(
                        .approve(
                            isWorking ? PhoneCopy.approving : "Confirm with Face ID",
                            symbol: "faceid",
                            isEnabled: !isWorking,
                            perform: onConfirm
                        )
                    )
                    .environment(\.keyringButtonsFill, true)
                    .environment(\.keyringButtonTall, true)
                }
                .padding(KeyringSpace.s4)
                .background(.bar)
            }
        }
        .tint(KeyringPalette.brand)
    }
}

/// One password's detail: site icon + account, native trailing-checkmark rule list, and account-scoped history.
struct PhonePasswordDetailView: View {
    let model: PhoneModel
    let loginID: String

    private var login: PhoneLogin? {
        model.snapshot.logins.first { $0.id == loginID }
    }

    private var recentForSite: [AccessRequest] {
        guard let login else { return [] }
        return model.snapshot.requests
            .filter { req in
                guard !req.state.isWaitingForYou,
                      req.login.site.caseInsensitiveCompare(login.site) == .orderedSame else { return false }
                if !login.account.isEmpty && !req.login.account.isEmpty {
                    return req.login.account.caseInsensitiveCompare(login.account) == .orderedSame
                }
                return true
            }
            .sorted { $0.askedAt > $1.askedAt }
    }

    var body: some View {
        List {
            if let login {
                if !login.account.isEmpty || login.secretDeleted {
                    Section {
                        HStack(alignment: .center, spacing: KeyringSpace.s3) {
                            SiteIconView(host: login.site, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                if !login.account.isEmpty {
                                    KeyringText(login.account, as: .body)
                                }
                                if login.asked > 0 {
                                    KeyringText("\(login.asked.formatted()) asked", as: .meta)
                                }
                                if login.secretDeleted {
                                    KeyringText(MainWindowCopy.deletedWhenBlocked, as: .meta)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(KeyringPalette.surface)
                }

                Section {
                    ForEach([LoginRule.ask, .automatic, .blocked], id: \.self) { rule in
                        Button {
                            guard login.rule != rule else { return }
                            Task { await model.setLoginRule(rule, forLogin: login.id) }
                        } label: {
                            HStack(alignment: .center, spacing: KeyringSpace.s3) {
                                Image(systemName: rule.visual.symbol)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(rule.visual.tint)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    KeyringText(PhoneCopy.rule(rule), as: .heading)
                                    KeyringText(PhoneCopy.ruleExplanation(rule), as: .meta)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if login.rule == rule {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(KeyringPalette.brand)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isChangingRuleOrDevice)
                    }
                } header: {
                    KeyringText(PhoneCopy.agentAccess, as: .sectionName)
                }
                .listRowBackground(KeyringPalette.surface)

                Section {
                    if recentForSite.isEmpty {
                        KeyringText(PhoneCopy.noRequestsForPassword, as: .meta)
                    } else {
                        ForEach(recentForSite) { req in
                            let outcome = PhoneHomeView.outcomeStyle(req)
                            VStack(alignment: .leading, spacing: KeyringSpace.s1) {
                                HStack {
                                    KeyringText(PhoneCopy.historyDetail(req), as: .meta)
                                    Spacer(minLength: KeyringSpace.s2)
                                    KeyringOutcomeBadge(outcome)
                                }
                                if !req.agentReason.isEmpty {
                                    KeyringText(PhoneCopy.quoted(req.agentReason), as: .body)
                                }
                                if let reply = req.state.reply, !reply.isEmpty {
                                    KeyringText(AccessRequestCopy.youTold(req.agent.name, reply), as: .meta, colour: KeyringPalette.denyText)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    KeyringText(PhoneCopy.recentRequests, as: .sectionName)
                }
                .listRowBackground(KeyringPalette.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(KeyringPalette.canvas)
        .navigationTitle(login?.site ?? PhoneCopy.passwords)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
