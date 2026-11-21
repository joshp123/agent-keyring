// Written by AI on 2026.11.21 by model claude opus 5.5, from the screens the
// Passwords app shows when it exports to another app (macOS 27), drawn
// small, with the thing to click marked. Pictures, not controls: nothing in
// them can be clicked.

import SwiftUI

/// What the Passwords app shows at one step of the "Copy your passwords"
/// guide, drawn close enough to recognise, with the thing to click ringed.
public struct PasswordsExportPicture: View {
    /// Apple's screens, in the order they appear.
    public enum Screen: Sendable, CaseIterable {
        /// The File menu, with Export All Items to App…
        case fileMenu
        /// "Some items will not be exported." Only for people with Sign in with Apple or shared items.
        case someItemsAlert
        /// The Export Passwords sheet.
        case exportSheet
        /// macOS asking for Touch ID or the Mac's password.
        case touchID
        /// Select a Destination, with Agent Keyring chosen.
        case selectDestination
        /// Export N items to "Agent Keyring"?
        case confirm
    }

    /// The guide's five steps and the screens each one shows. Step 2 shows the
    /// alert some people see first, then the sheet everyone sees.
    public static func screens(forGuideStep step: Int) -> [Screen] {
        switch step {
        case 1: [.fileMenu]
        case 2: [.someItemsAlert, .exportSheet]
        case 3: [.touchID]
        case 4: [.selectDestination]
        default: [.confirm]
        }
    }

    let screens: [Screen]
    let earlierVersion: Bool
    let items: Int

    /// - Parameters:
    ///   - guideStep: 1 to 5, as the page's guide counts them.
    ///   - earlierVersion: also show the earlier "AgentKeyring" in Select a Destination, dimmed.
    ///   - items: the number Apple's last sheet shows; a sample is fine, Apple counts it.
    public init(guideStep: Int, earlierVersion: Bool = false, items: Int = 547) {
        self.screens = Self.screens(forGuideStep: guideStep)
        self.earlierVersion = earlierVersion
        self.items = items
    }

    public var body: some View {
        HStack(alignment: .center, spacing: KeyringSpace.s4) {
            ForEach(Array(screens.enumerated()), id: \.offset) { index, screen in
                if index > 0 {
                    Image(systemName: "arrow.right").foregroundStyle(KeyringPalette.ink2).accessibilityHidden(true)
                }
                drawing(screen)
            }
        }
        .padding(KeyringSpace.s3)
        .frame(maxWidth: .infinity)
        .background(KeyringPalette.fill, in: .rect(cornerRadius: KeyringRadius.card))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func drawing(_ screen: Screen) -> some View {
        switch screen {
        case .fileMenu: FileMenu()
        case .someItemsAlert: SomeItemsAlert()
        case .exportSheet: ExportSheet()
        case .touchID: TouchIDDialog()
        case .selectDestination: SelectDestination(earlierVersion: earlierVersion)
        case .confirm: Confirm(items: items)
        }
    }
}

/// Apple's blue, for the buttons and the chosen menu item in the pictures.
private let appleBlue = Color(hex: 0x1F7BFF)

/// A dialog or sheet: white, rounded, a soft shadow.
private struct Panel<Content: View>: View {
    let width: CGFloat
    let alignment: HorizontalAlignment
    @ViewBuilder let content: Content

    init(width: CGFloat, alignment: HorizontalAlignment = .leading, @ViewBuilder content: () -> Content) {
        self.width = width
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 6) { content }
            .padding(10)
            .frame(width: width, alignment: Alignment(horizontal: alignment, vertical: .top))
            .background(KeyringPalette.surface, in: .rect(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}

/// One of Apple's buttons, drawn. `marked`: ringed, with the pointer on it.
private struct PictureButton: View {
    let title: String
    var prominent = false
    var marked = false
    var wide = false

    var body: some View {
        KeyringText(title, as: .pictureText, colour: prominent ? .white : KeyringPalette.ink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, KeyringSpace.s2)
            .padding(.vertical, 3)
            .frame(maxWidth: wide ? .infinity : nil)
            .background(prominent ? appleBlue : KeyringPalette.fill, in: .capsule)
            .clickHere(marked)
    }
}

extension View {
    /// The guide's mark for "click this": a ring in Keyring blue and, unless it is to be touched, the pointer.
    func clickHere(_ marked: Bool = true, pointer: Bool = true) -> some View {
        overlay {
            if marked {
                Capsule().strokeBorder(KeyringPalette.brand, lineWidth: 2).padding(-4)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if marked, pointer {
                Image(systemName: "cursorarrow").font(.system(size: 14)).foregroundStyle(.black)
                    .shadow(color: .white, radius: 1).offset(x: 8, y: 10).accessibilityHidden(true)
            }
        }
    }
}

private struct FileMenu: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: KeyringSpace.s2) {
                Image(systemName: "apple.logo").font(.system(size: 11)).foregroundStyle(KeyringPalette.ink)
                KeyringText(PasswordsExportCopy.appName, as: .pictureTitle).fixedSize()
                ForEach(PasswordsExportCopy.menus, id: \.self) { menu in
                    KeyringText(menu, as: .pictureText)
                        .fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(menu == "File" ? KeyringPalette.line : .clear, in: .capsule)
                }
            }
            .padding(.horizontal, KeyringSpace.s3).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KeyringPalette.surface.opacity(0.7))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(PasswordsExportCopy.fileMenu.enumerated()), id: \.offset) { _, item in
                    if let item {
                        let chosen = item == PasswordsExportCopy.exportAllItems
                        KeyringText(item, as: .pictureText, colour: chosen ? .white : KeyringPalette.ink)
                            .padding(.horizontal, KeyringSpace.s2).padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(chosen ? appleBlue : .clear, in: .rect(cornerRadius: 4))
                            .clickHere(chosen)
                    } else {
                        Divider().padding(.vertical, 2)
                    }
                }
            }
            .padding(KeyringSpace.s1)
            .frame(width: 190)
            .background(KeyringPalette.surface, in: .rect(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .padding(.leading, 74)
        }
        .frame(width: 330)
    }
}

