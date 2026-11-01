import AgentKeyringProtocol
import AgentKeyringRelaySupport
import Foundation

extension RelayCrypto {
    static func loginCopyContents(item: MirrorItem) throws -> Agentkeyring_V1_AutomaticLoginContents {
        let resolver = CredentialResolver()
        let candidate = resolver.candidate(for: item)
        var contents = Agentkeyring_V1_AutomaticLoginContents()
        contents.loginID = item.id.uuidString
        contents.sites = item.origins.sorted()
        contents.username = candidate.username ?? ""
        if candidate.availableFields.contains(.password) { contents.password = try resolver.value(in: item, field: .password) }
        if candidate.availableFields.contains(.totp) {
            for credential in item.credentials {
                if case let .totp(secret, period, digits, _, algorithm, _) = credential {
                    contents.totpSeed = secret
                    contents.totpPeriodSeconds = Int32(period)
                    contents.totpDigits = Int32(digits)
                    contents.totpAlgorithm = algorithm.rawValue.uppercased()
                }
            }
        }
        return contents
    }

    static func bundle(item: MirrorItem, leaseID: String, approvedAt: Int64, notAfter: Int64) throws -> Agentkeyring_V1_BundleContents {
        let resolver = CredentialResolver()
        let candidate = resolver.candidate(for: item)
        var contents = Agentkeyring_V1_BundleContents()
        contents.leaseID = leaseID
        contents.loginID = item.id.uuidString
        contents.sites = item.origins
        contents.notAfterUnixSeconds = notAfter
        if candidate.availableFields.contains(.username) { contents.username = try resolver.value(in: item, field: .username) }
        if candidate.availableFields.contains(.password) { contents.password = try resolver.value(in: item, field: .password) }
        if candidate.availableFields.contains(.totp) {
            let periods = item.credentials.compactMap { credential -> UInt16? in
                if case let .totp(_, period, _, _, _, _) = credential { period } else { nil }
            }
            guard periods.count == 1, let period = periods.first, period > 0 else { throw CredentialResolverError.invalidTOTP }
            var start = approvedAt / Int64(period) * Int64(period)
            while start < notAfter {
                var timed = Agentkeyring_V1_TimedCode()
                timed.validFromUnixSeconds = start
                timed.validUntilUnixSeconds = min(start + Int64(period), notAfter)
                timed.code = try resolver.value(in: item, field: .totp, now: Date(timeIntervalSince1970: Double(start)))
                contents.oneTimeCodes.append(timed)
                start += Int64(period)
            }
        }
        return contents
    }
}
