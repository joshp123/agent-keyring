import Darwin
import Foundation

func installedVersion(executable: URL? = currentExecutableURL()) -> String {
    guard let executable else { return "unknown" }
    let infoURL = executable.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: infoURL),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let dictionary = plist as? [String: Any],
        let version = dictionary["CFBundleShortVersionString"] as? String
    else { return "unknown" }
    return version
}

private func currentExecutableURL() -> URL? {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var path = [CChar](repeating: 0, count: Int(size))
    let result = path.withUnsafeMutableBufferPointer { buffer in
        _NSGetExecutablePath(buffer.baseAddress, &size)
    }
    guard result == 0 else { return nil }
    let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath()
}
