// Written by AI on 2026.11.18 by model claude opus 5.5; protobuf storage on 2026.11.27 by model claude opus 5.5.
//
// The Mac's keys (proto/agentkeyring/v2/keyring.proto, "Keys"). As an
// approving device it has a signing key and an opening key in the Secure
// Enclave, usable only after Touch ID or the Watch (a newly enrolled finger
// stops them working), or, on a Mac without Touch ID that opted in, after the
// Mac's password. The mode is saved with the keys and never changes. Its reply key signs only denials with words and needs
// the Mac unlocked, nothing more. As the machine its own agents run on, it has
// a receiving key for its own Automatic logins. One TLS identity serves both
// on the connection to the relay. Everything is kept in the app's keychain, as
// `StoredMacKeys`.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import OSLog
import Security

public enum MacKeysError: Error, LocalizedError {
    /// Keys are already saved: a vault's keys and their access control never change.
    case alreadyMade
    /// No keys yet, and this Mac makes them only after Josh chooses how he uses it.
    case notMade

    public var errorDescription: String? {
        switch self {
        case .alreadyMade: "This Mac already has its keys."
        case .notMade: MessageCopy.noKeysYet
        }
    }
}

@MainActor
public final class MacKeys {
    struct Saved {
        var signing: Data   // Secure Enclave key handles: usable only on this Mac, and only as their access control allows.
        var opening: Data
        var reply: Data
        var receiving: Data // Software key: the Mac as an Automatic machine.
        /// With software keys, the notice key is kept with them, so encrypted iCloud records open after a restart.
        var notice: Data?
        var mode: MacApprovalMode

        init(signing: Data, opening: Data, reply: Data, receiving: Data, notice: Data? = nil, mode: MacApprovalMode) {
            self.signing = signing; self.opening = opening; self.reply = reply; self.receiving = receiving
            self.notice = notice; self.mode = mode
        }

        /// Leads every saved StoredMacKeys, so anything else under the service reads as corrupt, never as keys.
        static let magic = Data("AKRKEY02".utf8)

        init(stored bytes: Data) throws {
            guard bytes.starts(with: Self.magic) else { throw CocoaError(.fileReadCorruptFile) }
            let proto = try Agentkeyring_V2_StoredMacKeys(serializedBytes: Data(bytes.dropFirst(Self.magic.count)))
            let mode: MacApprovalMode
            switch proto.approvalMode {
            case .biometricOrCompanion: mode = .biometricOrCompanion
            case .devicePassword: mode = .devicePassword
            case .unspecified, .UNRECOGNIZED: throw CocoaError(.fileReadCorruptFile)
            }
            self.init(signing: proto.signing, opening: proto.opening, reply: proto.reply, receiving: proto.receiving,
                      notice: proto.notice.isEmpty ? nil : proto.notice, mode: mode)
        }

        func stored() throws -> Data {
            var proto = Agentkeyring_V2_StoredMacKeys()
            proto.signing = signing
            proto.opening = opening
            proto.reply = reply
            proto.receiving = receiving
            if let notice { proto.notice = notice }
            proto.approvalMode = switch mode {
            case .biometricOrCompanion: .biometricOrCompanion
            case .devicePassword: .devicePassword
            }
            return Self.magic + (try proto.serializedData())
        }
    }

    private let saved: Saved
    /// How Josh approves on this Mac, fixed when the keys were made.
    public let mode: MacApprovalMode
    #if DEBUG
    /// `saved` holds software keys, made for the test peer or a test: no Touch ID, and no Secure Enclave.
    let usesSoftwareKeys: Bool
    #endif
    public let tls: DeviceTLSIdentity
    public let receiving: P256.KeyAgreement.PrivateKey
    public let signingPublicKey: P256.Signing.PublicKey
    public let openingPublicKey: P256.KeyAgreement.PublicKey
    public let replyPublicKey: P256.Signing.PublicKey
    /// What pushes to this Mac are sealed to, so another computer can wake it: a software key in
    /// the app's keychain, opened without Touch ID. A notice only says that a request waits; it opens nothing.
    public let notice: P256.KeyAgreement.PrivateKey

    /// StoredMacKeys behind `Saved.magic`.
    public static let defaultService = (Bundle.main.bundleIdentifier ?? "com.agentkeyring") + ".keys.v3"

