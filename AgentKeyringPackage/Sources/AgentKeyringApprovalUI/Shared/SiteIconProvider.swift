// Written by AI on 2026.11.26 by model gemini-4-neon.
//
// Abstraction allowing main apps (macOS and iOS) to provide k-anonymous site
// icons to `AgentKeyringApprovalUI` without linking icon resources into
// iOS notification or credential provider extensions.

import Foundation
import SwiftUI

public protocol SiteIconProviding: Sendable {
    func cachedIconData(forHost host: String, displayName: String) -> Data?
    func iconData(forHost host: String, displayName: String) async -> Data?
}

#if os(macOS)
import AgentKeyringSiteIcons

extension SiteIconStore: SiteIconProviding {}
#endif

private struct SiteIconProviderKey: EnvironmentKey {
    static var defaultValue: (any SiteIconProviding)? {
        #if os(macOS)
        return SiteIconStore.shared
        #else
        return nil
        #endif
    }
}

public extension EnvironmentValues {
    var siteIconProvider: (any SiteIconProviding)? {
        get { self[SiteIconProviderKey.self] }
        set { self[SiteIconProviderKey.self] = newValue }
    }
}
