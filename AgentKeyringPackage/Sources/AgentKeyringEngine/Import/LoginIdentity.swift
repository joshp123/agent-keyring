// Written by AI on 2026.11.23 by model claude opus 5.5.
//
// A login's ID, worked out from what it is, so every device that exports the
// same login from Passwords gives it the same ID: Passwords gives every item
// a new random ID on each export, on the Mac and on the iPhone alike, but
// keeps when it was made to the microsecond on both. That time tells apart
// two logins with the same site and account name; two items with the same
// site, account name and time are one login. Items with no time (made by hand)
// and the same site, account name and title are as many logins as the export
// lists: an export never loses one of two passwords.

import CryptoKit
import Foundation

public enum LoginIdentity {
    /// The ID of each item, in order: the same login gets the same ID on every device and every export. A new
    /// password or one-time code keeps it, and so does a new title when Passwords gives the creation time.
    /// Undated items with one key are told apart by their other details, then by their place in the export,
    /// never by a secret, so the list saved without secrets gives the same IDs.
    public static func ids(for items: [StoredVaultLogin]) -> [UUID] {
        let keys = items.map(key)
        var ids = keys.map(uuid)
        var undated: [String: [Int]] = [:]
        for (index, item) in items.enumerated() where item.createdAt == nil { undated[keys[index], default: []].append(index) }
        for (key, indices) in undated where indices.count > 1 {
            let ordered = indices.sorted { (tieBreak(items[$0]), $0) < (tieBreak(items[$1]), $1) }
            for (position, index) in ordered.enumerated() where position > 0 {
                ids[index] = uuid(key + "\u{0}#\(position + 1)")
            }
        }
        return ids
    }

    /// Of two exported items with one key (one login exported twice), the one that stands: the one changed
    /// last, and of two changed at once, the same one on every device whatever order the export lists them in.
    static func isNewerCopy(_ item: StoredVaultLogin, than other: StoredVaultLogin) -> Bool {
        (item.lastModifiedAt ?? .distantPast, tieBreak(item)) > (other.lastModifiedAt ?? .distantPast, tieBreak(other))
    }

    /// "ak-login-v1:" site NUL account NUL created, before hashing. Created is
    /// in microseconds since 2001, as Passwords keeps it on every device: two
    /// logins made a millisecond apart are still two.
    public static func key(_ item: StoredVaultLogin) -> String {
        let created = item.createdAt.map { "\(Int64(($0.timeIntervalSinceReferenceDate * 1_000_000).rounded()))" }
            ?? "no-created:" + normalized(item.title)
        return "ak-login-v1:" + site(item) + "\u{0}" + account(item) + "\u{0}" + created
    }

    /// The lowest of its sites' hosts, lowercased and without "www."; its title when it has no site.
    static func site(_ item: StoredVaultLogin) -> String {
        let hosts = item.origins.map { origin -> String in
            var host = (URLComponents(string: origin)?.host ?? origin).lowercased()
            host = host.trimmingCharacters(in: .whitespaces)
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return host
        }.filter { !$0.isEmpty }
        return hosts.min() ?? normalized(item.title)
    }

    /// The lowest password account name, else the lowest one-time code account name, normalised; empty if none.
    static func account(_ item: StoredVaultLogin) -> String {
        var passwordNames: [String] = []
        var codeNames: [String] = []
        for credential in item.credentials {
            switch credential {
            case let .password(userName, _): passwordNames.append(normalized(userName ?? ""))
            case let .totp(_, _, _, userName, _, _): codeNames.append(normalized(userName ?? ""))
            }
        }
        return passwordNames.filter { !$0.isEmpty }.min() ?? codeNames.filter { !$0.isEmpty }.min() ?? ""
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func tieBreak(_ item: StoredVaultLogin) -> String {
        let accounts = item.credentials.map { credential -> String in
            switch credential {
            case let .password(userName, _): "p:" + (userName ?? "")
            case let .totp(_, _, _, userName, _, _): "t:" + (userName ?? "")
            }
        }.sorted()
        return ([item.title, item.subtitle ?? ""] + item.origins.sorted() + accounts
            + ["\(item.lastModifiedAt?.timeIntervalSince1970 ?? 0)"]).joined(separator: "\u{0}")
    }

    /// The first 16 bytes of SHA-256, shaped as a version 5 UUID so every
    /// device and the command read it as the IDs they always have.
    static func uuid(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
