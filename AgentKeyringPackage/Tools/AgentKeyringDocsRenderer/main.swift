import AgentKeyringFeature
import AppKit
import Foundation
import ScreenCaptureKit
import SwiftUI

@main
enum AgentKeyringDocsRenderer {
    @MainActor
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let outputDirectory = try outputDirectory()
        let storyDirectory = storyOutputDirectory(outputDirectory: outputDirectory)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: storyDirectory,
            withIntermediateDirectories: true
        )

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentKeyringDocs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let controller = CredentialAccessController(
            store: CredentialAccessPolicyStore(
                fileURL: fixtureDirectory.appendingPathComponent("access-policies.json")
            )
        )
        let generation = fixtureGeneration()
        await controller.refresh(from: generation)
        await controller.setPolicies([
            generation.items[2].id: .allowAutomatically,
            generation.items[3].id: .allowAutomatically,
            generation.items[6].id: .block,
            generation.items[7].id: .block,
        ])
        controller.selectedPolicy = .ask

        for screen in DocumentationScreen.allCases {
            let outputURL =
                outputDirectory
                .appendingPathComponent("\(screen.rawValue).png")
            try await render(
                DocumentationPreviewView(screen: screen, controller: controller),
                contentSize: screen.logicalSize,
                title: screen.windowTitle,
                to: outputURL
            )
            print("Rendered \(outputURL.path)")
        }

        let assets = try storyAssets(from: outputDirectory)
        for scene in StoryScene.allCases {
            let outputURL = storyDirectory.appendingPathComponent("\(scene.rawValue).png")
            try renderCanvas(
                StoryFrame(scene: scene, assets: assets),
                size: CGSize(width: 1_920, height: 1_080),
                to: outputURL
            )
            print("Rendered \(outputURL.path)")
        }
    }

    private static func outputDirectory() throws -> URL {
        if CommandLine.arguments.count >= 2 {
            return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        }
        guard let workingDirectory = ProcessInfo.processInfo.environment["PWD"] else {
            throw RendererError.missingWorkingDirectory
        }
        return URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .appendingPathComponent("docs/media", isDirectory: true)
    }

    private static func storyOutputDirectory(outputDirectory: URL) -> URL {
        if CommandLine.arguments.count >= 3 {
            return URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        }
        return outputDirectory.appendingPathComponent("story", isDirectory: true)
    }

    @MainActor
    private static func render<Content: View>(
        _ content: Content,
        contentSize: CGSize,
        title: String,
        to outputURL: URL
    ) async throws {
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = CGRect(origin: .zero, size: contentSize)
        let window = NSWindow(
            contentRect: hostingView.bounds,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = title
        window.contentView = hostingView
        let visibleFrame = NSScreen.main?.visibleFrame ?? .zero
        window.setFrameOrigin(
            NSPoint(x: visibleFrame.minX + 24, y: visibleFrame.minY + 24)
        )
        window.orderBack(nil)
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(250))

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard
            let capturedWindow = shareableContent.windows.first(where: {
                $0.windowID == CGWindowID(window.windowNumber)
            })
        else {
            throw RendererError.renderFailed
        }

        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.ignoreShadows = false
        configuration.includeChildWindows = true
        configuration.dynamicRange = .sdr
        let output = try await SCScreenshotManager.captureScreenshot(
            contentFilter: SCContentFilter(desktopIndependentWindow: capturedWindow),
            configuration: configuration
        )
        window.close()

        guard let image = output.sdrImage else {
            throw RendererError.renderFailed
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RendererError.renderFailed
        }
        try data.write(to: outputURL, options: .atomic)
    }

    @MainActor
    private static func renderCanvas<Content: View>(
        _ content: Content,
        size: CGSize,
        to outputURL: URL
    ) throws {
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width),
                pixelsHigh: Int(size.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else {
            throw RendererError.renderFailed
        }
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RendererError.renderFailed
        }
        try data.write(to: outputURL, options: .atomic)
    }

    private static func storyAssets(from directory: URL) throws -> StoryAssets {
        StoryAssets(
            ready: try image(named: "ready.png", in: directory),
            access: try image(named: "access.png", in: directory),
            assistant: try image(named: "assistant.png", in: directory),
            approval: try image(named: "approval.png", in: directory),
            watchPrompt: try image(named: "native-watch-prompt.png", in: directory)
        )
    }

    private static func image(named name: String, in directory: URL) throws -> NSImage {
        let url = directory.appendingPathComponent(name)
        guard let image = NSImage(contentsOf: url) else {
            throw RendererError.missingImage(url)
        }
        return image
    }

    private static func fixtureGeneration() -> MirrorGeneration {
        let credentials = [
            fixtureItem(
                1, title: "Acme Mail", account: "alex@example.com", host: "mail.example.com"),
            fixtureItem(
                2, title: "Example Calendar", account: "alex@example.com",
                host: "calendar.example.com"),
            fixtureItem(
                3, title: "Example Shop", account: "alex@example.com", host: "shop.example.com"),
            fixtureItem(
                4, title: "Streaming Service", account: "family@example.com",
                host: "watch.example.com"),
            fixtureItem(5, title: "Code Forge", account: "alex-dev", host: "code.example.com"),
            fixtureItem(6, title: "Home Lab", account: "admin", host: "router.home.arpa"),
            fixtureItem(
                7, title: "Example Bank", account: "alex@example.com", host: "bank.example.com"),
            fixtureItem(
                8, title: "Recovery account", account: "recovery@example.com",
                host: "id.example.com"),
        ]
        return MirrorGeneration(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0)),
            previousGenerationID: nil,
            createdAt: Date().addingTimeInterval(-120),
            sourceExportedAt: Date().addingTimeInterval(-180),
            scope: .full,
            exporterIdentifier: "com.apple.Passwords",
            exporterDisplayName: "Passwords",
            items: credentials,
            delta: MirrorDelta(addedItemIDs: credentials.map(\.id)),
            skippedCredentialCount: 2,
            skippedCredentialSummary: MirrorSkippedCredentialSummary(passkeyCount: 2)
        )
    }

    private static func fixtureItem(
        _ number: Int,
        title: String,
        account: String,
        host: String
    ) -> MirrorItem {
        let id = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(number))
        )
        return MirrorItem(
            id: id,
            sourceIdentity: MirrorSourceIdentity(
                exporterIdentifier: "com.apple.Passwords",
                accountID: Data("account-\(number)".utf8),
                itemID: Data("item-\(number)".utf8)
            ),
            title: title,
            origins: ["https://\(host)/login"],
            credentials: [.password(userName: account, password: "DOCUMENTATION-ONLY")]
        )
    }
}

private enum RendererError: Error {
    case missingWorkingDirectory
    case missingImage(URL)
    case renderFailed
}
