import SwiftUI

@available(macOS 26.0, *)
public struct AccessControlView: View {
    @State private var selection = Set<UUID>()
    @State private var isShowingAssistant = false
    private let controller: CredentialAccessController

    public init(
        controller: CredentialAccessController,
        initialSelection: Set<UUID> = []
    ) {
        self.controller = controller
        _selection = State(initialValue: initialSelection)
    }

    public var body: some View {
        @Bindable var controller = controller

        VStack(spacing: 0) {
            if controller.needsConfirmation {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Confirm your access rules")
                            .font(.headline)
                        Text(controller.confirmationSummary)
                        if controller.confirmationResetsUnreadableRules {
                            Text("The rules file could not be read. Confirming resets every login to Ask each time. Nothing will be released until then.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Review the rules below. Nothing will be released until you confirm with Touch ID or Apple Watch.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Confirm your access rules") {
                        Task { await controller.confirmRules() }
                    }
                    .disabled(!controller.canConfirmRules)
                }
                .padding()
                Divider()
            }
            HSplitView {
                AccessPolicySidebar(
                    selectedPolicy: $controller.selectedPolicy,
                    askCount: controller.count(for: .ask),
                    automaticCount: controller.count(for: .allowAutomatically),
                    blockedCount: controller.count(for: .block),
                    openAssistant: { isShowingAssistant = true }
                )
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)

                Group {
                    if controller.rows.isEmpty {
                        ContentUnavailableView(
                            "No logins yet",
                            systemImage: "key.horizontal",
                            description: Text("Import logins from Apple Passwords first.")
                        )
                    } else if let selectedPolicy = controller.selectedPolicy {
                        AccessPolicyDetailView(
                            policy: selectedPolicy,
                            rows: controller.visibleRows,
                            searchText: $controller.searchText,
                            selection: $selection,
                            errorMessage: controller.errorMessage,
                            changePolicy: { policy in
                                Task {
                                    await controller.setPolicy(policy, for: selection)
                                    selection.removeAll()
                                }
                            }
                        )
                        .disabled(controller.needsConfirmation || controller.isSavingRules)
                    } else {
                        ContentUnavailableView(
                            "Choose an access rule",
                            systemImage: "sidebar.left",
                            description: Text("Select one of the three rules in the sidebar.")
                        )
                    }
                }
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(
            minWidth: 760,
            idealWidth: 1_080,
            minHeight: 520,
            idealHeight: 720
        )
        .sheet(isPresented: $isShowingAssistant, onDismiss: { selection.removeAll() }) {
            CredentialPolicyAssistantView(controller: controller)
        }
        .onChange(of: controller.selectedPolicy) {
            selection.removeAll()
        }
    }
}
