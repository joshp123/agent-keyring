import AppKit
import SwiftUI

enum StoryScene: String, CaseIterable {
    case problem
    case rules
    case approval
    case assistant
    case complete
}

struct StoryAssets {
    let ready: NSImage
    let access: NSImage
    let assistant: NSImage
    let approval: NSImage
    let watchPrompt: NSImage
}

struct StoryFrame: View {
    let scene: StoryScene
    let assets: StoryAssets

    var body: some View {
        ZStack {
            StoryBackdrop()

            switch scene {
            case .problem:
                ProblemStory()
            case .rules:
                RulesStory(access: assets.access)
            case .approval:
                ApprovalStory(
                    approval: assets.approval,
                    watchPrompt: assets.watchPrompt
                )
            case .assistant:
                AssistantStory(assistant: assets.assistant)
            case .complete:
                CompleteStory(ready: assets.ready)
            }

            StoryBrand()
            StoryFooter()
        }
        .frame(width: 1_920, height: 1_080)
    }
}

private struct StoryBackdrop: View {
    var body: some View {
        ZStack {
            StoryColour.background

            RadialGradient(
                colors: [
                    StoryColour.cyanGlow,
                    StoryColour.background.opacity(0),
                ],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 940
            )

            RadialGradient(
                colors: [
                    StoryColour.violetGlow,
                    StoryColour.background.opacity(0),
                ],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 1_020
            )
        }
        .ignoresSafeArea()
    }
}

private struct StoryBrand: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(
                    LinearGradient(
                        colors: [.cyan, .teal],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: .rect(cornerRadius: 15)
                )
            Text("Agent Keyring")
                .font(StoryFont.display(30, weight: .semibold))
                .foregroundStyle(.white)
        }
        .position(x: 205, y: 78)
    }
}

private struct StoryFooter: View {
    var body: some View {
        VStack {
            Spacer()
            HStack {
                Text("github.com/joshp123/agent-keyring")
                Spacer()
                Text("Apple Passwords  •  Apple Watch  •  local")
            }
            .font(StoryFont.display(20, weight: .medium))
            .foregroundStyle(StoryColour.quiet)
            .padding(.horizontal, 64)
            .padding(.bottom, 38)
        }
    }
}

private struct ProblemStory: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 42) {
            StoryHeading(
                eyebrow: "THE PROBLEM",
                title: "You tell Codex what you want.",
                detail: "Then the task reaches a password."
            )

            HStack(spacing: 34) {
                ConversationCard(
                    label: "YOU",
                    symbol: "person.fill",
                    tint: .purple,
                    text: "Sign in to billing.example.com and download my latest invoice."
                )
                Image(systemName: "arrow.right")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(StoryColour.muted)
                ConversationCard(
                    label: "CODEX",
                    symbol: "sparkles",
                    tint: .cyan,
                    text: "I found the invoice, but the site needs a password.",
                    status: "Password required"
                )
            }

            Label("Without credential access, the task stops here.", systemImage: "lock.fill")
                .font(StoryFont.display(34, weight: .semibold))
                .foregroundStyle(Color.orange)
        }
        .frame(width: 1_600, alignment: .leading)
        .offset(y: 36)
    }
}

private struct RulesStory: View {
    let access: NSImage

    var body: some View {
        HStack(spacing: 70) {
            VStack(alignment: .leading, spacing: 30) {
                StoryHeading(
                    eyebrow: "NOT ANY MORE",
                    title: "Your credential. Your rule.",
                    detail:
                        "Agent Keyring matches the website, then applies the access rule you chose."
                )

                VStack(spacing: 18) {
                    RuleCard(
                        symbol: "checkmark.circle.fill",
                        colour: .green,
                        title: "Allow automatically",
                        detail: "Codex continues without interrupting you."
                    )
                    RuleCard(
                        symbol: "applewatch",
                        colour: .blue,
                        title: "Ask each time",
                        detail: "Approve the exact site and account on Apple Watch or Touch ID."
                    )
                    RuleCard(
                        symbol: "nosign",
                        colour: .red,
                        title: "Blocked",
                        detail: "Agent Keyring refuses the request."
                    )
                }
            }
            .frame(width: 700)

            WindowCapture(image: access)
                .frame(width: 960)
        }
        .frame(width: 1_700)
        .offset(y: 38)
    }
}

private struct ApprovalStory: View {
    let approval: NSImage
    let watchPrompt: NSImage

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            StoryHeading(
                eyebrow: "ASK EACH TIME",
                title: "Stay in the loop when it matters.",
                detail: "Check the website and account. One approval releases one requested field."
            )

            HStack(spacing: 70) {
                WindowCapture(image: approval)
                    .frame(width: 700)

                VStack(spacing: 28) {
                    Text("Native macOS approval")
                        .font(StoryFont.display(28, weight: .semibold))
                        .foregroundStyle(StoryColour.muted)
                    Image(nsImage: watchPrompt)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 460)
                        .shadow(color: .black.opacity(0.22), radius: 34, y: 20)
                    Label(
                        "Approve on Apple Watch or Touch ID",
                        systemImage: "applewatch.radiowaves.left.and.right"
                    )
                    .font(StoryFont.display(30, weight: .semibold))
                    .foregroundStyle(.white)
                }
                .frame(width: 610)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 1_650)
        .offset(y: 52)
    }
}

