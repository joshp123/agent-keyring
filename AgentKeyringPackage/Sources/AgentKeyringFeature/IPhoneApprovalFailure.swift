import Foundation

public enum IPhoneApprovalFailure: String, Codable, Error, CaseIterable, Sendable {
    case notSignedInToICloud
    case networkUnavailable
    case quotaExceeded
    case rateLimited
    case unavailable

    public var reason: String {
        switch self {
        case .notSignedInToICloud: "not signed in to iCloud"
        case .networkUnavailable: "network unavailable"
        case .quotaExceeded: "iCloud quota exceeded"
        case .rateLimited: "iCloud rate-limited"
        case .unavailable: "iCloud unavailable"
        }
    }

    public var fallbackLine: String {
        "The iPhone could not be reached (\(reason)); asking on the Mac only."
    }
}
