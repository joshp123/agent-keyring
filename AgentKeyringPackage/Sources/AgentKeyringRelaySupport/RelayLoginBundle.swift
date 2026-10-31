import AgentKeyringCredentialImport
import AgentKeyringProtocol
import Foundation

public enum RelayLoginBundle {
    public static func contents(item: MirrorItem, loginID: String, leaseID: String,
                                approvedAt: Int64, notAfter: Int64) throws -> Agentkeyring_V1_BundleContents {
        var contents = Agentkeyring_V1_BundleContents()
        contents.leaseID = leaseID
        contents.loginID = loginID
        contents.sites = item.origins
        contents.notAfterUnixSeconds = notAfter
        let passwords = item.credentials.compactMap { credential -> (String?, String)? in
            if case let .password(name, password) = credential { return (name, password) }; return nil
        }
        guard passwords.count <= 1 else { throw RelayFailure(.invalidArgument, "This login has more than one password.") }
        contents.username = passwords.first?.0 ?? ""
        contents.password = passwords.first?.1 ?? ""
        let codes = item.credentials.filter { if case .totp = $0 { true } else { false } }
        guard codes.count <= 1 else { throw RelayFailure(.invalidArgument, "This login has more than one verification code.") }
        if let code = codes.first, case let .totp(secret, period, digits, name, algorithm, _) = code {
            guard period > 0 else { throw TOTPGeneratorError.invalidConfiguration }
            if contents.username.isEmpty { contents.username = name ?? "" }
            var start = approvedAt / Int64(period) * Int64(period)
            while start < notAfter {
                var timed = Agentkeyring_V1_TimedCode()
                timed.validFromUnixSeconds = start
                timed.validUntilUnixSeconds = min(start + Int64(period), notAfter)
                timed.code = try TOTPGenerator().code(secret: secret, period: period, digits: digits, algorithm: algorithm,
                                                     at: Date(timeIntervalSince1970: Double(start)))
                contents.oneTimeCodes.append(timed)
                start += Int64(period)
            }
        }
        return contents
    }
}
