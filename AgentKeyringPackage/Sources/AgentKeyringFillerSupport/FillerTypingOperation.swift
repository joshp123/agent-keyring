import Darwin
import Foundation

public enum FillerTypingOperation {
    public static func type(value: NSMutableData, expected: FillInspection,
        inspect: () -> FillInspection, post: (NSMutableData) -> Bool) -> FillTypingResult {
        defer { _ = memset_s(value.mutableBytes, value.length, 0, value.length) }
        if let refusal = inspect().typingRefusal(comparedTo: expected) { return refusal }
        return post(value) ? .filled : .failed
    }
}
