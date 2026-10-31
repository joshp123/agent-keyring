import AgentKeyringProtocol
import AgentKeyringRelaySupport
import CryptoKit
import Foundation
import LocalAuthentication

struct PhoneSavedCopy: Codable {
    var signedUpdate: Data?
    let revision: UInt64
    let updateDigest: Data
}

extension PhoneRelayApprover {
    func verifiedCopy(_ signed: Agentkeyring_V1_SignedCopyUpdate) throws -> Agentkeyring_V1_CopyUpdate {
        let set = try parsedKeys(currentKeys())
        guard let signer = set.keys.first(where: { $0.keyID == signed.signerKeyID && $0.role == .macDelivery }),
              try RelayCrypto.verify(signature: signed.signature, statement: signed.update, publicKey: signer.publicKey) else {
            throw RelayFailure(.permissionDenied, "The login copy lacks a current Mac delivery signature.")
        }
        let publicKey = try keys.encryptionPublicKey()
        guard set.keys.contains(where: { $0.role == .phone && $0.publicKey == (try? keys.signingPublicKey()) && $0.encryptionPublicKey == publicKey }) else {
            throw RelayFailure(.permissionDenied, "This iPhone's copy key has not been paired.")
        }
        let destination = RelayCrypto.keyID(publicKey)
        let update = try Agentkeyring_V1_CopyUpdate(serializedBytes: signed.update)
        let configuration = try configuration()
        guard update.domain == "agentkeyring.copy-update.v1", update.destinationKeyID == destination,
              update.configurationRevision == configuration.revision, update.revision > 0,
              Set(update.logins.map(\.loginID)).count == update.logins.count else {
            throw RelayFailure(.permissionDenied, "The login copy has the wrong destination, configuration or revision.")
        }
        for login in update.logins {
            guard configuration.logins.contains(where: { $0.loginID == login.loginID && $0.rule == .ask }),
                  login.hasSealed, login.sealed.receiverKeyID == destination,
                  !login.sealed.ciphertext.isEmpty else {
                throw RelayFailure(.permissionDenied, "The login copy includes a login this iPhone may not hold.")
            }
            _ = try P256.KeyAgreement.PublicKey(x963Representation: login.sealed.encapsulatedKey)
        }
        return update
    }

    func receiveCopy(_ signed: Agentkeyring_V1_SignedCopyUpdate) throws {
        let update = try verifiedCopy(signed)
        let digest = RelayCrypto.hash(signed.update)
        if let previous = state.copy {
            guard update.revision >= previous.revision,
                  update.revision != previous.revision || digest == previous.updateDigest else {
                throw RelayFailure(.permissionDenied, "The login copy rolled back or changed at the same revision.")
            }
        }
        var next = state
        next.copy = PhoneSavedCopy(signedUpdate: try signed.serializedData(), revision: update.revision, updateDigest: digest)
        try commit(next)
        logger.notice("Accepted sealed Ask copy; revision=\(update.revision, privacy: .public) logins=\(update.logins.count, privacy: .public)")
    }

    func refreshCopy() async {
        do {
            let set = try parsedKeys(currentKeys())
            let ownKey = try keys.signingPublicKey()
            guard set.keys.contains(where: { $0.publicKey == ownKey && !$0.encryptionPublicKey.isEmpty }) else { return }
            var request = Agentkeyring_V1_RelayWireRequest(); request.getCopyUpdate = .init()
            let response = try await transport().call(request)
            guard case let .copyUpdate(update) = response.response else { throw RelayFailure(.unavailable, "The relay sent no login copy.") }
            try receiveCopy(update)
        } catch {
            // Copy sync must never hide approval-only requests. Do not use an
            // unconfirmed copy after a failed refresh, but retain its revision floor.
            var next = state; next.copy?.signedUpdate = nil
            do { try commit(next) } catch { fail(error, stage: "Save unavailable copy") }
            if (error as? RelayFailure)?.code != .notFound { fail(error, stage: "Refresh login copy") }
        }
    }

    func currentCopy(_ loginID: String) throws -> (Agentkeyring_V1_CopyUpdate, Agentkeyring_V1_SealedAutomaticLogin)? {
        guard let bytes = state.copy?.signedUpdate else { return nil }
        let signed = try Agentkeyring_V1_SignedCopyUpdate(serializedBytes: bytes)
        let update = try verifiedCopy(signed)
        return update.logins.first(where: { $0.loginID == loginID }).map { (update, $0) }
    }

    func openCopy(_ copy: (Agentkeyring_V1_CopyUpdate, Agentkeyring_V1_SealedAutomaticLogin),
                  login: Agentkeyring_V1_Login, context: LAContext) throws -> Agentkeyring_V1_AutomaticLoginContents {
        let (update, sealed) = copy
        let associatedData = RelayCrypto.loginCopyAssociatedData(destination: update.destinationKeyID,
            configurationRevision: update.configurationRevision, revision: update.revision, loginID: login.loginID)
        var plaintext = try keys.openCopy(encapsulatedKey: sealed.sealed.encapsulatedKey,
                                         ciphertext: sealed.sealed.ciphertext, associatedData: associatedData, context: context)
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        let contents = try Agentkeyring_V1_AutomaticLoginContents(serializedBytes: plaintext)
        guard contents.loginID == login.loginID, contents.sites.sorted() == login.sites.sorted(),
              login.hasOneTimeCode_p == !contents.totpSeed.isEmpty else {
            throw RelayFailure(.permissionDenied, "The opened login copy does not match the current login and saved sites.")
        }
        return contents
    }
}
