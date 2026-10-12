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
        ZStack {
            windowGradient

            VStack(spacing: 18) {
                FillAccessibilityStep(onboarding: model.fillAccessibility)
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
        }
        .frame(width: 720)
        .frame(minHeight: 440)
        .tint(.teal)
        .containerBackground(windowGradient, for: .window)
        .task { await model.loadStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.fillAccessibility.refresh() } }
        }
        .onContinueUserActivity(ASCredentialExchangeActivity) { activity in
            model.receive(activity)
        }
        .onOpenURL { url in
            model.receiveAgentRequest(url)
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

private struct FillAccessibilityStep: View {
    let onboarding: FillAccessibilityOnboarding

    var body: some View {
        if onboarding.state == .permissionRequired {
            VStack(alignment: .leading, spacing: 8) {
                Button("Allow Agent Keyring to fill sign-in forms") {
                    Task { await onboarding.requestPermission() }
                }
                .accessibilityIdentifier("allow-sign-in-filling")
                Text("Turn on Agent Keyring in Accessibility settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if onboarding.state == .serviceUnavailable {
            Text("Agent Keyring’s fill service could not be reached.")
                .font(.callout)
        }
    }
}
