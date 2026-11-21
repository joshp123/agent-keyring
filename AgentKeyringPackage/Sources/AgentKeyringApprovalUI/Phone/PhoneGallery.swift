// Written by AI on 2026.11.21 by model Claude Opus 5.5.
//
// Every iPhone page in each state worth seeing, from the sample backend, for
// the cut-off check (PageGallery). A state missing here is one nobody has looked at.

#if os(iOS)
import AgentKeyringDesign
import SwiftUI

@MainActor
enum PhoneGallery {
    static func model(_ step: String?) -> PhoneModel {
        let sample = PhoneSampleBackend(step: step)
        return PhoneModel(backend: sample, initial: sample.current)
    }

    static var entries: [KeyringGalleryEntry] {
        let firstRun = ["start", "trouble", "found-mac", "approve-on-mac", "denied", "cant-reach", "expired", "receiving",
                        "notifications", "notifications-checklist", "notifications-off", "practice-offer", "practice-waiting",
                        "not-arrived", "mac-asleep", "setting-up", "approved", "denied-practice", "no-answer", "offer-watch", "no-watch"]
        let watchFlow = ["watch-not-paired", "watch-missing", "add-watch", "watch-waiting", "watch-expired", "watch-passcode",
                         "watch-encrypting", "watch-failed", "watch-added"]
        let pages = (firstRun + watchFlow).map { step in
            KeyringGalleryEntry("iphone-\(step)", .phone) {
                let model = model(step)
                PhoneFirstRunView(stage: model.snapshot.firstRun, model: model)
            }
        }
        let request = model(nil)
        let all = pages + [
            KeyringGalleryEntry("iphone-request", .phone) {
                PhoneRequestView(model: request, request: request.snapshot.requests[0])
            },
            KeyringGalleryEntry("iphone-request-practice", .phone) {
                PhoneRequestView(model: request, request: .practice(), practice: true)
            },
            KeyringGalleryEntry("iphone-held-notification", .phone) { PhoneNotificationCard(request: request.snapshot.requests[0]) },
            KeyringGalleryEntry("iphone-home", .phone) { PhoneHomeView(model: model(nil)) },
            KeyringGalleryEntry("iphone-home-empty", .phone) { PhoneHomeView(model: model("empty")) },
            KeyringGalleryEntry("iphone-passwords", .phone) { PhoneLoginsView(model: model(nil)) },
            KeyringGalleryEntry("iphone-devices", .phone) { PhoneDevicesView(model: model(nil)) },
            KeyringGalleryEntry("iphone-settings", .phone) { PhoneSettingsView(model: model(nil)) },
        ]
        // KEYRING_GALLERY_PART=n/m checks every m-th page from the n-th, for a machine short of memory.
        guard let part = ProcessInfo.processInfo.environment["KEYRING_GALLERY_PART"]?.split(separator: "/").compactMap({ Int($0) }),
              part.count == 2, part[1] > 0 else { return all }
        return all.enumerated().filter { $0.offset % part[1] == part[0] }.map(\.element)
    }
}
#endif
