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
            storedPhoneDelaySeconds = min(Int(ApprovalRequest.lifetimeSeconds), max(1, newValue))
            defaults.set(storedPhoneDelaySeconds, forKey: "phoneApprovalDelaySeconds")
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedPhoneDelaySeconds = min(Int(ApprovalRequest.lifetimeSeconds),
            max(1, defaults.object(forKey: "phoneApprovalDelaySeconds") as? Int ?? 120))
    }
}
