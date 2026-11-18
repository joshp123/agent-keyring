// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// First run on the iPhone (Paper, "First run"): one list that ticks itself.
// The app joins, asks iOS's question and tests itself; he only answers iOS
// and the requests. The same list, all ticked, greets him once it is ready.

#if os(iOS)
import SwiftUI
import UIKit

struct PhoneSetupList: View {
    let setup: PhoneSetup

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                KeyholeIcon(size: 64)
                VStack(spacing: 4) {
                    Text(PhoneCopy.appName).font(.largeTitle.bold()).tracking(-0.75).foregroundStyle(Phone.ink)
                    Text(setup.isReady ? PhoneCopy.readyLead : PhoneCopy.firstRunLead)
                        .font(.body).foregroundStyle(Phone.ink2)
                }
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)
            .padding(.top, 34)
            .padding(.bottom, 26)

            VStack(spacing: 0) {
                ForEach(setup.lines) { line in
                    Divider().overlay(Phone.line)
                    SetupLineView(line: line)
                }
                Divider().overlay(Phone.line)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Phone.surface)
    }
}

private struct SetupLineView: View {
    let line: PhoneSetupLine

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            mark.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.title).font(.body.weight(.semibold)).foregroundStyle(line.mark == .notYet ? Phone.ink2 : Phone.ink)
                if let detail = line.detail {
                    Text(detail).font(.subheadline).foregroundStyle(Phone.ink2)
                }
                if line.opensSettings {
                    Button(PhoneCopy.openSettings) {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(RowButtonStyle(fill: Phone.ink, text: Phone.surface))
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 13)
    }

    @ViewBuilder private var mark: some View {
        switch line.mark {
        case .done:
            Circle().fill(Phone.approve)
                .overlay(Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(Phone.onAnswer))
        case .working:
            Circle().strokeBorder(Phone.ink, lineWidth: 3)
        case .notYet:
            Circle().strokeBorder(Phone.line, lineWidth: 3)
        case .failed:
            Circle().fill(Phone.deny)
                .overlay(Image(systemName: "exclamationmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(Phone.onAnswer))
        }
    }
}

/// The test request and a new device's request: the same sheet as a login
/// request, with only Deny and Approve with Face ID.
struct PhoneSimpleRequestView: View {
    let model: PhoneModel
    let lead: String
    let title: String
    let detail: String
    let footnote: String
    let approve: () async -> Void
    let deny: () async -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                KeyholeIcon(size: 22)
                Text(PhoneCopy.appName).font(.subheadline.weight(.semibold)).foregroundStyle(Phone.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 18)
            VStack(spacing: 1) {
                Text(lead).font(.subheadline).foregroundStyle(Phone.ink2)
                Text(title).font(.largeTitle.bold()).tracking(-0.75).foregroundStyle(Phone.ink)
                Text(detail).font(.subheadline).foregroundStyle(Phone.ink2)
            }
            .multilineTextAlignment(.center)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 40)
            VStack(spacing: 10) {
                Button(PhoneCopy.deny) { Task { await deny() } }
                    .buttonStyle(PillButtonStyle(fill: Phone.deny, height: 50, stretches: false))
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Button { Task { await approve() } } label: {
                    Label(PhoneCopy.approveWithFaceID, systemImage: "faceid").labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillButtonStyle(fill: Phone.approve))
                Text(footnote).font(.footnote).foregroundStyle(Phone.ink2).multilineTextAlignment(.center)
            }
            .disabled(model.answering != nil)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 44)
        .background(Phone.surface)
        .ignoresSafeArea(.container, edges: .bottom)
        .interactiveDismissDisabled()
    }
}
#endif