    /// This Mac's saved keys, or nil when none have been made yet.
    public static func loadMacKeys(service: String = defaultService) throws -> MacKeys? {
        let keychain = DeviceKeychainStore(service: service)
        guard let saved = try savedKeys(read: { try keychain.readKeychainItem("keys") },
                                        delete: { try keychain.deleteKeychainItem("keys") }) else { return nil }
        let keys = try MacKeys(saved: saved, tls: DeviceTLSIdentity.loadOrCreate(service: service + ".tls"), usesSoftwareKeys: false)
        MacApprovalMode.current = keys.mode
        return keys
    }

    /// The saved keys. A keychain that cannot be read throws. Keys this build cannot decode are logged and
    /// deleted, so setup makes new ones.
    static func savedKeys(read: () throws -> Data?, delete: () throws -> Void) throws -> Saved? {
        guard let bytes = try read() else { return nil }
        do { return try Saved(stored: bytes) } catch {
            KeyringDiagnosticLog.mac.noteDeviceEvent("keys", "undecodable, starting again", ["error": "\(error)"])
            try delete()
            return nil
        }
    }

    /// Makes and saves this Mac's keys for `mode`. Everything that can fail
    /// happens before anything is saved, and the save only ever adds: if keys
    /// are saved already (another launch got there first), nothing changes and
    /// it throws `alreadyMade`, so the caller loads the saved ones.
    public static func make(_ mode: MacApprovalMode, service: String = defaultService) throws -> MacKeys {
        let keychain = DeviceKeychainStore(service: service)
        guard try savedKeys(read: { try keychain.readKeychainItem("keys") },
                            delete: { try keychain.deleteKeychainItem("keys") }) == nil else { throw MacKeysError.alreadyMade }
        let tls = try DeviceTLSIdentity.loadOrCreate(service: service + ".tls")
        let person = try access(mode.keyFlags)
        let unlocked = try access([.privateKeyUsage])
        let saved = Saved(signing: try SecureEnclave.P256.Signing.PrivateKey(accessControl: person).dataRepresentation,
            opening: try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: person).dataRepresentation,
            reply: try SecureEnclave.P256.Signing.PrivateKey(accessControl: unlocked).dataRepresentation,
            receiving: P256.KeyAgreement.PrivateKey().rawRepresentation, mode: mode)
        // Reading the new keys back proves them before they are saved.
        let keys = try MacKeys(saved: saved, tls: tls, usesSoftwareKeys: false)
        guard try keychain.add(saved.stored(), account: "keys") else { throw MacKeysError.alreadyMade }
        MacApprovalMode.current = keys.mode
        return keys
    }

    #if DEBUG
    /// Software keys in a file, never in the keychain, so a normal launch on
    /// the same Mac still finds only chip keys there. Tests give their own file.
    package static func loadMacKeys(softwareKeyFile file: URL, tls: DeviceTLSIdentity) throws -> MacKeys? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try MacKeys(saved: Saved(stored: Data(contentsOf: file)), tls: tls, usesSoftwareKeys: true)
    }

    /// As `make`, adding only: a file already there is never replaced.
    package static func make(_ mode: MacApprovalMode, softwareKeyFile file: URL, tls: DeviceTLSIdentity) throws -> MacKeys {
        let saved = Saved(signing: P256.Signing.PrivateKey().rawRepresentation, opening: P256.KeyAgreement.PrivateKey().rawRepresentation,
            reply: P256.Signing.PrivateKey().rawRepresentation, receiving: P256.KeyAgreement.PrivateKey().rawRepresentation,
            notice: P256.KeyAgreement.PrivateKey().rawRepresentation, mode: mode)
        let keys = try MacKeys(saved: saved, tls: tls, usesSoftwareKeys: true)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try saved.stored().write(to: file, options: .withoutOverwriting) }
        catch CocoaError.fileWriteFileExists { throw MacKeysError.alreadyMade }
        return keys
    }
    #endif

    private init(saved: Saved, tls: DeviceTLSIdentity, usesSoftwareKeys: Bool) throws {
        label = Host.current().localizedName ?? "MacBook"
        self.saved = saved
        self.tls = tls
        mode = saved.mode
        #if DEBUG
        self.usesSoftwareKeys = usesSoftwareKeys
        #endif
        receiving = try P256.KeyAgreement.PrivateKey(rawRepresentation: saved.receiving)
        notice = usesSoftwareKeys
            ? (try saved.notice.map { try P256.KeyAgreement.PrivateKey(rawRepresentation: $0) } ?? P256.KeyAgreement.PrivateKey())
            : try Self.noticeKey(service: Self.defaultService)
        #if DEBUG
        if usesSoftwareKeys {
            signingPublicKey = try P256.Signing.PrivateKey(rawRepresentation: saved.signing).publicKey
            openingPublicKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: saved.opening).publicKey
            replyPublicKey = try P256.Signing.PrivateKey(rawRepresentation: saved.reply).publicKey
            Logger(subsystem: "com.agentkeyring.app", category: "Keys").notice(
                "Software keys in use: they replace the Secure Enclave, and approval answers at once.")
            return
        }
        #endif
        // Reading a Secure Enclave key's public half needs no approval.
        signingPublicKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved.signing).publicKey
        openingPublicKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: saved.opening).publicKey
        replyPublicKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved.reply).publicKey
    }

    private static func noticeKey(service: String) throws -> P256.KeyAgreement.PrivateKey {
        let keychain = DeviceKeychainStore(service: service)
        if let bytes = try keychain.readKeychainItem("notice") { return try P256.KeyAgreement.PrivateKey(rawRepresentation: bytes) }
        let made = P256.KeyAgreement.PrivateKey()
        if try keychain.add(made.rawRepresentation, account: "notice") { return made }
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: keychain.readKeychainItem("notice") ?? made.rawRepresentation)
    }

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
    init(testing tls: DeviceTLSIdentity, label: String, mode: MacApprovalMode = .biometricOrCompanion) {
        let signing = P256.Signing.PrivateKey()
        let opening = P256.KeyAgreement.PrivateKey()
        let reply = P256.Signing.PrivateKey()
        let receivingKey = P256.KeyAgreement.PrivateKey()
        usesSoftwareKeys = true
        saved = Saved(signing: signing.rawRepresentation, opening: opening.rawRepresentation,
            reply: reply.rawRepresentation, receiving: receivingKey.rawRepresentation, mode: mode)
        self.mode = mode
        self.tls = tls
        self.label = label
        receiving = receivingKey
        notice = P256.KeyAgreement.PrivateKey()
        signingPublicKey = signing.publicKey
        openingPublicKey = opening.publicKey
        replyPublicKey = reply.publicKey
    }
    #endif

    /// This Mac as he named it, which every device shows.
    public let label: String

    public var deviceKeyID: String { CredentialSealing.keyID(signingPublicKey.x963Representation) }
    public var machineID: String { CredentialSealing.keyID(tls.publicKeySPKI) }

    public var device: Agentkeyring_V2_Device {
        var device = Agentkeyring_V2_Device()
        device.keyID = deviceKeyID
        device.kind = .mac
        device.label = label
        device.signingPublicKey = signingPublicKey.x963Representation
        device.openingPublicKey = openingPublicKey.x963Representation
        device.tlsPublicKey = tls.publicKeySPKI
        device.replyPublicKey = replyPublicKey.x963Representation
        device.replyKeyID = CredentialSealing.keyID(replyPublicKey.x963Representation)
        device.noticePublicKey = notice.publicKey.x963Representation
        return device
    }

    /// Opens HPKE-wrapped content keys for encrypted iCloud metadata records without Touch ID.
    public var cloudKeyOpener: CloudEnvelope.KeyOpener {
        let key = notice
        return { try CloudEnvelope.hpkeOpen(encapsulatedKey: $0, ciphertext: $1, info: $2, authenticating: $3, with: key) }
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

    func confirmOwner(_ context: LAContext, reason: String, until deadline: Date) async throws {
        #if DEBUG
        if usesSoftwareKeys {
            try OwnerBiometricConfirmation.checkDeadline(deadline)
            return
        }
        #endif
        try await OwnerBiometricConfirmation.confirm(context, reason: reason, until: deadline)
    }

    /// Signs with the Secure Enclave key, using a context Josh has just approved.
    public func signWithDeviceKey(_ payload: Data, context: LAContext) throws -> Data {
        #if DEBUG
        if usesSoftwareKeys { return try P256.Signing.PrivateKey(rawRepresentation: saved.signing).signature(for: payload).derRepresentation }
        #endif
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved.signing, authenticationContext: context)
            .signature(for: payload).derRepresentation
    }

    public func signReply(_ payload: Data) throws -> Data {
        #if DEBUG
        if usesSoftwareKeys { return try P256.Signing.PrivateKey(rawRepresentation: saved.reply).signature(for: payload).derRepresentation }
        #endif
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved.reply).signature(for: payload).derRepresentation
    }

    public var replyKeyID: String { CredentialSealing.keyID(replyPublicKey.x963Representation) }

    /// What this Mac signs its sealed copies with: its reply key, which needs no Touch ID.
    public var signer: PayloadReplySigner { PayloadReplySigner(keyID: replyKeyID, sign: signReply) }

    /// A sealed copy only if this Mac or a device in `members` signed it: files
    /// on disk and the relay are not trusted to say which copy is which. A copy
    /// from the relay is also checked against the signed catalogue's `listed` login.
    public func check(_ sealed: Agentkeyring_V2_SealedLogin, members: Agentkeyring_V2_Members?, listed: Agentkeyring_V2_Login? = nil) throws {
        if let listed, listed.loginID != sealed.loginID || listed.version != sealed.version { throw CredentialSealingError.wrongLogin }
        if sealed.signerKeyID == replyKeyID {
            try CredentialSealing.verifySealedLogin(sealed, by: replyKeyID, publicKey: replyPublicKey)
        } else if let members {
            try CredentialSealing.verifySealedLogin(sealed, members: members, listed: listed)
        } else {
            throw CredentialSealingError.unknownSigner
        }
    }

    /// Seals this Mac's copies again for a new device, away from the main
    /// thread, with the chip's keys made once for the whole batch.
    func resealer(context: LAContext, members: Agentkeyring_V2_Members) throws -> TouchIDCopyResealer {
        #if DEBUG
        if usesSoftwareKeys {
            let opening = try P256.KeyAgreement.PrivateKey(rawRepresentation: saved.opening)
            let reply = try P256.Signing.PrivateKey(rawRepresentation: saved.reply)
            return TouchIDCopyResealer(open: { try CredentialSealing.openSealedLogin($0, with: opening) }, sign: { try reply.signature(for: $0).derRepresentation },
                replyKeyID: replyKeyID, replyPublicKey: replyPublicKey, members: members)
        }
        #endif
        let opening = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: saved.opening, authenticationContext: context)
        let reply = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: saved.reply)
        return TouchIDCopyResealer(open: { try CredentialSealing.openSealedLogin($0, with: opening) }, sign: { try reply.signature(for: $0).derRepresentation },
            replyKeyID: replyKeyID, replyPublicKey: replyPublicKey, members: members)
    }

    /// Opens a login sealed to this Mac, using a context Josh has just approved.
    public func openSealedLogin(_ sealed: Agentkeyring_V2_SealedLogin, context: LAContext) throws -> Agentkeyring_V2_LoginSecret {
        #if DEBUG
        if usesSoftwareKeys { return try CredentialSealing.openSealedLogin(sealed, with: P256.KeyAgreement.PrivateKey(rawRepresentation: saved.opening)) }
        #endif
        return try CredentialSealing.openSealedLogin(sealed, with: SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: saved.opening,
            authenticationContext: context))
    }
}

/// One Touch ID's worth of re-sealing, safe to run off the main thread.
struct TouchIDCopyResealer: @unchecked Sendable {
    let open: (Agentkeyring_V2_SealedLogin) throws -> Agentkeyring_V2_LoginSecret
    let sign: (Data) throws -> Data
    let replyKeyID: String
    let replyPublicKey: P256.Signing.PublicKey
    let members: Agentkeyring_V2_Members

    /// This Mac's copy, checked, opened and sealed again to `key` for `openerID`.
    func reseal(_ copy: Agentkeyring_V2_SealedLogin, to key: P256.KeyAgreement.PublicKey, openerID: String) throws -> Agentkeyring_V2_SealedLogin {
        if copy.signerKeyID == replyKeyID { try CredentialSealing.verifySealedLogin(copy, by: replyKeyID, publicKey: replyPublicKey) }
        else { try CredentialSealing.verifySealedLogin(copy, members: members, listed: nil) }
        return try CredentialSealing.sealLogin(try open(copy), version: copy.version, to: key, openerID: openerID,
            signer: PayloadReplySigner(keyID: replyKeyID, sign: sign))
    }
}
#endif
