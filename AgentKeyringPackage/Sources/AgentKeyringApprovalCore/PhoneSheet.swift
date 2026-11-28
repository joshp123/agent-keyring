// Written by AI on 2026.11.21 by model Gemini 4 Neon.
//
// The single explicit state machine for every modal sheet and notification open
// on iPhone. Replaces the scattered sheet flags (shownRequestID, explaining,
// replyDraft, practiceRequest, settingsShown) and stacked .sheet modifiers so
// only one sheet can ever exist at a time, switching between Decide, Approving
// and Explain happens in place with zero ghost bounce, and reply drafts are
// scoped strictly per request ID.

import Foundation

public enum PhoneSheetMode: Equatable, Hashable, Sendable {
    /// Normal request decision: Approve with Face ID, Deny, Deny and Explain.
    case decide
    /// Direct approval triggered from a notification's Approve action, or an in-flight send.
    case approving
    /// Writing or speaking a denial reason.
    case explain
    /// Read-only inspection of a settled Activity row (shows full reason, account, and any denial reply).
    case settled
}

public enum PhoneSheetPresentation: Equatable, Hashable, Sendable {
    case none
    /// One waiting request (real or practice) presented in the single sheet.
    /// `canReturnToDecide` is true when Explain was entered from Decide so Back returns there.
    case request(id: String, mode: PhoneSheetMode, canReturnToDecide: Bool)
    /// Adding Apple Watch from Devices after first run.
    case addWatch
    /// Notification settings sheet from Home.
    case settings
}

public enum PhoneSheetEvent: Equatable, Sendable {
    case notificationTapped(id: String, isWaiting: Bool, endedNote: String?)
    case notificationApproveTapped(id: String, isWaiting: Bool, endedNote: String?)
    case notificationExplainTapped(id: String, isWaiting: Bool, endedNote: String?)
    case openDecide(id: String)
    case openExplain(id: String)
    case openSettled(id: String)
    case backToDecide
    case approveStarted(id: String)
    case approveCancelled(id: String)
    case requestEnded(id: String)
    case dismiss(expectedItem: PhoneSheetItem? = nil)
    case openAddWatch
    case addWatchClosed
    case openSettings
    case settingsClosed
    case updateDraft(id: String, text: String)
    case dismissStaleNotice
}

/// Stable identity for SwiftUI's single `.sheet(item:)`. Keyed by request ID
/// (not by mode) so moving Decide -> Explain -> Approving mutates in place
/// instead of dismissing and re-presenting the sheet.
public enum PhoneSheetItem: Identifiable, Equatable, Hashable, Sendable {
    case request(id: String)
    case addWatch
    case settings

    public var id: String {
        switch self {
        case let .request(id): "request:\(id)"
        case .addWatch: "addWatch"
        case .settings: "settings"
        }
    }
}

public struct PhoneSheetState: Hashable, Sendable {

    public var presentation: PhoneSheetPresentation = .none
    /// Reply text keyed strictly by request ID so switching requests never leaks text.
    public var drafts: [String: String] = [:]
    /// Non-blocking note shown on Home if the user taps a notification whose request already ended.
    public var staleNotice: String? = nil

    public init(presentation: PhoneSheetPresentation = .none, drafts: [String: String] = [:], staleNotice: String? = nil) {
        self.presentation = presentation
        self.drafts = drafts
        self.staleNotice = staleNotice
    }

    public var item: PhoneSheetItem? {
        switch presentation {
        case .none: nil
        case let .request(id, _, _): .request(id: id)
        case .addWatch: .addWatch
        case .settings: .settings
        }
    }

    public var requestID: String? {
        if case let .request(id, _, _) = presentation { id } else { nil }
    }

    public var requestMode: PhoneSheetMode? {
        if case let .request(_, mode, _) = presentation { mode } else { nil }
    }

    public var canReturnToDecide: Bool {
        if case let .request(_, .explain, back) = presentation { back } else { false }
    }

    public func draft(for id: String) -> String { drafts[id] ?? "" }

    /// Pure transition function. Unknown or stale events leave unrelated state untouched.
    public mutating func apply(_ event: PhoneSheetEvent) {
        switch event {
        case let .notificationTapped(id, isWaiting, endedNote):
            if isWaiting {
                staleNotice = nil
                presentation = .request(id: id, mode: .decide, canReturnToDecide: false)
            } else {
                if requestID == id { presentation = .none }
                drafts.removeValue(forKey: id)
                if let endedNote, !endedNote.isEmpty { staleNotice = endedNote }
            }

        case let .notificationApproveTapped(id, isWaiting, endedNote):
            if isWaiting {
                staleNotice = nil
                presentation = .request(id: id, mode: .approving, canReturnToDecide: false)
            } else {
                if requestID == id { presentation = .none }
                drafts.removeValue(forKey: id)
                if let endedNote, !endedNote.isEmpty { staleNotice = endedNote }
            }

        case let .notificationExplainTapped(id, isWaiting, endedNote):
            if isWaiting {
                staleNotice = nil
                presentation = .request(id: id, mode: .explain, canReturnToDecide: false)
            } else {
                if requestID == id { presentation = .none }
                drafts.removeValue(forKey: id)
                if let endedNote, !endedNote.isEmpty { staleNotice = endedNote }
            }

        case let .openDecide(id):
            staleNotice = nil
            presentation = .request(id: id, mode: .decide, canReturnToDecide: false)

        case let .openExplain(id):
            staleNotice = nil
            let fromDecide = (requestID == id && requestMode == .decide)
            presentation = .request(id: id, mode: .explain, canReturnToDecide: fromDecide)

        case let .openSettled(id):
            staleNotice = nil
            presentation = .request(id: id, mode: .settled, canReturnToDecide: false)

        case .backToDecide:
            if case let .request(id, .explain, true) = presentation {
                presentation = .request(id: id, mode: .decide, canReturnToDecide: false)
            }

        case let .approveStarted(id):
            if case let .request(current, _, _) = presentation, current == id {
                presentation = .request(id: id, mode: .approving, canReturnToDecide: false)
            }

        case let .approveCancelled(id):
            if case let .request(current, .approving, _) = presentation, current == id {
                presentation = .request(id: id, mode: .decide, canReturnToDecide: false)
            }

        case let .requestEnded(id):
            drafts.removeValue(forKey: id)
            if requestID == id { presentation = .none }

        case let .dismiss(expectedItem):
            if let expectedItem, item != expectedItem { return }
            presentation = .none

        case .openAddWatch:
            staleNotice = nil
            presentation = .addWatch

        case .addWatchClosed:
            if presentation == .addWatch { presentation = .none }

        case .openSettings:
            staleNotice = nil
            presentation = .settings

        case .settingsClosed:
            if presentation == .settings { presentation = .none }

        case let .updateDraft(id, text):
            if text.isEmpty { drafts.removeValue(forKey: id) }
            else { drafts[id] = text }

        case .dismissStaleNotice:
            staleNotice = nil
        }
    }
}
