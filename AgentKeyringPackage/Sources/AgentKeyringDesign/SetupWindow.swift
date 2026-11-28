// Written by AI on 2026.11.21 by model claude opus 5.5, from board 1 of the
// Paper file "Agent Keyring".
//
// The Mac's setup window: the steps on the left, the mascot under them, and
// the page on the right. 760 by 560, the size the checks host it at.

#if os(macOS)
import SwiftUI

public enum KeyringSetupStepProgress: Sendable { case done, current, upcoming }

public struct KeyringSetupStep: Sendable, Hashable {
    public let title: String
    public let progress: KeyringSetupStepProgress
    public init(_ title: String, _ progress: KeyringSetupStepProgress) {
        self.title = title
        self.progress = progress
    }
}

public struct KeyringSetupWindow<Page: View>: View {
    let heading: String
    let steps: [KeyringSetupStep]
    let mascot: KeyringMascotMood
    let page: Page

    /// - Parameters:
    ///   - heading: over the steps, such as "Setup on this Mac".
    ///   - steps: every step, each done, current or upcoming.
    ///   - page: a `KeyringPage`.
    public init(heading: String, steps: [KeyringSetupStep], mascot: KeyringMascotMood = .calm, @ViewBuilder page: () -> Page) {
        self.heading = heading
        self.steps = steps
        self.mascot = mascot
        self.page = page()
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                List {
                    Section {
                        ForEach(steps, id: \.self) { step in
                            row(step).listRowBackground(step.progress == .current
                                ? RoundedRectangle(cornerRadius: KeyringSpace.s2).fill(KeyringPalette.brandTint).padding(.horizontal, KeyringSpace.s2)
                                : nil)
                        }
                    } header: {
                        KeyringText(heading, as: .sectionName)
                    }
                }
                .listStyle(.sidebar)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                KeyringMascot(mascot)
                    .frame(width: KeyringSize.macSidebar - 2 * KeyringSpace.s6, height: KeyringSize.macSidebar - 2 * KeyringSpace.s6)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, KeyringSpace.s6)
            }
            .padding(.top, KeyringSpace.s8)
            .frame(width: KeyringSize.macSidebar)
            .background(KeyringPalette.sidebar)
            Divider()
            page
        }
        .frame(width: KeyringSize.macWindow.width, height: KeyringSize.macWindow.height)
    }

    private func row(_ step: KeyringSetupStep) -> some View {
        HStack(spacing: KeyringSpace.s3) {
            Image(systemName: symbol(step.progress))
                .foregroundStyle(colour(step.progress))
                .accessibilityHidden(true)
            KeyringText(step.title, as: step.progress == .current ? .heading : .body,
                        colour: step.progress == .upcoming ? KeyringPalette.ink2 : KeyringPalette.ink)
        }
        .padding(.vertical, KeyringSpace.s1)
    }

    private func symbol(_ progress: KeyringSetupStepProgress) -> String {
        switch progress {
        case .done: "checkmark.circle.fill"
        case .current: "circle.fill"
        case .upcoming: "circle"
        }
    }

    private func colour(_ progress: KeyringSetupStepProgress) -> Color {
        switch progress {
        case .done: KeyringPalette.approve
        case .current: KeyringPalette.brand
        case .upcoming: KeyringPalette.ink3
        }
    }
}
#endif
