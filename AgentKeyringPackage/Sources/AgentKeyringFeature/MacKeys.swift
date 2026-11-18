// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The Mac's keys (proto/agentkeyring/v2/keyring.proto, "Keys"). As an
// approving device it has a signing key and an opening key in the Secure
// Enclave, usable only after Touch ID or the Watch; a newly enrolled finger
// stops them working. Its reply key signs only denials with words and needs
// the Mac unlocked, nothing more. As the machine its own agents run on, it has
// a receiving key for its own Automatic logins. One TLS identity serves both
// on the connection to the relay. Everything is kept in the app's keychain.

import AgentKeyringProtocol
import AgentKeyringRelaySupport
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import Security

@MainActor
public final class MacKeys {
    private struct Saved: Codable {
        var signing: Data   // Secure Enclave key handles: usable only on this Mac, and only as their access control allows.
        var opening: Data
        var reply: Data
        var receiving: Data // Software key: the Mac as an Automatic machine.
    }

    private let saved: Saved
    public let tls: RelayTLSIdentity
    public let receiving: P256.KeyAgreement.PrivateKey
    public let signingPublicKey: P256.Signing.PublicKey
    public let openingPublicKey: P256.KeyAgreement.PublicKey
    public let replyPublicKey: P256.Signing.PublicKey

    public init(service: String = (Bundle.main.bundleIdentifier ?? "com.agentkeyring") + ".keys.v2") throws {
        let keychain = RelayKeychain(service: service)
        if let bytes = try keychain.read("keys") {
            saved = try PropertyListDecoder().decode(Saved.self, from: bytes)
        } else {
            let person = try Self.access([.privateKeyUsage, .biometryCurrentSet, .or, .companion])
            let unlocked = try Self.access([.privateKeyUsage])
            saved = Saved(signing: try SecureEnclave.P256.Signing.PrivateKey(accessControl: person).dataRepresentation,
                opening: try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: person).dataRepresentation,
                reply: try SecureEnclave.P256.Signing.PrivateKey(accessControl: unlocked).dataRepresentation,
                receiving: P256.KeyAgreement.PrivateKey().rawRepresentation)
            try keychain.write(PropertyListEncoder().encode(saved), account: "keys")
        }
        tls = try RelayTLSIdentity.loadOrCreate(service: service + ".tls")
        receiving = try P256.KeyAgreement.PrivateKey(rawRepresentation: saved.receiving)
        // Reading a Secure Enclave key's public half needs no approval.
        signingPublicKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved.signing).publicKey
        openingPublicKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: saved.opening).publicKey
        replyPublicKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved.reply).publicKey
    }

    private static func access(_ flags: SecAccessControlCreateFlags) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return control
    }

    public var deviceKeyID: String { Sealing.keyID(signingPublicKey.x963Representation) }
    public var machineID: String { Sealing.keyID(tls.publicKeySPKI) }

    public var device: Agentkeyring_V2_Device {
        var device = Agentkeyring_V2_Device()
        device.keyID = deviceKeyID
        device.kind = .mac
        device.label = Host.current().localizedName ?? "MacBook"
        device.signingPublicKey = signingPublicKey.x963Representation
        device.openingPublicKey = openingPublicKey.x963Representation
        device.tlsPublicKey = tls.publicKeySPKI
        device.replyPublicKey = replyPublicKey.x963Representation
        device.replyKeyID = Sealing.keyID(replyPublicKey.x963Representation)
        return device
    }

    /// The Mac as the machine its own agents run on. Its Automatic logins are
    /// sealed to its receiving key.
    public var machine: Agentkeyring_V2_Machine {
        var machine = Agentkeyring_V2_Machine()
        machine.machineID = machineID
        machine.label = Host.current().localizedName ?? "MacBook"
        machine.tlsPublicKey = tls.publicKeySPKI
        machine.receivingPublicKey = receiving.publicKey.x963Representation
        machine.automaticAllowed = true
        return machine
    }

    /// Signs with the Secure Enclave key, using a context Josh has just approved.
    public func sign(_ payload: Data, context: LAContext) throws -> Data {
        try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved.signing, authenticationContext: context)
            .signature(for: payload).derRepresentation
    }

    public func signReply(_ payload: Data) throws -> Data {
        try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved.reply).signature(for: payload).derRepresentation
    }

    public var replyKeyID: String { Sealing.keyID(replyPublicKey.x963Representation) }

    /// Opens a login sealed to this Mac, using a context Josh has just approved.
    public func open(_ sealed: Agentkeyring_V2_SealedLogin, context: LAContext) throws -> Agentkeyring_V2_LoginSecret {
        try Sealing.open(sealed, with: SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: saved.opening,
            authenticationContext: context))
    }
}
