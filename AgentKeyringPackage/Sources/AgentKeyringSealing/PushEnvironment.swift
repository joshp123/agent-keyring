// Written by AI on 2026.11.19 by model claude opus 5.5.
//
// Which of Apple's push services this build's address belongs to. It follows
// how the app was signed, not a build setting: a development-signed build
// (Xcode, including its Release configuration) gets sandbox addresses; an App
// Store, TestFlight or ad hoc build gets production ones.

import Foundation

public enum PushEnvironment {
    /// True when Apple gives this build production push addresses.
    public static var isProduction: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        // App Store and TestFlight builds carry no profile, and push in production.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return true }
        return environment(inProfile: data) != "development"
        #endif
    }

    /// The `aps-environment` in a provisioning profile's signed property list.
    static func environment(inProfile data: Data) -> String? {
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        return entitlements["aps-environment"] as? String
    }
}
