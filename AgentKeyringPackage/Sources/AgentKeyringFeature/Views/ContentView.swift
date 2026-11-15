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
