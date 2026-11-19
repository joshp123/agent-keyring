// Written by AI on 2026.11.20 by model claude opus 5.5.
//
// "Set Up Agents on This Mac": the app runs its own bundled `agent-keyring
// install`, which links the command and the agents' instructions and records
// the old links for `install --undo`. The app's sandbox lets it write only
// those folders (Config/AgentKeyring.entitlements).

import Foundation

/// The click on "Set Up Agents on This Mac" while it runs, or why it failed.
/// Whether it worked is read from the links, so a later `install --undo`, an
/// agent's own `install` or a Nix switch shows up the next time it is read.
public enum AgentsSetUpClick: Equatable, Sendable {
    case idle
    case working
    case failed(String)
}

/// Whether agents on this Mac ask this app: the command on their path is this app's.
public enum AgentsOnThisMac {
    /// His home, not the sandbox container's.
    public static var home: URL {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return URL.homeDirectory }
        return URL(fileURLWithPath: String(cString: directory))
    }

    public static var helper: URL { Bundle.main.bundleURL.appending(path: "Contents/Helpers/agent-keyring") }

    public static func areSetUp(home: URL = home, helper: URL = helper) -> Bool {
        let command = home.appending(path: ".local/bin/agent-keyring").resolvingSymlinksInPath()
        return command.path == helper.resolvingSymlinksInPath().path
    }
}

@available(macOS 26.0, *)
extension MirrorAppModel {
    public func setUpAgentsOnThisMac() async {
        guard agentsSetUpClick != .working else { return }
        agentsSetUpClick = .working
        let process = Process()
        process.executableURL = AgentsOnThisMac.helper
        process.arguments = ["install"]
        // The sandbox's own variables stay, so the command knows where it runs;
        // HOME inside the sandbox is the app's container, and the links belong in his own home.
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = AgentsOnThisMac.home.path
        process.environment = environment
        let output = Pipe()
        process.standardError = output
        process.standardOutput = output
        do {
            try process.run()
        } catch {
            agentsSetUpClick = .failed(FirstRunMessages.setUpFailed(error.localizedDescription))
            return
        }
        let said = await Task.detached { String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }.value
        process.waitUntilExit()
        agentsSetUpClick = process.terminationStatus == 0 && agentsSetUp ? .idle
            : .failed(FirstRunMessages.setUpFailed(said.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

enum FirstRunMessages {
    static func setUpFailed(_ detail: String) -> String {
        "The agents on this Mac weren’t set up: \(detail.isEmpty ? "the command stopped." : detail) Try again. If it keeps failing, copy the message below and send it to an agent: it can do this for you."
    }
}
