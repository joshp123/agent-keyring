import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("TOTP generation")
struct TOTPGeneratorTests {
    @Test("RFC 6238 SHA vectors generate the expected codes")
    func standardVectors() throws {
        let generator = TOTPGenerator()
        let date = Date(timeIntervalSince1970: 59)

        #expect(
            try generator.code(
                secret: Data("12345678901234567890".utf8),
                period: 30,
                digits: 8,
                algorithm: .sha1,
                at: date
            ) == "94287082"
        )
        #expect(
            try generator.code(
                secret: Data("12345678901234567890123456789012".utf8),
                period: 30,
                digits: 8,
                algorithm: .sha256,
                at: date
            ) == "46119246"
        )
        #expect(
            try generator.code(
                secret: Data(
                    "1234567890123456789012345678901234567890123456789012345678901234".utf8),
                period: 30,
                digits: 8,
                algorithm: .sha512,
                at: date
            ) == "90693936"
        )
    }
}
