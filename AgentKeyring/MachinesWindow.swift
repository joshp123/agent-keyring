// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The Machines window (RFC 0007 U4): the shared view over the relay approver.

import AgentKeyringApprovalUI
import AgentKeyringFeature
import AgentKeyringScreenBackends
import SwiftUI

struct MachinesWindow: View {
    @State private var machines: MacMachinesModel
    private let approvals: ApprovalPresenter

    init(relay: RelayApprover, routing: ApprovalRoutingSettings, approvals: ApprovalPresenter) {
        self.approvals = approvals
        let backend = RelayMachinesBackend(relay: relay, routing: routing)
        self.machines = MacMachinesModel(backend: backend, initial: backend.snapshot())
    }

    var body: some View {
        MacMachinesView(model: machines)
            .onAppear { machines.review = { approvals.present(enrolmentID: $0) } }
    }
}
