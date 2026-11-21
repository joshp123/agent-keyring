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
import OSLog
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
    #if DEBUG
    /// Launched with -StandInKey YES: `saved` holds software keys.
    let standIn: Bool
    #endif
    public let tls: RelayTLSIdentity
    public let receiving: P256.KeyAgreement.PrivateKey
    public let signingPublicKey: P256.Signing.PublicKey
    public let openingPublicKey: P256.KeyAgreement.PublicKey
    public let replyPublicKey: P256.Signing.PublicKey

    public init(service: String = (Bundle.main.bundleIdentifier ?? "com.agentkeyring") + ".keys.v2") throws {
        label = Host.current().localizedName ?? "MacBook"
        #if DEBUG
        standIn = StandInKey.isOn
        if standIn {
            saved = try Self.standInKeys()
            tls = try RelayTLSIdentity.loadOrCreate(service: service + ".tls")
            receiving = try P256.KeyAgreement.PrivateKey(rawRepresentation: saved.receiving)
            signingPublicKey = try P256.Signing.PrivateKey(rawRepresentation: saved.signing).publicKey
            openingPublicKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: saved.opening).publicKey
            replyPublicKey = try P256.Signing.PrivateKey(rawRepresentation: saved.reply).publicKey
            Logger(subsystem: "com.agentkeyring.app", category: "Keys").notice(
                "Stand-in key in use: software keys in the app's container replace the Secure Enclave, and Touch ID answers at once.")
            return
        }
        #endif
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

    #if DEBUG
    /// Software keys in a file in the app's container, never in the keychain,
    /// so a normal launch on the same Mac still finds only chip keys there.
    private static func standInKeys() throws -> Saved {
        let file = URL.applicationSupportDirectory.appending(path: "AgentKeyring/stand-in-keys.plist")
        if FileManager.default.fileExists(atPath: file.path) {
            return try PropertyListDecoder().decode(Saved.self, from: Data(contentsOf: file))
        }
        let keys = Saved(signing: P256.Signing.PrivateKey().rawRepresentation, opening: P256.KeyAgreement.PrivateKey().rawRepresentation,
            reply: P256.Signing.PrivateKey().rawRepresentation, receiving: P256.KeyAgreement.PrivateKey().rawRepresentation)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListEncoder().encode(keys).write(to: file, options: .atomic)
        return keys
    }
    #endif

    private static func access(_ flags: SecAccessControlCreateFlags) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return control
    }

    #if DEBUG
    /// Software keys and a TLS identity held only in memory, for tests: nothing
    /// touches the keychain or the disk, and Touch ID answers at once.
    init(testing tls: RelayTLSIdentity, label: String) {
        standIn = true
        saved = Saved(signing: P256.Signing.PrivateKey().rawRepresentation, opening: P256.KeyAgreement.PrivateKey().rawRepresentation,
            reply: P256.Signing.PrivateKey().rawRepresentation, receiving: P256.KeyAgreement.PrivateKey().rawRepresentation)
        self.tls = tls
        self.label = label
        receiving = try! P256.KeyAgreement.PrivateKey(rawRepresentation: saved.receiving)
        signingPublicKey = try! P256.Signing.PrivateKey(rawRepresentation: saved.signing).publicKey
        openingPublicKey = try! P256.KeyAgreement.PrivateKey(rawRepresentation: saved.opening).publicKey
        replyPublicKey = try! P256.Signing.PrivateKey(rawRepresentation: saved.reply).publicKey
    }
    #endif

    /// This Mac as he named it, which every device shows.
    public let label: String

    public var deviceKeyID: String { Sealing.keyID(signingPublicKey.x963Representation) }
    public var machineID: String { Sealing.keyID(tls.publicKeySPKI) }

    public var device: Agentkeyring_V2_Device {
        var device = Agentkeyring_V2_Device()
        device.keyID = deviceKeyID
        device.kind = .mac
        device.label = label
        device.signingPublicKey = signingPublicKey.x963Representation
        device.openingPublicKey = openingPublicKey.x963Representation
        device.tlsPublicKey = tls.publicKeySPKI
        device.replyPublicKey = replyPublicKey.x963Representation
        device.replyKeyID = Sealing.keyID(replyPublicKey.x963Representation)
        return device
    }

    /// The Mac as the computer its own agents run on. Its Automatic passwords
    /// are sealed to its receiving key, once Josh allows this Mac them.
    public var machine: Agentkeyring_V2_Machine {
        var machine = Agentkeyring_V2_Machine()
        machine.machineID = machineID
        machine.label = label
        machine.tlsPublicKey = tls.publicKeySPKI
        machine.receivingPublicKey = receiving.publicKey.x963Representation
        return machine
    }

    /// Signs with the Secure Enclave key, using a context Josh has just approved.
    public func sign(_ payload: Data, context: LAContext) throws -> Data {
        #if DEBUG
        if standIn { return try P256.Signing.PrivateKey(rawRepresentation: saved.signing).signature(for: payload).derRepresentation }
        #endif
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved.signing, authenticationContext: context)
            .signature(for: payload).derRepresentation
    }

    public func signReply(_ payload: Data) throws -> Data {
        #if DEBUG
        if standIn { return try P256.Signing.PrivateKey(rawRepresentation: saved.reply).signature(for: payload).derRepresentation }
        #endif
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved.reply).signature(for: payload).derRepresentation
    }

    public var replyKeyID: String { Sealing.keyID(replyPublicKey.x963Representation) }

    /// What this Mac signs its sealed copies with: its reply key, which needs no Touch ID.
    public var signer: Sealing.Signer { Sealing.Signer(keyID: replyKeyID, sign: signReply) }

    /// A sealed copy only if this Mac or a device in `members` signed it: files
    /// on disk and the relay are not trusted to say which copy is which. A copy
    /// from the relay is also checked against the signed catalogue's `listed` login.
    public func check(_ sealed: Agentkeyring_V2_SealedLogin, members: Agentkeyring_V2_Members?, listed: Agentkeyring_V2_Login? = nil) throws {
        if let listed, listed.loginID != sealed.loginID || listed.version != sealed.version { throw Sealing.Failure.wrongLogin }
        if sealed.signerKeyID == replyKeyID {
            try Sealing.checkSealed(sealed, by: replyKeyID, publicKey: replyPublicKey)
        } else if let members {
            try Sealing.checkSealed(sealed, members: members, listed: listed)
        } else {
            throw Sealing.Failure.unknownSigner
        }
    }

    /// Seals this Mac's copies again for a new device, away from the main
    /// thread, with the chip's keys made once for the whole batch.
    public func resealer(context: LAContext, members: Agentkeyring_V2_Members) throws -> Resealer {
        #if DEBUG
        if standIn {
            let opening = try P256.KeyAgreement.PrivateKey(rawRepresentation: saved.opening)
            let reply = try P256.Signing.PrivateKey(rawRepresentation: saved.reply)
            return Resealer(open: { try Sealing.open($0, with: opening) }, sign: { try reply.signature(for: $0).derRepresentation },
                replyKeyID: replyKeyID, replyPublicKey: replyPublicKey, members: members)
        }
        #endif
        let opening = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: saved.opening, authenticationContext: context)
        let reply = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved.reply)
        return Resealer(open: { try Sealing.open($0, with: opening) }, sign: { try reply.signature(for: $0).derRepresentation },
            replyKeyID: replyKeyID, replyPublicKey: replyPublicKey, members: members)
    }

    /// Opens a login sealed to this Mac, using a context Josh has just approved.
    public func open(_ sealed: Agentkeyring_V2_SealedLogin, context: LAContext) throws -> Agentkeyring_V2_LoginSecret {
        #if DEBUG
        if standIn { return try Sealing.open(sealed, with: P256.KeyAgreement.PrivateKey(rawRepresentation: saved.opening)) }
        #endif
        return try Sealing.open(sealed, with: SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: saved.opening,
            authenticationContext: context))
    }
}

/// One Touch ID's worth of re-sealing, safe to run off the main thread.
public struct Resealer: @unchecked Sendable {
    let open: (Agentkeyring_V2_SealedLogin) throws -> Agentkeyring_V2_LoginSecret
    let sign: (Data) throws -> Data
    let replyKeyID: String
    let replyPublicKey: P256.Signing.PublicKey
    let members: Agentkeyring_V2_Members

    /// This Mac's copy, checked, opened and sealed again to `key` for `openerID`.
    public func reseal(_ copy: Agentkeyring_V2_SealedLogin, to key: P256.KeyAgreement.PublicKey, openerID: String) throws -> Agentkeyring_V2_SealedLogin {
        if copy.signerKeyID == replyKeyID { try Sealing.checkSealed(copy, by: replyKeyID, publicKey: replyPublicKey) }
        else { try Sealing.checkSealed(copy, members: members, listed: nil) }
        return try Sealing.seal(try open(copy), version: copy.version, to: key, openerID: openerID,
            signer: Sealing.Signer(keyID: replyKeyID, sign: sign))
    }
}
