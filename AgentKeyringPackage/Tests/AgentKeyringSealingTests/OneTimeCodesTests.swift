// Written by AI on 2026.11.28 by model claude opus 5.5.

import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import Testing

struct OneTimeCodesTests {
    @Test("RFC 6238's SHA-1, SHA-256 and SHA-512 vectors give its codes", arguments: [
        ("SHA1", "12345678901234567890", "94287082"),
        ("SHA256", "12345678901234567890123456789012", "46119246"),
        ("SHA512", "1234567890123456789012345678901234567890123456789012345678901234", "90693936"),
    ])
    func rfc6238Vectors(algorithm: String, seed: String, expected: String) throws {
        var secret = Agentkeyring_V2_LoginSecret()
        secret.totpSeed = Data(seed.utf8)
        secret.totpDigits = 8
        secret.totpAlgorithm = algorithm
        #expect(try OneTimeCodes.codes(for: secret, from: 59, until: 60).map(\.code) == [expected])
    }
}
