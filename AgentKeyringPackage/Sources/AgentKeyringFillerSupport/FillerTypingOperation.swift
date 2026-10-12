import Darwin
import Foundation

public enum FillerTypingOperation {
    public static func type(value: NSMutableData, expected: FillInspection, deadline: Date,
        now: () -> Date = Date.init, inspect: () -> FillInspection,
        post: (NSMutableData, Date) -> FillTypingResult) -> FillTypingResult {
        defer { _ = memset_s(value.mutableBytes, value.length, 0, value.length) }
        guard now() < deadline else { return .requestExpired }
        if let refusal = inspect().typingRefusal(comparedTo: expected) { return refusal }
        guard now() < deadline else { return .requestExpired }
        let result = post(value, deadline)
        if let refusal = inspect().typingRefusal(comparedTo: expected) { return refusal }
        return result
    }
}