private struct PasswordsIcon: View {
    var body: some View {
        HStack(spacing: -3) {
            ForEach([Color(hex: 0xF5C542), Color(hex: 0x4CC764), Color(hex: 0x3D8BFF)], id: \.self) {
                Image(systemName: "key.fill").foregroundStyle($0)
            }
        }
        .font(.system(size: 13))
        .frame(width: 30, height: 30)
        .background(Color(hex: 0x111114), in: .rect(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct SomeItemsAlert: View {
    var body: some View {
        Panel(width: 160) {
            // Apple's paragraphs under the title are left out, for room: the title and the keys are what he will recognise.
            PasswordsIcon()
            KeyringText(PasswordsExportCopy.someItemsTitle, as: .pictureTitle)
            HStack(spacing: KeyringSpace.s1) {
                PictureButton(title: PasswordsExportCopy.cancel, wide: true)
                PictureButton(title: PasswordsExportCopy.continueButton, prominent: true, marked: true, wide: true)
            }
        }
    }
}

private struct ExportSheet: View {
    var body: some View {
        Panel(width: 210) {
            Image(systemName: "square.and.arrow.up.on.square").font(.system(size: 20)).foregroundStyle(appleBlue)
                .frame(maxWidth: .infinity).accessibilityHidden(true)
            // Apple's sentence under the title is left out, for room, as in Select a Destination.
            KeyringText(PasswordsExportCopy.exportTitle, as: .pictureTitle)
            HStack(spacing: KeyringSpace.s1) {
                Spacer(minLength: 0)
                PictureButton(title: PasswordsExportCopy.cancel)
                PictureButton(title: PasswordsExportCopy.continueButton, prominent: true, marked: true)
            }
            .padding(.top, KeyringSpace.s1)
        }
    }
}

private struct TouchIDDialog: View {
    var body: some View {
        Panel(width: 190) {
            Image(systemName: "touchid").font(.system(size: 24)).foregroundStyle(Color(hex: 0xE5455C))
                .padding(KeyringSpace.s1)
                .clickHere(pointer: false)
                .padding(.bottom, KeyringSpace.s1)
                .accessibilityHidden(true)
            KeyringText(PasswordsExportCopy.touchIDTitle, as: .pictureTitle)
            KeyringText(PasswordsExportCopy.touchIDBody, as: .pictureText)
            PictureButton(title: PasswordsExportCopy.usePassword, wide: true)
            PictureButton(title: PasswordsExportCopy.cancel, wide: true)
        }
    }
}

private struct SelectDestination: View {
    let earlierVersion: Bool

    var body: some View {
        Panel(width: 250) {
            Image(systemName: "square.2.layers.3d").font(.system(size: 20)).foregroundStyle(appleBlue)
                .frame(maxWidth: .infinity).accessibilityHidden(true)
            // Apple's sentence under the title is left out: the list is what he looks for, and the page has no room for both.
            KeyringText(PasswordsExportCopy.destinationTitle, as: .pictureTitle)
            VStack(spacing: 0) {
                HStack(spacing: KeyringSpace.s2) {
                    KeyringMascot(.calm).frame(width: 16, height: 16)
                    KeyringText(PasswordsExportCopy.agentKeyring, as: .pictureTitle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, KeyringSpace.s2).padding(.vertical, 4)
                .background(KeyringPalette.line, in: .rect(cornerRadius: 6))
                .clickHere()
                if earlierVersion {
                    HStack(spacing: KeyringSpace.s2) {
                        Image(systemName: "key.horizontal.fill").font(.system(size: 8)).foregroundStyle(.white)
                            .frame(width: 16, height: 16).background(Color(hex: 0x15233D), in: .rect(cornerRadius: 4))
                            .accessibilityHidden(true)
                        KeyringText(PasswordsExportCopy.earlierVersion, as: .pictureText, colour: KeyringPalette.ink3)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, KeyringSpace.s2).padding(.vertical, 4)
                }
            }
            HStack(spacing: KeyringSpace.s1) {
                Spacer(minLength: 0)
                PictureButton(title: PasswordsExportCopy.cancel)
                PictureButton(title: PasswordsExportCopy.continueButton, prominent: true, marked: true)
            }
            .padding(.top, KeyringSpace.s1)
        }
    }
}

private struct Confirm: View {
    let items: Int

    var body: some View {
        Panel(width: 270) {
            KeyringMascot(.calm).frame(width: 28, height: 28).frame(maxWidth: .infinity)
            KeyringText(PasswordsExportCopy.confirmTitle(items), as: .pictureTitle)
            KeyringText(PasswordsExportCopy.confirmBody(items), as: .pictureText, colour: KeyringPalette.ink2)
            HStack(spacing: KeyringSpace.s1) {
                Spacer(minLength: 0)
                PictureButton(title: PasswordsExportCopy.cancel)
                PictureButton(title: PasswordsExportCopy.continueInAgentKeyring, prominent: true, marked: true)
            }
            .padding(.top, KeyringSpace.s1)
        }
    }
}
