# Credential CLI: verification

Written by AI on 2026-09-17 by model gpt-6-astra.

The CLI was verified in isolation before approval, then through the installed
signed app after rollout was authorized.

The CLI acquires one field into a private named macOS pasteboard, reads it
without consuming it, and explicitly clears it. Browser operations remain with
the model and its current tools. The shipped skill contains instructions only.

Verified before rollout:

- All 63 Swift tests passed.
- A sandboxed synthetic producer used the production resolver and authorization
  path. The production CLI read the resulting reference twice, encountered a
  broken output pipe, read it again, cleared it, then failed to read it. Ask
  invoked authorization once; automatic invoked none; blocked and denied
  requests released nothing. Run `script/verify_credential_retention.sh` to
  reproduce this proof.
- In the actual Codex browser, the model acquired a synthetic password once,
  attempted entry into a missing input, read the same reference again with the
  production CLI, and successfully submitted the password. Explicit clear
  removed the value; a subsequent read failed with empty stdout.
- A separate acquired TOTP code completed the login and was explicitly cleared.
  The server accepted the password and code and displayed the authenticated
  account. No Keyring browser module was involved.
- Generated-secret scans found no matches in the task transcript, 27 local
  Codex logs or the audit record, including the failed browser operation.

Those isolated checks used a synthetic store and authorizer.

Verified through the installed version 0.2.2:

- The app, helper and extension signatures, signing identity, bundle identifiers
  and entitlements matched the previous installation. The bundled skill matched
  source. No browser modules were bundled.
- The built-in example account completed one username acquisition and one
  password acquisition through the installed app. The password used the default
  Ask rule and completed native authorization. Each reference supported repeated
  reads and another read after a broken output pipe. Explicit clear succeeded,
  repeated clear succeeded, and reading after clear failed with empty stdout.
- The existing encrypted mirror remained byte-for-byte unchanged. There was no
  saved access-policy file before or after the checks; default Ask remained in
  effect. No real password was requested.
- The previous app and pre-existing local skill edits were preserved for
  rollback. This was a local signed installation, without notarization or a
  public binary release.

Retained values have no automatic expiry; the model must clear them on
completion or abandonment.
