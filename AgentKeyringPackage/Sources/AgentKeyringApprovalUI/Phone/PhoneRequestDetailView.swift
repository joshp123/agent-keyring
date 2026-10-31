// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// A request after the fact: what was asked, what you answered, what the
// agent did with it. Read-only, apart from ending access that is in use.

#if os(iOS)
import SwiftUI

struct PhoneRequestDetailView: View {
    let model: PhoneKeyringModel
    let request: AccessRequest

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AccessRequestHeadline(request: request, siteFont: .title)
                OutcomeLine(request: request)
                if request.state.isInUse {
                    Button(AccessRequestCopy.endNow) { Task { await model.endAccess(request.id) } }
                        .buttonStyle(DecisionButtonStyle(colour: KeyringColour.deny, height: 44))
                }
                if case let .denied(_, _, askAgainAfter?) = request.state, request.state.isHoldingOffNewRequests(now: .now) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(AccessRequestCopy.askAgainUntil(askAgainAfter))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button(AccessRequestCopy.letAskAgain) { Task { await model.allowAskingAgain(request.id) } }
                            .buttonStyle(.quiet(height: 44))
                    }
                }
                Hairline()
                AccessRequestFacts(request: request)
                Hairline()
                AgentClaim(request: request)
                if !request.events.isEmpty {
                    Hairline()
                    Timeline(events: request.events)
                }
            }
            .padding(.horizontal, KeyringMetric.margin)
            .padding(.vertical, 12)
        }
        .navigationTitle(AccessRequestCopy.dayAndClock(request.askedAt))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OutcomeLine: View {
    let request: AccessRequest

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: outcomeSymbol(request.state))
                .foregroundStyle(outcomeColour(request.state) ?? .secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(AccessRequestCopy.outcome(request) ?? "")
                    .font(.body.weight(.semibold))
                if case let .denied(_, reply?, _) = request.state {
                    Text("You replied: “\(reply)”")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct Timeline: View {
    let events: [AccessRequestEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What happened")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(events, id: \.self) { event in
                    GridRow {
                        Text(AccessRequestCopy.clock(event.time))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(event.text)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}
#endif
