// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// What stands in for Face ID, Touch ID, iCloud and the relay while the screens
// run on a sandbox world. Every action that would reach outside the device is
// run here first, as Josh chose for it: done at once, done after a wait,
// failed with his words, or cancelled as if he closed the dialog. Only once it
// has run does the world change. Nothing is dropped: an action set to fail
// throws, and one set to cancel throws CancellationError, as the real ones do.

import Foundation

/// An action that would reach outside the device.
public enum SandboxEffect: Hashable, Sendable, CaseIterable {
    case approve, deny, stop, allowAskingAgain
    case setRule, removeDevice, renameDevice
    case addPassword, importAgain, sendUpdates, sendPractice
    case addWatch, addComputer, answerDeviceJoin, setUpHere
    case sync, reset
    /// iOS's question about notifications.
    case askNotifications
    /// A question beside the window that needs only Josh's approval.
    case ownerApproval
}

/// How a sandbox action ends.
public enum SandboxOutcome: Hashable, Sendable {
    case immediate
    case delayed(Duration)
    case fail(String)
    case cancelled
}

/// A sandbox action that was set to fail, with the sentence the screen shows.
public struct SandboxFailure: LocalizedError, Hashable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

@MainActor
public final class SandboxEffectRunner {
    /// How each action ends; anything not listed ends at once.
    public var outcomes: [SandboxEffect: SandboxOutcome]
    /// Every action run, in order, with how it ended.
    public private(set) var log: [(effect: SandboxEffect, outcome: SandboxOutcome)] = []
    private var waiting: [UUID: (effect: SandboxEffect, task: Task<Void, Error>)] = [:]

    public init(_ outcomes: [SandboxEffect: SandboxOutcome] = [:]) {
        self.outcomes = outcomes
    }

    /// Runs `effect` as set. Throws `SandboxFailure` or `CancellationError` when set to, or when
    /// `cancel` stops it while it waits.
    public func runEffect(_ effect: SandboxEffect) async throws {
        let outcome = outcomes[effect] ?? .immediate
        log.append((effect, outcome))
        switch outcome {
        case .immediate:
            return
        case let .delayed(duration):
            let id = UUID()
            let task = Task { try await Task.sleep(for: duration) }
            waiting[id] = (effect, task)
            defer { waiting[id] = nil }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
        case let .fail(message):
            throw SandboxFailure(message)
        case .cancelled:
            throw CancellationError()
        }
    }

    /// Stops every waiting run of `effect`, as closing macOS's dialog does.
    public func cancelEffect(_ effect: SandboxEffect) {
        for entry in waiting.values where entry.effect == effect { entry.task.cancel() }
    }

    /// The actions run so far, without how they ended.
    public var ran: [SandboxEffect] { log.map(\.effect) }
}
