import AgentKeyringFeature
import ArgumentParser
import Foundation
import Testing
@testable import AgentKeyringCLI

@Suite("Human-first CLI")
struct AgentKeyringCLITests {
    @Test("Top-level help explains the product and leads with examples")
    func topLevelHelp() {
        let help = AgentKeyringCLI.helpMessage(columns: 100)
        #expect(help.contains("Use imported Apple Passwords logins from the command line."))
        #expect(help.contains("agent-keyring find example.com"))
        #expect(help.contains("SUBCOMMANDS"))
        #expect(!help.contains("JSON"))
    }

    @Test("Find takes the page URL as its main argument")
    func findCommand() throws {
        let command = try #require(
            AgentKeyringCLI.parseAsRoot([
                "find", "https://example.com/login", "--account", "person@example.com",
            ]) as? Find
        )
        #expect(command.site == "https://example.com/login")
        #expect(command.account == "person@example.com")
    }

    @Test("Bare domains are treated as HTTPS sites")
    func bareDomain() throws {
        #expect(try normaliseWebTarget("example.com") == "https://example.com")
        #expect(
            try normaliseSecureWebTarget("example.com/login")
                == "https://example.com/login"
        )
    }

    @Test("Full page URLs remain unchanged")
    func fullPageURL() throws {
        #expect(
            try normaliseSecureWebTarget("https://example.com/login?next=%2Faccount")
                == "https://example.com/login?next=%2Faccount"
        )
    }

    @Test("Copy uses human field names and conventional options")
    func copyCommand() throws {
        let id = UUID()
        let command = try #require(
            AgentKeyringCLI.parseAsRoot([
                "copy", "code", "https://example.com", "--credential", id.uuidString,
                "--expires", "45",
            ]) as? Copy
        )
        #expect(command.field == .code)
        #expect(command.site == "https://example.com")
        #expect(command.credential == id.uuidString)
        #expect(command.expires == 45)
    }

    @Test("Every command has focused local help")
    func commandHelp() {
        let help = AgentKeyringCLI.helpMessage(for: Copy.self, columns: 100)
        #expect(help.contains("copy <field> <site>"))
        #expect(help.contains("--account"))
        #expect(help.contains("--credential"))
        #expect(help.contains("--expires"))
    }

    @Test("Argument Parser rejects unknown commands and missing values")
    func usageErrors() {
        expectParseFailure(["frobnicate"])
        expectParseFailure(["find"])
        expectParseFailure(["find", "https://example.com", "--wat", "value"])
        expectParseFailure(["copy", "api-key", "https://example.com"])
    }

    @Test("Copy rejects insecure pages before contacting the app")
    func insecureCopy() {
        #expect(throws: ValidationError.self) {
            try normaliseSecureWebTarget("http://example.com")
        }
    }

    @Test("Status translates transport data into human meaning")
    func statusOutput() throws {
        let response = AgentBridgeResponse(
            id: UUID(),
            ok: true,
            mirror: AgentMirrorSummary(
                importedAt: Date(timeIntervalSince1970: 1_000),
                ageSeconds: 6 * 86_400,
                credentialCount: 523
            )
        )
        #expect(
            try CLIOutput.render(response, for: .status)
                == "523 logins available\nUpdated 6 days ago\n"
        )
    }

    @Test("Find shows safe account metadata without transport JSON")
    func findOutput() throws {
        let candidate = CredentialCandidate(
            id: UUID(),
            title: "example.com",
            username: "example@example.com",
            origins: ["https://example.com"],
            availableFields: [.username, .password]
        )
        let response = AgentBridgeResponse(
            id: UUID(),
            ok: true,
            candidates: [candidate]
        )
        let output = try CLIOutput.render(
            response,
            for: .find(targetURL: "https://example.com/login", account: nil)
        )
        #expect(output.contains("1 login found for example.com"))
        #expect(output.contains("Account: example@example.com"))
        #expect(output.contains("Can copy: username, password"))
        #expect(!output.contains(candidate.id.uuidString))
        #expect(!output.contains("{"))
    }

    @Test("Copy receipts name the safe account and destination")
    func copyOutput() throws {
        let candidate = CredentialCandidate(
            id: UUID(),
            title: "example.com",
            username: "example@example.com",
            origins: ["https://example.com"],
            availableFields: [.password]
        )
        let response = AgentBridgeResponse(
            id: UUID(),
            ok: true,
            candidates: [candidate],
            copiedField: .password,
            clipboardExpiresAt: Date().addingTimeInterval(30)
        )
        #expect(
            try CLIOutput.render(
                response,
                for: .copy(
                    field: .password,
                    targetURL: "https://example.com/login",
                    account: nil,
                    credentialID: nil,
                    expiration: 30
                )
            )
                == "Copied the password for example@example.com on example.com. Paste it within 30 seconds.\n"
        )
    }

    @Test("Duplicate account errors lead to credential IDs instead of looping")
    func duplicateAccountError() {
        let candidates = [
            CredentialCandidate(
                id: UUID(),
                title: "First",
                username: "same@example.com",
                origins: ["https://example.com"],
                availableFields: [.password]
            ),
            CredentialCandidate(
                id: UUID(),
                title: "Second",
                username: "same@example.com",
                origins: ["https://example.com"],
                availableFields: [.password]
            ),
        ]
        let response = AgentBridgeResponse(
            id: UUID(),
            ok: false,
            error: .ambiguous,
            candidates: candidates
        )
        let error = CLIError(
            response: response,
            command: .copy(
                field: .password,
                targetURL: "https://example.com",
                account: nil,
                credentialID: nil,
                expiration: 30
            )
        )

        #expect(error.rendered.contains("--credential UUID"))
        #expect(!error.rendered.contains("--account 'same@example.com'"))
    }

    @Test("Install replaces recognised legacy copies with links to the app")
    func installMigratesLegacyCopies() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let commandSource = root.appendingPathComponent("app/agent-keyring")
        let skillSource = root.appendingPathComponent("app/agent-keyring-skill")
        let commandDestination = root.appendingPathComponent("bin/agent-keyring")
        let skillDestination = root.appendingPathComponent("skills/agent-keyring")
        try FileManager.default.createDirectory(
            at: commandDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            "agent-keyring — use the local encrypted Agent Keyring".utf8
        ).write(to: commandDestination)
        try FileManager.default.createDirectory(
            at: skillDestination,
            withIntermediateDirectories: true
        )
        try "---\nname: agent-keyring\n---\n".write(
            to: skillDestination.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        try IntegrationInstaller.install([
            IntegrationLink(
                destination: commandDestination,
                source: commandSource,
                legacyKind: .command
            ),
            IntegrationLink(
                destination: skillDestination,
                source: skillSource,
                legacyKind: .codexSkill
            ),
        ])

        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: commandDestination.path)
                == commandSource.path
        )
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: skillDestination.path)
                == skillSource.path
        )
    }

    @Test("Install checks every destination before making changes")
    func installPreflightsAllDestinations() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let commandDestination = root.appendingPathComponent("bin/agent-keyring")
        let skillDestination = root.appendingPathComponent("skills/agent-keyring")
        try FileManager.default.createDirectory(
            at: skillDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "unrelated".write(
            to: skillDestination,
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: CLIError.self) {
            try IntegrationInstaller.install([
                IntegrationLink(
                    destination: commandDestination,
                    source: root.appendingPathComponent("app/agent-keyring"),
                    legacyKind: .command
                ),
                IntegrationLink(
                    destination: skillDestination,
                    source: root.appendingPathComponent("app/skill"),
                    legacyKind: .codexSkill
                ),
            ])
        }
        #expect(!FileManager.default.fileExists(atPath: commandDestination.path))
        #expect(
            try String(contentsOf: skillDestination, encoding: .utf8) == "unrelated"
        )
    }

    @Test("Install leaves current links alone")
    func installIsIdempotent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("app/agent-keyring")
        let destination = root.appendingPathComponent("bin/agent-keyring")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: source
        )

        try IntegrationInstaller.install([
            IntegrationLink(
                destination: destination,
                source: source,
                legacyKind: .command
            )
        ])

        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.path)
                == source.path
        )
    }

    @Test("Version comes from the app containing the resolved executable")
    func bundledVersion() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("AgentKeyring.app/Contents")
        let executable = contents.appendingPathComponent("Helpers/agent-keyring")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "1.2.3"],
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))

        #expect(installedVersion(executable: executable) == "1.2.3")
    }

    private func expectParseFailure(_ arguments: [String]) {
        do {
            _ = try AgentKeyringCLI.parseAsRoot(arguments)
            Issue.record("Expected parsing to fail")
        } catch {
            #expect(!String(describing: error).contains("{\""))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
