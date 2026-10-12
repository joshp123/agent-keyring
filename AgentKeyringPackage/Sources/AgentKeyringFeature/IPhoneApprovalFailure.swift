import CloudKit
import Foundation

public enum IPhoneApprovalFailure: String, Codable, Error, CaseIterable, Sendable {
    case notSignedInToICloud
    case networkUnavailable
    case quotaExceeded
    case rateLimited
    case unavailable

    public init(cloudError: any Error) {
        guard let error = cloudError as? CKError else { self = .unavailable; return }
        switch error.code {
        case .notAuthenticated: self = .notSignedInToICloud
        case .networkFailure, .networkUnavailable: self = .networkUnavailable
        case .quotaExceeded: self = .quotaExceeded
        case .requestRateLimited, .serviceUnavailable, .zoneBusy: self = .rateLimited
        default: self = .unavailable
        }
    }

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
