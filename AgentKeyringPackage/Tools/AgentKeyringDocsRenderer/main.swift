import AgentKeyringFeature
import AppKit
import Foundation
import SwiftUI

@main
enum AgentKeyringDocsRenderer {
    @MainActor
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let outputDirectory = try outputDirectory()
        try FileManager.default.createDirectory(
            at: outputDirectory,
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
            try render(
                DocumentationPreviewView(screen: screen, controller: controller),
                size: screen.logicalSize,
                to: outputURL
            )
            print("Rendered \(outputURL.path)")
        }
    }

    private static func outputDirectory() throws -> URL {
        if CommandLine.arguments.count == 2 {
            return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        }
        guard let workingDirectory = ProcessInfo.processInfo.environment["PWD"] else {
            throw RendererError.missingWorkingDirectory
        }
        return URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .appendingPathComponent("docs/media", isDirectory: true)
    }

    @MainActor
    private static func render<Content: View>(
        _ content: Content,
        size: CGSize,
        to outputURL: URL
    ) throws {
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hostingView.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * 2),
                pixelsHigh: Int(size.height * 2),
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
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.98, alpha: 1).setFill()
            NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        window.close()

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RendererError.renderFailed
        }
        try data.write(to: outputURL, options: .atomic)
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
    case renderFailed
}
