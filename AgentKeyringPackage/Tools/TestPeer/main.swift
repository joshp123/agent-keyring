// Written by AI on 2026.11.27 by model gpt-6.2-sol.

#if os(macOS) && DEBUG
import AgentKeyringApprovalCore
import AgentKeyringEngine
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication

struct PeerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Options {
    let directory: URL
    let socket: URL
    let relay: RelayBoxClient
    let apns: URL

    init(_ arguments: [String]) throws {
        let usage = "Usage: TestPeer --dir DIR --socket PATH --relay http://127.0.0.1:PORT --apns DIR"
        guard arguments.count == 8 else { throw PeerError(usage) }
        var flags: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            flags[arguments[index]] = arguments[index + 1]
        }
        guard let dir = flags["--dir"], let sock = flags["--socket"], let address = flags["--relay"], let apns = flags["--apns"],
              !dir.isEmpty, !sock.isEmpty, let url = URL(string: address),
              url.scheme == "http", url.host == "127.0.0.1", url.port != nil else { throw PeerError(usage) }
        RelayBoxClient.acceptsLoopbackForTests = true
        guard let relay = RelayBoxClient(checking: address) else { throw PeerError(usage) }
        self.relay = relay
        self.apns = URL(fileURLWithPath: apns, isDirectory: true)
        directory = URL(fileURLWithPath: dir, isDirectory: true)
        socket = URL(fileURLWithPath: sock)
    }
}

private func readIfPresent(_ file: URL) throws -> Data? {
    do { return try Data(contentsOf: file) }
    catch CocoaError.fileReadNoSuchFile { return nil }
}

@MainActor
final class PeerRuleClock {
    var date: Date?
}

@MainActor
final class TestPeer {
    let model: MacKeyringEngine
    let device: MacSyncCoordinator
    let cloud = InMemoryCloudPipe()
    let invitation = PeerInvitation()
    let ruleClock = PeerRuleClock()
    let pushes: RecordedPushes
    let directory: URL
    var phone: PhoneKeyringEngine?

    init(options: Options, settings: UserDefaults) throws {
        let dir = options.directory
        directory = dir
        pushes = RecordedPushes(directory: options.apns)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tlsFile = dir.appending(path: "tls.pb")
        let tls = try DeviceTLSIdentity.loadOrCreate(
            read: { try readIfPresent(tlsFile) },
            write: { try $0.write(to: tlsFile, options: .atomic) }
        )
        let keyFile = dir.appending(path: "keys.pb")
        let keys = try MacKeys.loadMacKeys(softwareKeyFile: keyFile, tls: tls)
            ?? MacKeys.make(.biometricOrCompanion, softwareKeyFile: keyFile, tls: tls)
        let policyFile = dir.appending(path: "rules.pb")
        let ruleStore = LoginRuleStore(
            read: { try readIfPresent(policyFile) },
            write: { try $0.write(to: policyFile, options: .atomic) }
        )
        model = MacKeyringEngine(
            store: MacVaultFileStore(directory: dir.appending(path: "logins")),
            bridge: AgentBridgeDirectory(socketURL: options.socket),
            accessControl: CredentialAccessController(store: ruleStore, now: { [ruleClock] in ruleClock.date ?? .now }),
            leaseStore: CredentialLeaseStore(persistence: LeasePersistence(directory: dir.appending(path: "leases"))),
            usage: PasswordUsageLog(file: dir.appending(path: "usage.pb")),
            settings: settings
        )
        model.enableBackgroundOnDeviceSorting = false
        var environment = MacSyncEnvironment(storage: .files(in: dir.appending(path: "device")))
        environment.relay = options.relay
        environment.cloud = cloud
        environment.invitationStore = CloudKeychainInvitationStore(read: { [invitation] in invitation.card },
                                                                   write: { [invitation] in invitation.card = $0; return true })
        environment.gateway = try pushes.gateway()

        environment.pushRelayURL = nil
        environment.complaints = dir.appending(path: "complaints.pb")
        model.adopt(keys, environment: environment, leavingInvitation: false)
        guard let device = model.device else { throw PeerError("Mac device did not start") }
        self.device = device
        if !device.hasPushKey {
            try device.setPushCredential(keyID: "TESTKEY", teamID: "TESTTEAM",
                                         privateKey: P256.Signing.PrivateKey().derRepresentation)
        }
        device.registerPush(token: RecordedPushes.macToken, topic: RecordedPushes.topic, production: false)
    }

    func run() async throws {
        defer {
            phone?.stopBackgroundWork()
            device.stopBackgroundWork()
        }
        await model.loadStatus()
        if let problem = model.problem { throw PeerError(problem) }
        try model.startAgentListener()
        try reply("READY")
        // Reading stdin must leave the main actor free to service the socket and relay.
        while let line = await Task.detached(operation: { readLine() }).value {
            if line == "QUIT" {
                try reply("OK")
                return
            }
            try await reply(handle(line))
        }
    }

    private func reply(_ line: String) throws {
        try FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }

