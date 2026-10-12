import AgentKeyringApprovalCore
import SwiftUI

struct PhoneApprovalView: View {
    let model: PhoneApprovalModel

    var body: some View {
        NavigationStack {
            List {
                PhoneStatusSection(iCloudStatus: model.iCloudStatus, notificationStatus: model.notificationStatus)
                PhoneKeySection(fingerprint: model.keyFingerprint, status: model.keyStatus)
                PhoneDecisionsSection(decisions: model.decisions, failure: model.lastFailure)
            }
            .navigationTitle("Agent Keyring")
        }
    }
}

private struct PhoneStatusSection: View {
    let iCloudStatus: String
    let notificationStatus: String

    var body: some View {
        Section("Connection") {
            LabeledContent("iCloud", value: iCloudStatus)
            LabeledContent("Notifications", value: notificationStatus)
        }
    }
}

private struct PhoneKeySection: View {
    let fingerprint: String?
    let status: String

    var body: some View {
        Section {
            if let fingerprint {
                Text(fingerprint)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text(status).foregroundStyle(.secondary)
            }
        } header: {
            Text("Public key fingerprint")
        } footer: {
            Text("SHA-256. Pair this phone with your Mac before approving logins.")
        }
    }
}

private struct PhoneDecisionsSection: View {
    let decisions: [PhoneDecisionHistoryEntry]
    let failure: String?

    var body: some View {
        Section("Recent decisions") {
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
            if decisions.isEmpty {
                Text("No decisions yet").foregroundStyle(.secondary)
            }
            ForEach(decisions) { decision in
                PhoneDecisionRow(decision: decision)
            }
        }
    }
}

private struct PhoneDecisionRow: View {
    let decision: PhoneDecisionHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                switch decision.choice {
                case .approve: Text("Approve")
                case .deny: Text("Deny")
                case .blockThisLogin: Text("Block this login")
                }
                Spacer()
                if decision.sent {
                    Text("Sent").foregroundStyle(.secondary)
                } else {
                    Text("Failed").foregroundStyle(.red)
                }
            }
            Text(decision.time, format: .dateTime.month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
