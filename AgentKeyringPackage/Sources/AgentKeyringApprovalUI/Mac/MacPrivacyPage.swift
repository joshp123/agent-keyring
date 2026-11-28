// Written by AI on 2026.11.25 by model gemini-4-neon; split into its own file on 2026.11.27 by model claude opus 5.5.
//
// Production macOS view for Step 2 (Privacy) of first run.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import AppKit
import SwiftUI

public struct MacPrivacyPageActions {
    public var openPrivacyPolicy: () -> Void = { NSWorkspace.shared.open(PrivacyCopy.privacyPolicyURL) }
    public var openSourceCode: () -> Void = { NSWorkspace.shared.open(PrivacyCopy.sourceCodeURL) }
    public var back: () -> Void = {}
    public var continueOn: () -> Void = {}
    public init() {}
}

public struct MacPrivacyPage: View {

    let actions: MacPrivacyPageActions

    public init(actions: MacPrivacyPageActions = MacPrivacyPageActions()) {
        self.actions = actions
    }

    public var body: some View {
        MacFirstRunWindow(step: 2, mascot: .calm) {
            VStack(alignment: .leading, spacing: KeyringSpace.s3) {
                VStack(alignment: .leading, spacing: KeyringSpace.s1) {
                    KeyringText(PartsCopy.step(2, of: 5), as: .stepMarker)
                    KeyringText(PrivacyCopy.title, as: .title)
                    KeyringText(PrivacyCopy.subtitle, as: .meta)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(PrivacyCopy.points.enumerated()), id: \.element.id) { index, point in
                        if index > 0 { Divider() }
                        HStack(alignment: .top, spacing: KeyringSpace.s3) {
                            Image(systemName: point.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(KeyringPalette.brand)
                                .frame(width: 26, height: 26)
                                .background(KeyringPalette.brandTint, in: .rect(cornerRadius: 7, style: .continuous))
                                .padding(.top, 1)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 1) {
                                KeyringText(point.heading, as: .label, colour: KeyringPalette.ink)
                                KeyringText(point.body, as: .caption)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, KeyringSpace.s4)
                        .padding(.vertical, 10)
                    }
                }
                .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card))
                .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card).strokeBorder(KeyringPalette.line))

                Spacer(minLength: 0)

                Divider()

                HStack(spacing: KeyringSpace.s3) {
                    KeyringButton(.link(PrivacyCopy.privacyPolicy, perform: actions.openPrivacyPolicy))
                    KeyringButton(.link(PrivacyCopy.readSourceCode, perform: actions.openSourceCode))
                    Spacer(minLength: KeyringSpace.s2)
                    KeyringButton(.plain(FirstRunCopy.back, perform: actions.back))
                    KeyringButton(.advance(FirstRunCopy.continueButton, perform: actions.continueOn))
                }
            }
            .padding(.horizontal, KeyringSpace.s8)
            .padding(.top, KeyringSpace.s6)
            .padding(.bottom, KeyringSpace.s5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(KeyringPalette.canvas)
        }
    }
}
#endif
