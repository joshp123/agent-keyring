// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// The words the parts say themselves. Pages bring every other word from
// their own copy tables.

public enum PartsCopy {
    public static func step(_ number: Int, of total: Int) -> String { "Step \(number) of \(total)" }
    public static let copy = "Copy"
    public static let copied = "Copied"
    public static let checkDone = "Done"
    public static let checkPending = "Not set yet"
    public static let checkNeedsAttention = "Needs attention"
}
