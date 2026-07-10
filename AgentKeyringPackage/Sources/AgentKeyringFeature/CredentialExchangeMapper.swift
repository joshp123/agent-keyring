import AuthenticationServices
import Foundation

@available(macOS 26.0, *)
public struct CredentialExchangeMapper: Sendable {
    public init() {}

    public func map(
        _ exportedData: ASExportedCredentialData,
        scope: MirrorImportScope = .full
    ) -> MirrorImportBatch {
        var items: [MirrorItem] = []
        var skippedPasskeyCount = 0
        var missingPasswordCount = 0
        var otherSkippedCredentialCount = 0

        for account in exportedData.accounts {
            for item in account.items {
                var mappedCredentials: [MirrorCredential] = []

                for credential in item.credentials {
                    switch credential {
                    case let .basicAuthentication(authentication):
                        guard let password = authentication.password?.value else {
                            missingPasswordCount += 1
                            continue
                        }
                        mappedCredentials.append(
                            .password(
                                userName: authentication.userName?.value,
                                password: password
                            )
                        )
                    case let .totp(totp):
                        mappedCredentials.append(
                            .totp(
                                secret: totp.secret,
                                period: totp.period,
                                digits: totp.digits,
                                userName: totp.userName,
                                algorithm: map(totp.algorithm),
                                issuer: totp.issuer
                            )
                        )
                    case .passkey:
                        skippedPasskeyCount += 1
                    default:
                        otherSkippedCredentialCount += 1
                    }
                }

                guard !mappedCredentials.isEmpty else { continue }
                items.append(
                    MirrorItem(
                        id: UUID(),
                        sourceIdentity: MirrorSourceIdentity(
                            exporterIdentifier: exportedData.exporterRelyingPartyIdentifier,
                            accountID: account.id,
                            itemID: item.id
                        ),
                        createdAt: item.created,
                        lastModifiedAt: item.lastModified,
                        title: item.title,
                        subtitle: item.subtitle,
                        isFavorite: item.favorite,
                        origins: item.scope?.urls.map(\.absoluteString) ?? [],
                        credentials: mappedCredentials
                    )
                )
            }
        }

        let skippedSummary = MirrorSkippedCredentialSummary(
            passkeyCount: skippedPasskeyCount,
            missingPasswordCount: missingPasswordCount,
            otherCount: otherSkippedCredentialCount
        )

        return MirrorImportBatch(
            scope: scope,
            exportedAt: exportedData.timestamp,
            exporterIdentifier: exportedData.exporterRelyingPartyIdentifier,
            exporterDisplayName: exportedData.exporterDisplayName,
            items: items,
            skippedCredentialCount: skippedSummary.totalCount,
            skippedCredentialSummary: skippedSummary
        )
    }

    private func map(
        _ algorithm: ASImportableCredential.TOTP.Algorithm
    ) -> MirrorTOTPAlgorithm {
        switch algorithm {
        case .sha1:
            .sha1
        case .sha256:
            .sha256
        case .sha512:
            .sha512
        @unknown default:
            .sha1
        }
    }
}
