// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The rules window (RFC 0007, U3): the shared rules view over the existing
// access-rules controller, with its AI assistant as a sheet.

import AgentKeyringApprovalUI
import AgentKeyringFeature
import AgentKeyringScreenBackends
import SwiftUI

struct RulesWindow: View {
    private let model: MirrorAppModel
    @State private var rules: MacRulesModel
    @State private var showingAssistant = false

    init(model: MirrorAppModel) {
        self.model = model
        let backend = AccessRulesBackend(model: model)
        self.rules = MacRulesModel(backend: backend, initial: backend.snapshot())
    }

    var body: some View {
        MacRulesView(model: rules)
            .frame(minWidth: 760, minHeight: 480)
            .onAppear { rules.openAssistant = { showingAssistant = true } }
            .sheet(isPresented: $showingAssistant) {
                CredentialPolicyAssistantView(controller: model.accessControl)
            }
    }
}
