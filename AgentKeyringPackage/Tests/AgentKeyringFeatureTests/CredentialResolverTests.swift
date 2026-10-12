import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Agent credential resolution")
struct CredentialResolverTests {
    private let resolver = CredentialResolver()

    @Test("Exact, www and one-label subdomain matches are supported")
    func hostMatching() throws {
        let snapshot = generation(items: [
            item(title: "Example", origin: "https://example.com", username: "agent@example.com")
        ])

        #expect(
            try resolver.candidates(in: snapshot, targetURL: "https://example.com/login").count == 1
        )
        #expect(
            try resolver.candidates(in: snapshot, targetURL: "https://www.example.com/login").count
                == 1)
        #expect(
            try resolver.candidates(in: snapshot, targetURL: "https://accounts.example.com/login")
                .count == 1)
        #expect(
            try resolver.candidates(in: snapshot, targetURL: "https://example.com.evil.test/login")
                .isEmpty)
    }

    @Test("A non-default port never matches a default-port page")
    func portBoundary() throws {
        let snapshot = generation(items: [
            item(title: "Admin", origin: "https://example.com:8443", username: "admin")
        ])

        #expect(
            try resolver.candidates(in: snapshot, targetURL: "https://example.com/login").isEmpty)
        #expect(
            try resolver.candidates(in: snapshot, targetURL: "https://example.com:8443/login").count
                == 1)
    }

    @Test("An exact origin outranks a parent-domain match")
    func exactOriginWins() throws {
        let exact = item(title: "Exact", origin: "https://accounts.example.com", username: "exact")
        let parent = item(title: "Parent", origin: "https://example.com", username: "parent")
        let snapshot = generation(items: [parent, exact])

        let candidates = try resolver.candidates(
            in: snapshot,
            targetURL: "https://accounts.example.com/login"
        )

        #expect(candidates.map(\.id) == [exact.id])
    }

    @Test("Ambiguous accounts fail closed until narrowed")
    func ambiguityAndNarrowing() throws {
        let first = item(
            title: "Example", origin: "https://example.com", username: "first@example.com")
        let second = item(
            title: "Example", origin: "https://example.com", username: "second@example.com")
        let snapshot = generation(items: [first, second])

        #expect(throws: CredentialResolverError.ambiguous) {
            try resolver.secret(
                in: snapshot,
                targetURL: "https://example.com/login",
                field: .password
            )
        }
        #expect(
            try resolver.secret(
                in: snapshot,
                targetURL: "https://example.com/login",
                usernameHint: "SECOND@example.com",
                field: .password
            ) == "CANARY-second@example.com"
        )
    }

    @Test("Secrets are refused for plain HTTP")
    func insecureOrigin() throws {
        let snapshot = generation(items: [
            item(title: "Example", origin: "https://example.com", username: "agent@example.com")
        ])

        #expect(throws: CredentialResolverError.insecureOrigin) {
            try resolver.validateSecureTarget("http://example.com/login")
        }
        #expect(throws: CredentialResolverError.insecureOrigin) {
            try resolver.secret(
                in: snapshot,
                targetURL: "http://example.com/login",
                field: .password
            )
        }
    }

    @Test("Safe candidates never encode password or TOTP material")
    func candidatesDoNotLeakSecrets() throws {
        let snapshot = generation(items: [
            item(
                title: "Example",
                origin: "https://example.com",
                username: "agent@example.com",
                includeTOTP: true
            )
        ])
        let candidates = try resolver.candidates(
            in: snapshot,
            targetURL: "https://example.com"
        )
        let encoded = String(decoding: try JSONEncoder().encode(candidates), as: UTF8.self)

        #expect(!encoded.contains("CANARY-agent@example.com"))
        #expect(!encoded.contains("totp-secret-canary"))
    }

    @Test("Account filtering precedes host ranking")
    func accountBeforeRanking() throws {
        let parent = item(title: "Parent", origin: "https://example.com", username: "B")
        let exact = item(title: "Exact", origin: "https://accounts.example.com", username: "A")
        #expect(try resolver.candidates(in: generation(items: [exact, parent]),
            targetURL: "https://accounts.example.com", usernameHint: "b").map(\.id) == [parent.id])
    }

    @Test("Default HTTP logins match HTTPS sign-in pages")
    func httpUpgrade() throws {
        let snapshot = generation(items: [item(title: "Example", origin: "http://example.com:80", username: "A")])
        #expect(try resolver.secret(in: snapshot, targetURL: "https://example.com:443/login", field: .password) == "CANARY-A")
        #expect(try resolver.candidates(in: snapshot, targetURL: "https://example.com:8443").isEmpty)
    }

    @Test("Child hosts cannot cross public suffixes", arguments: ["github.io", "vercel.app", "co.uk", "foo.ck", "公司.cn"])
    func publicSuffixBoundary(suffix: String) throws {
        let snapshot = generation(items: [item(title: "Shared host", origin: "https://\(suffix)", username: "A")])
        #expect(try resolver.candidates(in: snapshot, targetURL: "https://tenant.\(suffix)").isEmpty)
        #expect(try resolver.candidates(in: snapshot, targetURL: "https://www.\(suffix)").isEmpty)
    }

    @Test("PSL exceptions and tenant child domains remain usable")
    func suffixExceptions() throws {
        for host in ["www.ck", "tenant.github.io", "tenant.vercel.app"] {
            let snapshot = generation(items: [item(title: "Tenant", origin: "https://\(host)", username: "A")])
            #expect(try resolver.candidates(in: snapshot, targetURL: "https://login.\(host)").count == 1)
        }
        let snapshot = generation(items: [item(title: "Child", origin: "https://login.example.com", username: "A")])
        #expect(try resolver.candidates(in: snapshot, targetURL: "https://example.com").count == 1)
    }

    @Test("Code-only logins expose and resolve their account name")
    func codeOnlyAccount() throws {
        let login = MirrorItem(id: UUID(), sourceIdentity: MirrorSourceIdentity(
            exporterIdentifier: "fixture", accountID: Data(), itemID: Data()),
            title: "Code", origins: ["https://example.com"], credentials: [
                .totp(secret: Data("12345678901234567890".utf8), period: 30, digits: 6,
                    userName: "code-account", algorithm: .sha1, issuer: nil)])
        let snapshot = generation(items: [login])
        let candidates = try resolver.candidates(in: snapshot, targetURL: "https://example.com", usernameHint: "CODE-ACCOUNT")
        #expect(candidates.first?.username == "code-account")
        #expect(candidates.first?.availableFields == [.username, .totp])
        #expect(try resolver.secret(in: snapshot, targetURL: "https://example.com", usernameHint: "code-account", field: .username) == "code-account")
    }

    private func generation(items: [MirrorItem]) -> MirrorGeneration {
        MirrorGeneration(
            id: UUID(),
            previousGenerationID: nil,
            createdAt: Date(timeIntervalSince1970: 2_000),
            sourceExportedAt: Date(timeIntervalSince1970: 1_900),
            scope: .full,
            exporterIdentifier: "com.apple.Passwords",
            exporterDisplayName: "Passwords",
            items: items,
            delta: MirrorDelta(),
            skippedCredentialCount: 0
        )
    }

    private func item(
        title: String,
        origin: String,
        username: String,
        includeTOTP: Bool = false
    ) -> MirrorItem {
        var credentials: [MirrorCredential] = [
            .password(userName: username, password: "CANARY-\(username)")
        ]
        if includeTOTP {
            credentials.append(
                .totp(
                    secret: Data("totp-secret-canary".utf8),
                    period: 30,
                    digits: 6,
                    userName: username,
                    algorithm: .sha1,
                    issuer: title
                )
            )
        }
        return MirrorItem(
            id: UUID(),
            sourceIdentity: MirrorSourceIdentity(
                exporterIdentifier: "com.apple.Passwords",
                accountID: Data(username.utf8),
                itemID: Data(origin.utf8)
            ),
            title: title,
            origins: [origin],
            credentials: credentials
        )
    }
}
