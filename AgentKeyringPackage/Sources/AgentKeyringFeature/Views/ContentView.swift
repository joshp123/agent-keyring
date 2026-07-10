import AuthenticationServices
import SwiftUI

@available(macOS 26.0, *)
public struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    private let model: MirrorAppModel

    public init(model: MirrorAppModel = MirrorAppModel()) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            windowGradient

            VStack(spacing: 18) {
                if let request = model.pendingCredentialRelease {
                    CredentialReleaseApprovalView(request: request)
                        .transition(.blurReplace)
                } else {
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
                    MirrorSecurityFooter()
                }
            }
            .padding(32)
            .animation(.snappy, value: model.pendingCredentialRelease)
        }
        .frame(width: model.pendingCredentialRelease == nil ? 780 : 560)
        .tint(.teal)
        .containerBackground(windowGradient, for: .window)
        .task { await model.loadStatus() }
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

@available(macOS 26.0, *)
private struct MirrorSecurityFooter: View {
    var body: some View {
        HStack(spacing: 14) {
            Label("Encrypted locally", systemImage: "lock.fill")
            Divider().frame(height: 12)
            Label("Apple Passwords stays primary", systemImage: "key.fill")
            Spacer()
            Label("Passkeys stay in Passwords", systemImage: "person.badge.key.fill")
        }
        .font(.callout)
        .fontWeight(.medium)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }
}
