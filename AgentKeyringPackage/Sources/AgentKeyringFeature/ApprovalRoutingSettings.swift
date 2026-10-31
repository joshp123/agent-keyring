import Foundation
import Observation

@MainActor
@Observable
public final class ApprovalRoutingSettings {
    private let defaults: UserDefaults
    private var storedPhoneDelaySeconds: Int
    public var phoneDelaySeconds: Int {
        get { storedPhoneDelaySeconds }
        set {
            storedPhoneDelaySeconds = min(540, max(30, newValue))
            defaults.set(storedPhoneDelaySeconds, forKey: "phoneApprovalDelaySeconds")
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedPhoneDelaySeconds = min(540,
            max(30, defaults.object(forKey: "phoneApprovalDelaySeconds") as? Int ?? 120))
    }
}
