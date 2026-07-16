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

        HSplitView {
            AccessPolicySidebar(
                selectedPolicy: $controller.selectedPolicy,
                askCount: controller.count(for: .ask),
                automaticCount: controller.count(for: .allowAutomatically),
                blockedCount: controller.count(for: .block),
                openAssistant: { isShowingAssistant = true }
            )
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 300)

            Group {
                if controller.rows.isEmpty {
                    ContentUnavailableView(
                        "No mirrored credentials",
                        systemImage: "key.horizontal",
                        description: Text("Refresh from Apple Passwords before setting access rules.")
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