private struct AssistantStory: View {
    let assistant: NSImage

    var body: some View {
        HStack(spacing: 70) {
            VStack(alignment: .leading, spacing: 34) {
                StoryHeading(
                    eyebrow: "LET YOUR AI CHOOSE",
                    title: "Do not sort every credential by hand.",
                    detail: "Copy a safe prompt and paste it into the AI you already use."
                )

                VStack(alignment: .leading, spacing: 24) {
                    StoryStep(number: 1, text: "Your AI asks about your tasks and risk preferences")
                    StoryStep(
                        number: 2,
                        text:
                            "It recommends Allow automatically, Ask each time or Blocked for every credential"
                    )
                    StoryStep(number: 3, text: "You review every change before applying it")
                }

                Label(
                    "The prompt contains metadata, never passwords or verification codes.",
                    systemImage: "lock.shield.fill"
                )
                .font(StoryFont.display(26, weight: .medium))
                .foregroundStyle(StoryColour.muted)
            }
            .frame(width: 700)

            WindowCapture(image: assistant)
                .frame(width: 900)
        }
        .frame(width: 1_700)
        .offset(y: 38)
    }
}

private struct CompleteStory: View {
    let ready: NSImage

    var body: some View {
        HStack(spacing: 85) {
            VStack(alignment: .leading, spacing: 36) {
                StoryHeading(
                    eyebrow: "TASK CONTINUES",
                    title: "Ask Codex normally.",
                    detail: "Agent Keyring handles credentials according to your rules."
                )

                ConversationCard(
                    label: "CODEX",
                    symbol: "checkmark.seal.fill",
                    tint: .green,
                    text: "Signed in. Your latest invoice is downloaded.",
                    status: "Done"
                )

                VStack(alignment: .leading, spacing: 14) {
                    Label("Apple Passwords stays the source of truth", systemImage: "key.fill")
                    Label(
                        "Secrets stay out of chat and command output",
                        systemImage: "lock.shield.fill")
                }
                .font(StoryFont.display(28, weight: .medium))
                .foregroundStyle(StoryColour.muted)
            }
            .frame(width: 760)

            WindowCapture(image: ready)
                .frame(width: 840)
        }
        .frame(width: 1_700)
        .offset(y: 45)
    }
}

private struct StoryHeading: View {
    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(eyebrow)
                .font(StoryFont.display(26, weight: .bold))
                .tracking(2.2)
                .foregroundStyle(StoryColour.accent)
            Text(title)
                .font(StoryFont.display(68, weight: .bold))
                .tracking(-1.2)
                .foregroundStyle(.white)
            Text(detail)
                .font(StoryFont.display(34))
                .foregroundStyle(StoryColour.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ConversationCard: View {
    let label: String
    let symbol: String
    let tint: Color
    let text: String
    var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 50, height: 50)
                    .background(tint.opacity(0.12), in: .circle)
                Text(label)
                    .font(StoryFont.display(22, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(StoryColour.mutedInk)
                Spacer()
                if let status {
                    Text(status)
                        .font(StoryFont.display(20, weight: .semibold))
                        .foregroundStyle(status == "Done" ? Color.green : Color.orange)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(
                            (status == "Done" ? Color.green : Color.orange).opacity(0.11),
                            in: .capsule
                        )
                }
            }
            Text(text)
                .font(StoryFont.display(34, weight: .medium))
                .foregroundStyle(StoryColour.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(30)
        .frame(width: 700, alignment: .topLeading)
        .frame(minHeight: 245, alignment: .topLeading)
        .background(.white.opacity(0.97), in: .rect(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .stroke(StoryColour.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 38, y: 24)
    }
}

private struct RuleCard: View {
    let symbol: String
    let colour: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(colour)
                .frame(width: 62, height: 62)
                .background(colour.opacity(0.12), in: .circle)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(StoryFont.display(32, weight: .bold))
                    .foregroundStyle(StoryColour.ink)
                Text(detail)
                    .font(StoryFont.display(25))
                    .foregroundStyle(StoryColour.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(22)
        .background(.white.opacity(0.97), in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(colour.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct StoryStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Text(number, format: .number)
                .font(StoryFont.display(23, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(StoryColour.accent, in: .circle)
            Text(text)
                .font(StoryFont.display(30, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WindowCapture: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
    }
}

private enum StoryColour {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.09)
    static let accent = Color(red: 0.05, green: 0.78, blue: 0.88)
    static let cyanGlow = Color.cyan.opacity(0.17)
    static let violetGlow = Color.purple.opacity(0.12)
    static let muted = Color.white.opacity(0.68)
    static let quiet = Color.white.opacity(0.38)
    static let ink = Color(red: 0.07, green: 0.10, blue: 0.16)
    static let mutedInk = Color(red: 0.34, green: 0.38, blue: 0.44)
    static let hairline = Color.white.opacity(0.20)
}

private enum StoryFont {
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Helvetica Neue", fixedSize: size).weight(weight)
    }
}
