import AgentKeyringFeature
import Foundation
import Testing
@testable import AgentKeyringCLI

@Suite("Harness installation")
struct InstallCommandTests {
    @Test("Install copies both skills, merges the browser config, and can run twice")
    func installTwice() throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let configURL = fixture.home.appendingPathComponent(".agent-browser/config.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original: [String: Any] = [
            "headed": true, "timeout": 12000,
            "plugins": [
                ["name": "another-vault", "command": "/tools/vault", "capabilities": ["credential.read"]],
                ["name": "agent-keyring", "command": "/old/agent-keyring", "custom": "preserved"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: configURL)
        let first = try CLIClient.install(home: fixture.home, executable: fixture.executable)
        let firstConfig = try Data(contentsOf: configURL)
        let second = try CLIClient.install(home: fixture.home, executable: fixture.executable)
        #expect(second.rendered == first.rendered)
        #expect(try Data(contentsOf: configURL) == firstConfig)
        for harness in ["codex", "claude"] {
            let installed = fixture.home.appendingPathComponent(".\(harness)/skills/agent-keyring/SKILL.md")
            #expect(try Data(contentsOf: installed) == fixture.skill)
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: installed.path)) == nil)
        }
        let command = fixture.home.appendingPathComponent(".local/bin/agent-keyring")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: command.path) == fixture.executable.path)
        let config = try #require(JSONSerialization.jsonObject(with: firstConfig) as? [String: Any])
        #expect(config["headed"] as? Bool == true)
        #expect(config["timeout"] as? Int == 12000)
        let plugins = try #require(config["plugins"] as? [[String: Any]])
        #expect(plugins.count == 2)
        #expect(plugins[0]["command"] as? String == "/tools/vault")
        #expect(plugins[1]["command"] as? String == command.path)
        #expect(plugins[1]["args"] as? [String] == ["agent-browser-plugin"])
        #expect(plugins[1]["capabilities"] as? [String] == ["credential.read"])
        #expect(plugins[1]["custom"] as? String == "preserved")
        let snippet = try #require(first.rendered.components(separatedBy: "AGENTS.md:\n").last)
        #expect(snippet.split(separator: "\n").count <= 2)
        #expect(snippet.contains("logins and secrets"))
        #expect(snippet.contains("agent-keyring --help"))
    }

    @Test("A read-only Claude skills directory is skipped without blocking the other integrations")
    func readOnlySkills() throws {
        let fixture = try InstallFixture()
        defer { fixture.cleanUp() }
        let skills = fixture.home.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: skills.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: skills.path) }
        for _ in 0..<2 {
            let result = try CLIClient.install(home: fixture.home, executable: fixture.executable)
            let skipped = result.rendered.split(separator: "\n").filter { $0.hasPrefix("Skipped ") }
            #expect(skipped.count == 1)
            #expect(skipped.first?.contains(skills.path) == true)
            #expect(skipped.first?.contains(fixture.skillSource.path) == true)
            #expect(try Data(contentsOf: fixture.home.appendingPathComponent(".codex/skills/agent-keyring/SKILL.md")) == fixture.skill)
            #expect(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".agent-browser/config.json").path))
            #expect(!FileManager.default.fileExists(atPath: skills.appendingPathComponent("agent-keyring").path))
        }
    }

    @Test("Install help names both harnesses and the browser plugin")
    func help() {
        let help = Install.helpMessage(columns: 120)
        #expect(help.contains("Claude Code and Codex skills"))
        #expect(help.contains("agent-browser plugin"))
        #expect(!help.contains("Codex instructions"))
    }
}

private struct InstallFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let skill = Data("Synthetic bundled skill\n".utf8)
    var home: URL { root.appendingPathComponent("home") }
    var executable: URL { root.appendingPathComponent("AgentKeyring.app/Contents/Helpers/agent-keyring") }
    var skillSource: URL { root.appendingPathComponent("AgentKeyring.app/Contents/Resources/AgentTools/AgentSkill/agent-keyring/SKILL.md") }

    init() throws {
        for directory in [home, executable.deletingLastPathComponent(), skillSource.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data().write(to: executable)
        try skill.write(to: skillSource)
    }

    func cleanUp() { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
}
