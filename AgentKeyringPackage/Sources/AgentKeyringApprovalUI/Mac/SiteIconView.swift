// Written by AI on 2026.11.25 by model gemini-4-neon.
// Updated on 2026.11.26 for cross-platform macOS + iOS k-anonymous icon buckets.
//
// Renders site icons synchronously from the bundled offline pack or on-disk
// k-anonymous bucket cache, fetching a 14-bit SHA-256 prefix bucket on demand
// when absent (zero pings to saved websites, private/IP hosts skipped), and
// falling back to a subtle monogram badge for unindexed long-tail domains.

#if os(macOS) || os(iOS)
import AgentKeyringDesign
import SwiftUI

#if os(macOS)
import AgentKeyringSiteIcons
import AppKit
private typealias PlatformImage = NSImage
#else
import UIKit
private typealias PlatformImage = UIImage
#endif

public struct SiteIconView: View {
    #if os(macOS)
    /// Total number of favicons available in the bundled offline icon pack.
    nonisolated public static var bundledIconCount: Int {
        SiteIconStore.shared.bundledIconCount
    }

    /// Returns whether the bundled offline pack contains a real icon for `host`.
    nonisolated public static func hasBundledIcon(forHost host: String, displayName: String = "") -> Bool {
        SiteIconStore.shared.hasBundledIcon(forHost: host, displayName: displayName)
    }
    #endif

    @Environment(\.siteIconProvider) private var iconProvider
    @State private var loadedImage: PlatformImage?

    let host: String
    let displayName: String
    let size: CGFloat

    public init(host: String, displayName: String = "", size: CGFloat = 22) {
        self.host = host
        self.displayName = displayName.isEmpty ? host : displayName
        self.size = size
    }

    private var displayImage: PlatformImage? {
        if let loadedImage { return loadedImage }
        return SiteIconImageCache.cachedImage(host: host, displayName: displayName, provider: iconProvider)
    }

    public var body: some View {
        Group {
            if let image = displayImage {
                platformSwiftUIImage(image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.12)
                    .frame(width: size, height: size)
                    .background(Color.white, in: .rect(cornerRadius: size * 0.27, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                            .strokeBorder(KeyringPalette.line, lineWidth: 0.75)
                    )
                    .accessibilityHidden(true)
            } else {
                fallbackMonogram
            }
        }
        .task(id: "\(host)|\(displayName)") {
            guard let provider = iconProvider else { return }
            if let cached = SiteIconImageCache.cachedImage(host: host, displayName: displayName, provider: provider) {
                loadedImage = cached
                return
            }
            guard let data = await provider.iconData(forHost: host, displayName: displayName),
                  !Task.isCancelled,
                  let image = PlatformImage(data: data)
            else {
                return
            }
            SiteIconImageCache.store(image, host: host, displayName: displayName)
            loadedImage = image
        }
    }

    private func platformSwiftUIImage(_ image: PlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }

    private var fallbackMonogram: some View {
        Text(monogram)
            .font(KeyringFont.fixed(KeyringFont.PostScript.semibold, size: size * 0.42))
            .foregroundStyle(KeyringPalette.ink2)
            .frame(width: size, height: size)
            .background(KeyringPalette.fill, in: .rect(cornerRadius: size * 0.27, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(KeyringPalette.line, lineWidth: 0.75)
            )
            .accessibilityHidden(true)
    }

    private var monogram: String {
        let words = displayName.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2, let first = words[0].first, let second = words[1].first {
            return String([first, second]).uppercased()
        }
        if let first = words.first {
            return String(first.prefix(2)).uppercased()
        }
        return "?"
    }
}

private enum SiteIconImageCache {
    @MainActor private static var decoded: [String: PlatformImage] = [:]

    @MainActor
    static func cachedImage(host: String, displayName: String, provider: (any SiteIconProviding)?) -> PlatformImage? {
        let key = "\(host.lowercased())|\(displayName.lowercased())"
        if let hit = decoded[key] { return hit }
        guard let data = provider?.cachedIconData(forHost: host, displayName: displayName),
              let image = PlatformImage(data: data)
        else {
            return nil
        }
        decoded[key] = image
        return image
    }

    @MainActor
    static func store(_ image: PlatformImage, host: String, displayName: String) {
        let key = "\(host.lowercased())|\(displayName.lowercased())"
        decoded[key] = image
    }
}
#endif
