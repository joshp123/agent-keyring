import AuthenticationServices
import AppKit
import SwiftUI

@available(macOS 26.0, *)
public struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    private let model: MirrorAppModel

    public init(model: MirrorAppModel = MirrorAppModel()) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 18) {
            if model.leaseStore.needsHistoryReset {
                LeaseHistoryRecoveryView(model: model)
            }
            MirrorStatusPanel(
                status: model.status,
                isLoading: model.isLoading,
                isImporting: model.isImporting,
                providerState: model.providerState,
                notice: model.notice,
                enableProvider: model.requestProviderEnablement,
                openPasswords: model.openPasswords,
                manageAccess: { openWindow(id: "access") }
            )
            Toggle("Show example.com login", isOn: Binding(
                get: { model.includeExampleCredential },
                set: { enabled in
                    Task { await model.setIncludeExampleCredential(enabled) }
                }
            ))
            .toggleStyle(.checkbox)

        }
        .padding(24)
        .frame(width: 720)
        .frame(minHeight: 440)
        .fixedSize(horizontal: false, vertical: true)
        .tint(.blue)
        .task { await model.loadStatus() }
        .onContinueUserActivity(ASCredentialExchangeActivity) { activity in
            model.receive(activity)
        }
    }
}

@available(macOS 26.0, *)
private struct LeaseHistoryRecoveryView: View {
    let model: MirrorAppModel
    @State private var isResetting = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Agents are paused on this Mac", systemImage: "exclamationmark.circle")
                .font(.headline)
            Text(model.leaseStore.errorMessage ?? "Agent Keyring can't read its record of what agents are using. Reset the record to let them ask again. This ends any access agents have now. Your logins and rules stay.")
                .font(.callout)
            if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
            Button("Reset…") {
                Task {
                    isResetting = true
                    defer { isResetting = false }
                    do { try await model.resetLeaseHistory() }
                    catch { failure = "The record wasn't reset: \(error.localizedDescription)" }
                }
            }
            .disabled(isResetting)
            .accessibilityIdentifier("reset-task-history")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }
}
