// Written by AI on 2026.11.21 by model claude opus 5.5; moved onto the
// sandbox world on 2026.11.27 by the same model.
//
// The Mac's everyday pages for the cut-off check (PageGallery): Devices,
// Passwords, Sort with AI and the menu bar window, in each state worth
// seeing, with the longest words each holds. Each runs on the built-in
// sandbox world, changed only as far as the state needs.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

@MainActor
enum MacEverydayGallery {
    static var entries: [KeyringGalleryEntry] {
        devices + passwords + menuBar
    }

    private static let menuWidth: CGFloat = 460
    private static let longMacName = "Research Team MacBook Pro"

    /// The built-in world, seen from its MacBook Pro.
    private static func world(_ change: (inout SandboxState) -> Void = { _ in }) -> SandboxWorld {
        var state = SandboxState.builtIn()
        state.thisDeviceID = "macbook"
        change(&state)
        return SandboxWorld(state)
    }

    private static func main(_ world: SandboxWorld) -> MacMainModel {
        MacMainModel(backend: SandboxMainBackend(world), initial: world.state.macSnapshot)
    }

    private static func window(_ model: MacMainModel) -> some View {
        MacMainWindowView(model: model) { _, _ in AnyView(EmptyView()) }.frame(height: 680)
    }

    /// Only the requests already answered.
    private static func earlier(_ state: inout SandboxState) {
        state.requests.removeAll { $0.request.state.isWaitingForYou }
    }

    // MARK: Devices

    private static var devices: [KeyringGalleryEntry] {
        let width = KeyringGalleryEntryKind.macPanel(width: KeyringSize.macWindow.width)
        return [
            // Devices scrolls in the window, so it is checked to its last row.
            .init("devices-iphone-practice-under-way", width) {
                MacDevicesTab(model: main(world { state in
                    state.devices[2].name = longMacName
                    state.practice = ["iphone": .sending, "watch": .withApple]
                    state.computers[2].name = "build-server.example"
                }))
            },
            .init("devices-practice-answered", width) {
                MacDevicesTab(model: main(world { state in
                    state.devices[2].name = longMacName
                    state.devices.append(.init(id: "work-iphone", name: "Work iPhone", kind: .iPhone))
                    state.computers.removeAll { $0.id == "linux" }
                    state.practice = ["macbook": .approved, "iphone": .denied, "watch": .noAnswer,
                                      "work-iphone": .failed(MessageCopy.noPushAddress("Work iPhone"))]
                }))
            },
            .init("devices-this-mac-alone-no-push-key", width) {
                MacDevicesTab(model: main(world { state in
                    state.devices = [.init(id: "macbook", name: longMacName, kind: .mac)]
                    state.computers = [SandboxComputer(id: "macbook-agents", name: longMacName, pairedDeviceID: "macbook")]
                    state.practice = ["macbook": .waitingHere]
                    state.mac.noPushKey = true
                }))
            },
            .init("devices-changes-not-sent", width) {
                MacDevicesTab(model: main(world { state in
                    state.devices.removeAll { $0.kind == .watch }
                    state.computers.removeAll { $0.id == "linux" }
                    state.mac.unsentChanges = 1_249
                }))
            },
            .init("devices-no-icloud-open-at-login", width) {
                MacDevicesTab(model: main(world { state in
                    state.devices.removeAll { $0.kind == .watch }
                    state.computers.removeAll { $0.id == "linux" }
                    state.readiness = ["iphone": .waitingForNotifications]
                    state.mac.signedOutOfICloud = true
                    state.mac.opensAtLogin = true
                }))
            },
            .init("devices-window", .macPanel(width: 1120)) {
                let model = main(world { state in
                    earlier(&state)
                    state.practice = ["iphone": .approved]
                })
                model.destination = .devices
                return window(model)
            },
        ]
    }

    // MARK: Passwords, Activity and Settings

    private static var passwords: [KeyringGalleryEntry] { [
        .init("passwords", .macPanel(width: 1160)) { window(main(world(earlier))) },
        .init("passwords-edit-mode", .macPanel(width: 1160)) {
            let model = main(world(earlier))
            model.beginEditingRules()
            model.toggleEditSelection(model.snapshot.logins[1].id)
            return window(model)
        },
        .init("activity", .macPanel(width: 1120)) {
            let model = main(world())
            model.destination = .activity
            return window(model)
        },
        .init("settings", .macPanel(width: 520)) {
            MacSettingsView(model: main(world { state in
                state.mac.remindsToUpdate = true
                state.mac.opensAtLogin = true
            }))
        },
        .init("passwords-filtered-blocked", .macWindow) {
            let model = main(world(earlier))
            model.ruleFilter = .blocked
            return MacPasswordsTab(model: model)
        },
        .init("passwords-stale-copy-with-reminder", .macWindow) {
            MacPasswordsTab(model: main(world { state in
                state.mac.copyIsStale = true
                state.mac.remindsToUpdate = false
            }))
        },
        .init("passwords-copy-changed-nothing", .macWindow) {
            MacPasswordsTab(model: main(world { state in
                state.mac.copyChangedNothing = true
                state.mac.remindsToUpdate = false
            }))
        },
        .init("passwords-unblocking-deleted-password", .macWindow) {
            let model = main(world())
            model.beginEditingRules()
            if let deleted = model.snapshot.logins.first(where: { $0.rule == .blocked }) { model.toggleEditSelection(deleted.id) }
            return MacPasswordsTab(model: model)
        },
        .init("passwords-test-password-only", .macWindow) {
            MacPasswordsTab(model: main(world { state in
                state.logins = state.logins.filter(\.isTestPassword)
                state.importedAt = nil
                state.mac.sampleOnly = true
            }))
        },
    ] }

    // MARK: The menu bar window

    private static func menu(_ world: SandboxWorld) -> MacMenuBarView {
        MacMenuBarView(model: MacMenuBarModel(backend: SandboxMenuBackend(world), initial: world.state.menuSnapshot))
    }

    private static var menuBar: [KeyringGalleryEntry] {
        let width = KeyringGalleryEntryKind.macPanel(width: menuWidth)
        return [
            .init("menu-bar-waiting-in-use-earlier", width) { menu(world()) },
            .init("menu-bar-replying", width) {
                let replying = world { $0.requests = Array($0.requests.prefix(3)) }
                return MacMenuBarView(model: MacMenuBarModel(backend: SandboxMenuBackend(replying), initial: replying.state.menuSnapshot),
                                      initialReplyingRequestID: "r1", initialReplyDraft: "Use the invoice already in Downloads instead.")
            },
            .init("menu-bar-longest", width) {
                menu(world { state in
                    state.logins = Array(state.logins.prefix(1))
                    state.requests = [SandboxRequest(AccessRequest(
                        id: "long", login: RequestedLogin(site: "accounts.longcompany-example.example", account: "you@example.com"),
                        agent: RequestingAgent(name: "Research Assistant for Bookkeeping", machine: longMacName, address: ""),
                        access: .login, agentReason: "You asked me to download October’s invoice from the billing page and attach it to the expenses report.",
                        askedAt: SandboxState.fixedClock().addingTimeInterval(-120), state: .waitingForYou(until: .now.addingTimeInterval(500))))]
                    state.enrolments = [DeviceEnrolment(id: "j", kind: .machine, name: "build-server.example", code: "", askedAt: SandboxState.fixedClock())]
                })
            },
            .init("menu-bar-all-quiet", width) {
                menu(world { state in
                    earlier(&state)
                    state.requests = Array(state.requests.prefix(3))
                })
            },
        ]
    }
}
#endif
