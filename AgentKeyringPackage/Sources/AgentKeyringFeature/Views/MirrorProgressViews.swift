import SwiftUI

@available(macOS 26.0, *)
struct SetupSteps: View {
    let providerState: ProviderEnablementState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SetupStep(
                number: 1,
                title: "Allow imports",
                state: firstStepState
            )
            StepConnector(isComplete: providerState == .enabled)
            SetupStep(number: 2, title: "Export all items", state: .pending)
            StepConnector(isComplete: false)
            SetupStep(number: 3, title: "Approve once", state: .pending)
        }
        .accessibilityElement(children: .contain)
    }

    private var firstStepState: SetupStep.State {
        switch providerState {
        case .enabled:
            .complete
        case .denied:
            .blocked
        case .unknown, .requesting:
            .current
        }
    }
}

@available(macOS 26.0, *)
private struct SetupStep: View {
    enum State {
        case pending
        case current
        case complete
        case blocked
    }

    let number: Int
    let title: LocalizedStringKey
    let state: State

    var body: some View {
        VStack(spacing: 7) {
            Group {
                switch state {
                case .complete:
                    Image(systemName: "checkmark")
                case .blocked:
                    Image(systemName: "exclamationmark")
                case .pending, .current:
                    Text(number, format: .number)
                }
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(foregroundColour)
            .frame(width: 24, height: 24)
            .background(backgroundColour, in: Circle())

            Text(title)
                .font(.caption)
                .foregroundStyle(state == .pending ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity)
    }

    private var foregroundColour: Color {
        switch state {
        case .complete:
            .white
        case .blocked:
            .orange
        case .current:
            .teal
        case .pending:
            .secondary
        }
    }

    private var backgroundColour: Color {
        switch state {
        case .complete:
            .green
        case .blocked:
            .orange.opacity(0.14)
        case .current:
            .teal.opacity(0.14)
        case .pending:
            .secondary.opacity(0.10)
        }
    }
}

@available(macOS 26.0, *)
private struct StepConnector: View {
    let isComplete: Bool

    var body: some View {
        Capsule()
            .fill(isComplete ? Color.green.opacity(0.55) : Color.secondary.opacity(0.16))
            .frame(height: 2)
            .padding(.top, 11)
            .accessibilityHidden(true)
    }
}

@available(macOS 26.0, *)
struct MirrorDeltaStrip: View {
    let status: SafeMirrorStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                DeltaValue(
                    count: status.credentialItemCount,
                    label: "credentials",
                    colour: .teal
                )
                MetricDivider()
                DeltaValue(count: status.addedCount, label: "added")
                MetricDivider()
                DeltaValue(count: status.changedCount, label: "updated")
                MetricDivider()
                DeltaValue(count: status.removedCount, label: "removed")

                if status.skippedCredentialCount > 0 {
                    MetricDivider()
                    DeltaValue(
                        count: status.skippedCredentialCount,
                        label: "skipped",
                        colour: .secondary
                    )
                }
            }

            if status.skippedCredentialCount > 0 {
                Label(skippedExplanation, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("mirror-delta")
    }

    private var skippedExplanation: String {
        guard let summary = status.skippedCredentialSummary else {
            return "Passkeys and other unsupported credentials stay in Apple Passwords."
        }

        var parts: [String] = []
        if summary.passkeyCount > 0 {
            parts.append("\(summary.passkeyCount) passkeys")
        }
        if summary.missingPasswordCount > 0 {
            parts.append("\(summary.missingPasswordCount) records without a password")
        }
        if summary.otherCount > 0 {
            parts.append("\(summary.otherCount) other credentials")
        }

        return parts.isEmpty
            ? "Unsupported credentials stay in Apple Passwords."
            : "\(parts.joined(separator: ", ")) stayed in Apple Passwords."
    }
}

@available(macOS 26.0, *)
private struct DeltaValue: View {
    let count: Int
    let label: LocalizedStringKey
    var colour: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(count, format: .number)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(colour)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

@available(macOS 26.0, *)
private struct MetricDivider: View {
    var body: some View {
        Divider()
            .frame(height: 38)
            .padding(.horizontal, 18)
    }
}
