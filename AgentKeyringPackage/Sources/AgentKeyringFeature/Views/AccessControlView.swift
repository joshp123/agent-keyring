import SwiftUI

@available(macOS 26.0, *)
public struct AccessControlView: View {
    @State private var selection = Set<UUID>()
    @State private var isShowingAssistant = false
    private let controller: CredentialAccessController

    public init(controller: CredentialAccessController) {
        self.controller = controller
    }

    public var body: some View {
        @Bindable var controller = controller

        NavigationSplitView {
            AccessPolicySidebar(
                selectedPolicy: $controller.selectedPolicy,
                askCount: controller.count(for: .ask),
                automaticCount: controller.count(for: .allowAutomatically),
                blockedCount: controller.count(for: .block),
                openAssistant: { isShowingAssistant = true }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
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
                    searchText: controller.searchText,
                    selection: $selection,
                    sortOrder: $controller.sortOrder,
                    errorMessage: controller.errorMessage
                )
            } else {
                ContentUnavailableView(
                    "Choose an access group",
                    systemImage: "sidebar.left",
                    description: Text("Select one of the 3 policies in the sidebar.")
                )
            }
        }
        .frame(
            minWidth: 820,
            idealWidth: 960,
            maxWidth: 1_100,
            minHeight: 540,
            idealHeight: 680,
            maxHeight: 760
        )
        .searchable(
            text: $controller.searchText,
            placement: .toolbar,
            prompt: "Search this group"
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MovePolicyMenu(
                    currentPolicy: controller.selectedPolicy,
                    selectionCount: selection.count
                ) { policy in
                    Task {
                        await controller.setPolicy(policy, for: selection)
                        selection.removeAll()
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingAssistant, onDismiss: { selection.removeAll() }) {
            CredentialPolicyAssistantView(controller: controller)
        }
        .onChange(of: controller.selectedPolicy) {
            selection.removeAll()
        }
    }
}
