Written by AI on 2026.11.19 by model claude opus 5.5.

# Test Exporter

A small Mac app that stands in for Apple's Passwords app when rehearsing
Agent Keyring's first run. It holds three made-up logins and, when its button
is clicked, exports them through Apple's credential exchange
(`ASCredentialExportManager`), so Apple's own picker appears and Agent Keyring
can be chosen in it. Nobody's real passwords are involved.

- Example Mail: one site, a password.
- Example Shop: two sites (`shop.example.com`, `checkout.example.com`).
- Example Bank: a password and a one-time code. Its secret is RFC 6238's test
  secret, so the expected code is `oathtool --totp -b GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ`.

## What an exporter must declare

Apple's `ASCredentialExportManager` documentation: the app's credential
provider extension declares `SupportsCredentialExchange` (YES) and
`SupportedCredentialExchangeVersions` (`["1.0"]`) under
`NSExtension > NSExtensionAttributes > ASCredentialProviderExtensionCapabilities`.
With exactly one such extension, `requestExport(for: nil)` exports on its
behalf. `ASCredentialProviderViewController`'s documentation asks for the
AutoFill Credential Provider entitlement on the app and the extension. Because
of its extension, this app is also offered as an import destination.

## Building

The bundle identifiers are `<prefix>.AgentKeyring.TestExporter` and
`<prefix>.AgentKeyring.TestExporter.CredentialProvider`, from
`Config/Local.xcconfig`. Archive the `TestExporter` scheme with
`-allowProvisioningUpdates` and the App Store Connect API key, then export it
as `developer-id` with two Developer ID (`MAC_APP_DIRECT`) profiles: "Agent
Keyring Test Exporter Developer ID" and "Agent Keyring Test Exporter Provider
Developer ID". An API key cannot make Developer ID profiles through Xcode, so
these were made with the App Store Connect API.
