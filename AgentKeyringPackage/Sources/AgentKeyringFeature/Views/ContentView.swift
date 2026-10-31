import AuthenticationServices
import AppKit
import SwiftUI

@available(macOS 26.0, *)
public struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
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
            IPhoneDevicesView(controller: model.accessControl)
            if model.accessControl.hasPairedApprovalDevice {
                HStack {
                    @Bindable var routingSettings = model.approvalRoutingSettings
                    Text("Ask on iPhone after")
                    TextField("Seconds", value: $routingSettings.phoneDelaySeconds, format: .number)
                        .frame(width: 60)
                    Text("seconds")
                }
            }
        }
        .padding(24)
        .frame(width: 720)
        .frame(minHeight: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(windowGradient)
        .tint(.teal)
        .containerBackground(windowGradient, for: .window)
        .task { await model.loadStatus() }
        .onContinueUserActivity(ASCredentialExchangeActivity) { activity in
            model.receive(activity)
        }
    }

    private var windowGradient: LinearGradient {
        let colours: [Color] =
            if colorScheme == .dark {
                [
                    Color(red: 0.04, green: 0.08, blue: 0.17),
                    Color(red: 0.04, green: 0.16, blue: 0.16),
                    Color(red: 0.11, green: 0.07, blue: 0.20),
                ]
            } else {
                [
                    Color(red: 0.93, green: 0.96, blue: 1.00),
                    Color(red: 0.90, green: 0.98, blue: 0.96),
                    Color(red: 0.96, green: 0.94, blue: 1.00),
                ]
            }
        return LinearGradient(
            colors: colours,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

@available(macOS 26.0, *)
private struct LeaseHistoryRecoveryView: View {
    let model: MirrorAppModel
    @State private var isResetting = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Task history could not be opened", systemImage: "exclamationmark.circle")
                .font(.headline)
            Text("Reset it to let agents ask again. This ends previous task access on this Mac. Your saved logins and access rules are kept.")
                .font(.callout)
            if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
            Button("Reset task history…") {
                Task {
                    isResetting = true
                    defer { isResetting = false }
                    do { try await model.resetLeaseHistory() }
                    catch { failure = "Task history wasn't reset: \(error.localizedDescription)" }
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
