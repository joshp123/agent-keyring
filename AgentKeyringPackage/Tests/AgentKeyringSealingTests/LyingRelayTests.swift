// Written by AI on 2026.11.19 by model claude opus 5.5.
// A relay that lies about which password a request is for. The relay writes
// the request and sends a login beside it; only the Catalogue is signed. The
// iPhone and Apple Watch name and approve a request from the signed Catalogue
// (Sealing.signedLogin), so a bank password can't be passed off as example.com.
// Below it, the push environment read from the signing profile.

import AgentKeyringProtocol
@testable import AgentKeyringSealing
import CryptoKit
import Foundation
import Testing

struct LyingRelayTests {
    func login(_ id: String, _ site: String, _ rule: Agentkeyring_V2_Rule = .ask) -> Agentkeyring_V2_Login {
        var login = Agentkeyring_V2_Login()
        login.loginID = id; login.title = site; login.sites = ["https://\(site)"]; login.account = "josh@\(site)"; login.rule = rule
        return login
    }

    var catalogue: Catalogue {
        var catalogue = Catalogue()
        catalogue.domain = "agentkeyring.catalogue.v2"
        catalogue.logins = [login("bank", "bank.example"), login("example", "example.com"), login("blocked", "blocked.example", .blocked)]
        return catalogue
    }

    func request(for loginID: String) -> KeyringRequest {
        var request = KeyringRequest()
        request.domain = "agentkeyring.request.v2"; request.requestID = "r1"; request.loginID = loginID; request.agent = "Codex"
        return request
    }

    /// The relay asks for the bank password and sends example.com's details beside it.
    @Test func theSignedCatalogueNamesTheRequestNotTheRelay() throws {
        var work = Agentkeyring_V2_Work()
        work.request = try request(for: "bank").serializedData()
        work.login = login("example", "example.com")  // the lie
        let named = try Sealing.signedLogin(for: Sealing.parseRequest(work.request), in: catalogue)
        #expect(named.sites == ["https://bank.example"])
        #expect(named.account == "josh@bank.example")
    }

    @Test func aBlockedPasswordCanNotBeApproved() {
        #expect(throws: Sealing.Failure.notAllowedForSigner) { try Sealing.signedLogin(for: request(for: "blocked"), in: catalogue) }
    }

    @Test func aPasswordMissingFromTheCatalogueCanNotBeApproved() {
        #expect(throws: Sealing.Failure.wrongLogin) { try Sealing.signedLogin(for: request(for: "invented"), in: catalogue) }
        #expect(throws: Sealing.Failure.wrongLogin) { try Sealing.signedLogin(for: request(for: "bank"), in: nil) }
    }

    /// The relay sends the bank's sealed copy with a request for example.com: the approval refuses to carry it.
    @Test func aSealedCopyForAnotherPasswordIsRefused() throws {
        var secret = Agentkeyring_V2_LoginSecret()
        secret.loginID = "bank"; secret.username = "josh"; secret.password = "bank-password"
        let machine = P256.KeyAgreement.PrivateKey()
        #expect(throws: Sealing.Failure.notForThisRequest) {
            try Sealing.approve(request: request(for: "example").serializedData(), secret: secret, sites: ["https://example.com"],
                                receivingKey: machine.publicKey, signerKeyID: "device") { _ in Data() }
        }
    }
}


struct PushEnvironmentTests {
    func profile(_ environment: String) -> Data {
        let plist = try! PropertyListSerialization.data(fromPropertyList: ["Entitlements": ["aps-environment": environment]], format: .xml, options: 0)
        return Data([0x30, 0x80]) + plist + Data([0x00, 0x00])  // a CMS envelope around the property list
    }

    @Test func readsTheProfilesPushEnvironment() {
        #expect(PushEnvironment.environment(inProfile: profile("development")) == "development")
        #expect(PushEnvironment.environment(inProfile: profile("production")) == "production")
    }
}
