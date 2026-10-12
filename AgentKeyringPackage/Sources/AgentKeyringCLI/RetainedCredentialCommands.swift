import ArgumentParser
import Foundation

struct Read: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write a retained value to stdout without consuming it or adding a newline."
    )

    @Argument(help: "The reference printed by acquire.") var reference: String

    func validate() throws { _ = try credentialReference(reference) }

    mutating func run() async throws {
        try await CLIClient.read(reference: credentialReference(reference))
    }
}

struct Clear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Clear a retained value. An already cleared reference is harmless."
    )

    @Argument(help: "The reference printed by acquire.") var reference: String

    func validate() throws { _ = try credentialReference(reference) }

    mutating func run() async throws {
        try await CLIClient.clear(reference: credentialReference(reference))
    }
}

private func credentialReference(_ value: String) throws -> UUID {
    guard let reference = UUID(uuidString: value) else {
        throw ValidationError("Use a valid reference printed by acquire.")
    }
    return reference
}