    private func handle(_ line: String) async throws -> String {
        let words = line.split(separator: " ", maxSplits: 3).map(String.init)
        switch words.first {
        case "IMPORT_SELECTIVE" where words.count == 1:
            return try await importSelective()
        case "IMPORT_LATER" where words.count == 1:
            try await importPasswords(["new.example"])
            let id = try loginID(for: "new.example")
            try await setRule(.automatic, for: id)
            return id.uuidString
        case "SET_RULE" where words.count == 3:
            guard let id = UUID(uuidString: words[1]) else { throw PeerError("Invalid login ID") }
            let rule: LoginRule
            switch words[2] {
            case "ask": rule = .ask
            case "automatic": rule = .automatic
            case "blocked": rule = .blocked
            default: throw PeerError("Unknown rule")
            }
            try await setRule(rule, for: id)
            return "OK"
        case "APPROVE_WAITING_LEASE" where words.count == 1:
            let lease = try await waitFor("local lease") { model.leaseStore.waitingRequests.first }
            let approved = try await model.approveLeaseWithTouchID(lease.requestID, context: LAContext())
            guard approved.state == .approved else { throw PeerError("Lease did not become active") }
            return approved.requestID
        case "DENY_WAITING_LEASE":
            let lease = try await waitFor("local lease") { model.leaseStore.waitingRequests.first }
            _ = try model.denyLease(lease.requestID, reply: words.dropFirst().joined(separator: " "))
            return lease.requestID
        case "STOP_LEASE" where words.count == 2:
            let stopped = try model.leaseStore.revoke(words[1])
            guard stopped.state == .ended else { throw PeerError("Lease did not stop") }
            return "OK"
        case "INVITE_CODE" where words.count == 1:
            return try device.inviteMachine()
        case "APPROVE_JOIN" where words.count == 1:
            let join = try await waitFor("computer join") { device.joins.first }
            try await device.approveJoin(MacSyncCoordinator.joinID(join), context: LAContext(), onAuthenticated: {})
            if let phone, case let .machine(machine)? = join.request.joining {
                try await waitForPhone("iPhone to see the new computer", phone: phone) {
                    $0.devices.contains { $0.id == machine.machineID }
                }
            }
            return "OK"
        case "REFUSE_JOIN" where words.count >= 2:
            let join = try await waitFor("computer join") { device.joins.first }
            guard device.refuseJoin(MacSyncCoordinator.joinID(join), reply: words.dropFirst().joined(separator: " ")) else {
                throw PeerError("Join refusal did not start")
            }
            return "OK"
        case "REMOVE_COMPUTER" where words.count >= 2:
            let name = words.dropFirst().joined(separator: " ")
            guard let machine = device.members?.machines.first(where: { $0.label == name }) else {
                throw PeerError("No computer named \(name)")
            }
            try await device.removeConfirmed(machine.machineID, context: LAContext())
            return "OK"
        case "ENROL_PHONE" where words.count == 1:
            try await enrolPhone()
            return "OK"
        case "REMOVE_PHONE" where words.count == 1:
            return try await removePhone()
        case "CONTEST_RULE" where words.count == 3:
            guard let id = UUID(uuidString: words[1]), let order = RuleContestOrder(rawValue: words[2]) else {
                throw PeerError("Invalid login ID or contest order")
            }
            try await contestRule(for: id, order: order)
            return "OK"
        default:
            return try await remoteCommand(words)
        }
    }

    private func importSelective() async throws -> String {
        try await importPasswords(["github.example", "docs.example", "my.1password.com"])
        let github = try loginID(for: "github.example")
        let docs = try loginID(for: "docs.example")
        try await setRule(.automatic, for: docs)
        return "\(github.uuidString) \(docs.uuidString)"
    }

    private func importPasswords(_ sites: [String]) async throws {
        let source = "com.apple.Passwords"
        let account = "test@example.net"
        let items = sites.map { site in
            var credentials: [ImportedLoginSecret] = [.password(userName: account, password: "pw-\(site)")]
            if site == "github.example" {
                credentials.append(.totp(secret: Data("12345678901234567890".utf8), period: 30, digits: 6,
                                         userName: account, algorithm: .sha1, issuer: nil))
            }
            return StoredVaultLogin(
                id: UUID(),
                sourceIdentity: LoginSourceIdentity(exporterIdentifier: source, accountID: Data("test".utf8),
                    itemID: Data(site.utf8)),
                title: site,
                origins: ["https://\(site)"],
                credentials: credentials
            )
        }
        model.openPasswordsCopyFlow()
        model.sendImport(.switchToAllPasswords)
        model.stageIncomingBatch(LoginImportBatch(scope: .selected, exportedAt: .now, exporterIdentifier: source,
            exporterDisplayName: "Passwords", items: items, skippedCredentialCount: 0))
        guard await model.commitStagedImport() else {
            throw PeerError(model.problem ?? "Selective import did not save")
        }
    }

    private func loginID(for title: String) throws -> UUID {
        guard let login = model.leaseLogins.first(where: { $0.title == title }) else {
            throw PeerError("Import did not save \(title)")
        }
        return login.id
    }

    func setRule(_ rule: LoginRule, for id: UUID) async throws {
        model.clearProblem()
        await model.accessControl.setRule(rule, for: [id], context: LAContext())
        if let problem = model.accessControl.errorMessage ?? model.problem { throw PeerError(problem) }
        guard model.accessControl.rule(for: id) == rule else { throw PeerError("Rule did not change") }
    }

    func waitFor<T>(_ label: String, _ pending: () async throws -> T?) async throws -> T {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        repeat {
            if let value = try await pending() { return value }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        throw PeerError("Timed out waiting for \(label)")
    }
}

private enum Main {
    @MainActor static func run() async {
        do {
            umask(0o077)
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            let suite = "TestPeer.\(UUID().uuidString)"
            guard let settings = UserDefaults(suiteName: suite) else {
                throw PeerError("Could not create isolated defaults")
            }
            defer { settings.removePersistentDomain(forName: suite) }
            try await TestPeer(options: options, settings: settings).run()
        } catch {
            let message = "TestPeer: \(error)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            exit(1)
        }
    }
}
await Main.run()
#else
fatalError("TestPeer requires a macOS debug build")
#endif
