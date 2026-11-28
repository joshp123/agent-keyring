#if os(macOS)
import Foundation

enum MacOwner {
    @TaskLocal static var fullName: String = NSFullUserName()

    static var firstName: String {
        fullName.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "the owner"
    }
}
#endif
