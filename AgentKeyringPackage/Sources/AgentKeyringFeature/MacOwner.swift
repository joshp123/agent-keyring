import Foundation

public enum MacOwner {
    @TaskLocal public static var fullName: String = NSFullUserName()

    public static var firstName: String {
        fullName.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "the owner"
    }
}
