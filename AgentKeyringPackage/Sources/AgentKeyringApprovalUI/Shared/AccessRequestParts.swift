// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The parts of a request that look the same on iPhone and Mac: the question,
// the facts Agent Keyring observed, and the agent's claim.

import SwiftUI

/// "Codex wants to sign in to / github.com / as josh@example.com".
/// The site is the largest thing on the screen: it is what Josh is deciding about.
public struct AccessRequestHeadline: View {
    let request: AccessRequest
    let siteFont: Font

    public init(request: AccessRequest, siteFont: Font = .largeTitle) {
        self.request = request
        self.siteFont = siteFont
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AccessRequestCopy.headlineLead(request))
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(request.login.site)
                .font(siteFont.weight(.bold))
                .tracking(-0.6)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Text(AccessRequestCopy.headlineAccount(request))
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Label and value on one baseline grid. Only facts Agent Keyring saw itself:
/// the machine the request came from and what the approval would allow.
public struct AccessRequestFacts: View {
    let request: AccessRequest

    public init(request: AccessRequest) {
        self.request = request
    }

    public var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            FactRow(label: AccessRequestCopy.machineLabel, value: AccessRequestCopy.machine(request.agent))
            FactRow(label: AccessRequestCopy.accessLabel, value: AccessRequestCopy.access(request))
            if case let .program(command) = request.access {
                FactRow(label: AccessRequestCopy.commandLabel, value: command, monospaced: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FactRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        GridRow {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: KeyringMetric.factLabelWidth, alignment: .leading)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .body)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Everything the agent told Agent Keyring about itself: its reason, quoted
/// behind a rule, and the folder it says it is in. Labelled as the agent's,
/// so none of it reads like something Keyring checked.
public struct AgentClaim: View {
    let request: AccessRequest
    let lineLimit: Int?

    public init(request: AccessRequest, lineLimit: Int? = nil) {
        self.request = request
        self.lineLimit = lineLimit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AccessRequestCopy.claimHeading(request.agent))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(request.agentReason)”")
                        .font(.body)
                        .lineLimit(lineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                    if let folder = request.agent.folder {
                        Text(AccessRequestCopy.claimFolder(folder))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Text(AccessRequestCopy.claimFootnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// "Waiting for you · 4:12 left", ticking once a second.
public struct WaitingStatusLine: View {
    let deadline: Date

    public init(deadline: Date) {
        self.deadline = deadline
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Circle()
                    .fill(KeyringColour.signal)
                    .frame(width: 8, height: 8)
                Text(AccessRequestCopy.waitingForYou)
                    .fontWeight(.semibold)
                Spacer(minLength: 8)
                Text(AccessRequestCopy.remaining(until: deadline, now: context.date))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
            }
            .font(.subheadline)
            .foregroundStyle(KeyringColour.signal)
        }
    }
}
