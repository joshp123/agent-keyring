// Written by AI on 2026.11.21 by model Claude Opus 5.5.
//
// Every iPhone page in each state worth seeing, on the built-in sandbox world,
// for the cut-off check (PageGallery). A state missing here is one nobody has looked at.

#if os(iOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

@MainActor
enum PhoneGallery {
    static func model(_ step: String?) -> PhoneModel {
        let world = SandboxWorld()
        if let step { world.set { $0.showPhone(step: step) } }
        return PhoneModel(backend: world, initial: world.phoneSnapshot)
    }

    static var entries: [KeyringGalleryEntry] {
        let pages = (SandboxState.phoneFirstRunSteps + SandboxState.phoneWatchSteps).map { step in
            KeyringGalleryEntry("iphone-\(step)", .phone) {
                let model = model(step)
                PhoneFirstRunView(stage: model.snapshot.firstRun, model: model)
            }
        }
        let request = model(nil)
        return pages + [
            KeyringGalleryEntry("iphone-request-decide", .phone) {
                PhoneRequestView(model: request, request: request.snapshot.requests[0], mode: .decide)
            },
            KeyringGalleryEntry("iphone-request-approving", .phone) {
                PhoneRequestView(model: request, request: request.snapshot.requests[0], mode: .approving)
            },
            KeyringGalleryEntry("iphone-request-explain", .phone) {
                PhoneRequestView(model: request, request: request.snapshot.requests[0], mode: .explain)
            },
            KeyringGalleryEntry("iphone-request-practice-decide", .phone) {
                PhoneRequestView(model: request, request: .practiceAccessRequest(), mode: .decide, practice: true)
            },
            KeyringGalleryEntry("iphone-request-practice-explain", .phone) {
                PhoneRequestView(model: request, request: .practiceAccessRequest(), mode: .explain, practice: true)
            },
            KeyringGalleryEntry("iphone-held-notification", .phone) { PhoneNotificationCard(request: request.snapshot.requests[0]) },
            KeyringGalleryEntry("iphone-home", .phone) { PhoneHomeView(model: model(nil)) },
            KeyringGalleryEntry("iphone-home-empty", .phone) { PhoneHomeView(model: model("empty")) },
            KeyringGalleryEntry("iphone-home-mac-joining", .phone) { PhoneHomeView(model: model("mac-joining")) },
            KeyringGalleryEntry("iphone-passwords", .phone) { PhoneLoginsView(model: model(nil)) },
            KeyringGalleryEntry("iphone-devices", .phone) { PhoneDevicesView(model: model(nil)) },
            KeyringGalleryEntry("iphone-settings", .phone) { PhoneSettingsView(model: model(nil)) },
            KeyringGalleryEntry("iphone-copy-from-passwords", .phone) { PhoneCopyPasswordsPage(model: model(nil), inFirstRun: false) },
        ] + addComputer
    }

    /// Adding another computer from this iPhone, in each state.
    static var addComputer: [KeyringGalleryEntry] {
        let states: [(String, PhoneAddComputer)] = [
            ("invite", .invite(code: "7K2M-9QXD-4HPR-T3VN-8WBC-6J", command: DeviceSheetCopy.enrolCommand("7K2M-9QXD-4HPR-T3VN-8WBC-6J"),
                               until: .now.addingTimeInterval(600))),
            ("asked", .asked(name: "Mac mini")), ("added", .added(name: "Mac mini")), ("expired", .expired),
        ]
        return states.map { name, state in
            KeyringGalleryEntry("iphone-add-computer-\(name)", .phone) {
                PhoneAddComputerContent(state: state, tap: { _ in })
            }
        }
    }
}
#endif
