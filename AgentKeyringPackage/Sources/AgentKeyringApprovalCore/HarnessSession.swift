import Foundation
import Security

public struct HarnessProcessStartTime: Codable, Equatable, Hashable, Sendable {
    public let seconds: UInt64
    public let microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

public struct HarnessSession: Codable, Equatable, Hashable, Sendable {
    public let processIdentifier: Int32
    public let processStartTime: HarnessProcessStartTime

    public init(processIdentifier: Int32, processStartTime: HarnessProcessStartTime) {
        self.processIdentifier = processIdentifier
        self.processStartTime = processStartTime
    }
}
