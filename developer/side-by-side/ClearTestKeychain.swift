// Written by AI on 2026.11.01 by model gpt-6.1-sol.
// Test cleanup only. Run as the main executable of a profile-signed test bundle.
import Foundation
import Security

let testID = "com.joshpalmer.KeyringTest.AgentKeyring"
let testGroup = "7M8BR7R488." + testID
guard Bundle.main.bundleIdentifier == testID,
    CommandLine.arguments.dropFirst() == ["--clear-test-keychain"] else {
    fputs("This command clears only the isolated test identity.\n", stderr)
    exit(2)
}
for itemClass in [kSecClassGenericPassword, kSecClassKey] {
    let status = SecItemDelete([
        kSecClass as String: itemClass,
        kSecAttrAccessGroup as String: testGroup,
        kSecUseDataProtectionKeychain as String: true,
        kSecAttrSynchronizable as String: false,
    ] as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        fputs("Test Keychain cleanup failed (\(status)).\n", stderr)
        exit(1)
    }
}
let status = SecItemDelete([
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: testID + ".vault",
    kSecAttrAccount as String: "snapshot-key",
    kSecAttrSynchronizable as String: false,
] as CFDictionary)
guard status == errSecSuccess || status == errSecItemNotFound else {
    fputs("Test mirror key cleanup failed (\(status)).\n", stderr)
    exit(1)
}
print("Cleared only non-synchronizable keys in the isolated test group and its mirror-key service.")
