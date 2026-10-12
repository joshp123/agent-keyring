Written by AI (GPT-6, Codex, 2026-10-12). Decision spike; no production changes.

# Decision

Keep Agent Keyring sandboxed. Put the Accessibility inspection and synthetic
typing in one **embedded, unsandboxed XPC service**, running as the logged-in
user. This is the smallest change to the *current architecture*: it preserves
the vault, rules, request bridge, credential-provider extension and Sparkle
configuration. Apple explicitly supports this arrangement for directly
distributed apps.

Removing the main app's sandbox is a valid, simpler single-process alternative,
but it needs a coordinated storage/CLI transition and gives the entire app
cross-app control. There is no supported Accessibility entitlement that makes
the existing sandboxed process suitable for this flow.

**Verified here:** Developer ID signing, hardened runtime, a sandboxed host
successfully invoking an unsandboxed embedded XPC service, filesystem isolation,
AX error results without consent, and TCC attribution to the containing app.
**Not verified:** permission-granted AX inspection, browser addresses, secure
field roles, keyboard delivery, screen-unlock handling, or notarization of the
throwaway bundle. These require the next proof with Josh's Accessibility grant.

# Current architecture

Read from this checkout and checked against the installed app:

- `Config/AgentKeyring.entitlements`: App Sandbox, AutoFill credential-provider
  entitlement, and Sparkle's two Mach lookup exceptions.
- `Config/Shared.xcconfig`: `ENABLE_APP_SANDBOX = YES` and
  `ENABLE_HARDENED_RUNTIME = YES`.
- The credential-provider extension independently has both App Sandbox and
  AutoFill credential-provider entitlements. Its controller is an empty
  `ASCredentialProviderViewController` subclass. The main app handles import.
- `EncryptedSnapshotStore.defaultDirectoryURL()` and
  `CredentialAccessPolicyStore.defaultFileURL()` use Foundation's user
  Application Support directory.
- `AgentBridgeDirectory.defaultRootURL()` uses that directory in the app, but
  explicitly constructs `~/Library/Containers/<app-id>/Data/...` in the CLI.
  This is file-based IPC, not an existing XPC connection to repurpose.
- `KeychainVaultKeyProvider` uses `SecItemAdd`/`SecItemCopyMatching`, generic
  password service `<app-id>.vault`, account `snapshot-key`. It sets neither
  `kSecUseDataProtectionKeychain` nor `kSecAttrSynchronizable` nor an access
  group. Its current implementation therefore targets the file-based login
  keychain, with ACL-based access; it is not a key file inside the app container.
- The installed app already embeds Sparkle's `Installer.xpc` and
  `Downloader.xpc`. `codesign -d --entitlements :-` returned empty entitlement
  dictionaries for both. Thus unsandboxed embedded XPC is already part of the
  installed product's update architecture.

# Options

| Option | Change and cost | Decision |
| --- | --- | --- |
| (a) Unsandbox main app | Remove the sandbox entitlement **and** disable the main target's sandbox build setting. Keep Developer ID and hardened runtime. AX and posting still need user consent. Coordinate storage, CLI and update settings. | Valid alternative; fewest processes. |
| (b) Embedded unsandboxed XPC | One XPC target under `Contents/XPCServices`, one typed app-to-service interface. App retains vault and approvals; service receives the approved field value in memory and returns status. No daemon, root, login item or global Mach endpoint. | Recommended for the current product. |
| (c) Sandbox entitlement/exception | No supported entitlement enables the required cross-app AX flow. Apple Events and Input Monitoring have narrower, different capabilities. | Reject for this design. |

## (a) Removing the main app sandbox

**Storage:** Foundation will resolve Application Support to
`~/Library/Application Support` rather than
`~/Library/Containers/<app-id>/Data/Library/Application Support`. The existing
code would see an empty mirror and empty policies, while the CLI would continue
writing requests into the old container. Merely removing an entitlement is
therefore insufficient.

There are two ordinary choices: explicitly retain the old data root throughout
the app and CLI, or copy the persistent vault and policies to a new common root
and change both endpoints together. Do not replay old approval requests or
credential buffers. Foundation path resolution is verified below; an actual
upgrade/migration was not attempted. Existing files must be preserved until
the upgraded app can open its old mirror with the existing key. Also check
container-backed preferences such as Sparkle's update settings. macOS container
protection is separate from App Sandbox, so accessing the old directory should
be tested with the unchanged shipping identity rather than assuming that
turning off sandboxing grants universal file access.

**Keychain:** No keychain data move is inherently required. Preserve the bundle
identifier and signing identity/designated requirement, and the service/account
query. The normal Developer ID designated requirement does not include the
sandbox entitlement. Continued access to the existing key is expected from
the file-based ACL model, but not tested against Josh's real key. Do not create
a replacement vault key while treating a failed old-key read as missing data.
Apple explains the two keychain implementations and their access models in
[TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

**Extension:** Keep the extension sandboxed and retain its AutoFill entitlement,
signing and provisioning. A sandboxed extension inside an unsandboxed containing
app is supported; the app's sandbox setting is not inherited by the extension.
The import hand-off still needs a live regression check. Do not remove the
AutoFill entitlement from the main app as part of this change. Apple DTS
confirms this containing-app arrangement in
[this answer](https://developer.apple.com/forums/thread/776568).

**Sparkle:** Continue using Sparkle. Its documented unsandboxed configuration
removes `SUEnableDownloaderService`, `SUEnableInstallerLauncherService`, and
the `-spks`/`-spki` Mach lookup exceptions. Keep the feed, signature key and
Developer ID/notarization release flow. Removing the bundled Sparkle services
physically is optional; no framework repackaging is needed for the decision.
Source: [Sparkle sandboxing guide](https://sparkle-project.org/documentation/sandboxing/).
An actual update across this transition was not attempted.

**Trade-off:** fewer application processes and no secret transfer to a helper,
but the process owning the mirror, imports and UI also holds Accessibility
control and no longer has App Sandbox's filesystem restrictions.

## (b) Embedded unsandboxed XPC service

Use `NSXPCConnection(serviceName:)` and an embedded `.xpc` bundle, not
`Process`/`NSTask`/`posix_spawn`: children inherit the parent's sandbox, whereas
XPC services have independent configurations. Use an Objective-C-compatible,
typed NSXPC protocol; there is no need for a JSON socket protocol.

Entitlements/configuration for the minimal service:

- **Omit** `com.apple.security.app-sandbox` and `com.apple.security.inherit`.
- No `com.apple.security.accessibility` entitlement: Apple says it is not real.
- No Apple Events entitlement for AX/CGEvent code; no Input Monitoring or
  Screen Recording permission is required for this proposed read-and-post path.
- No keychain sharing or AutoFill entitlement: the service does not open the
  mirror or its keychain key.
- No app group or global Mach lookup exception for a private embedded service.
  Those become relevant to a separate named launch agent, which is unnecessary.
- Sign the helper with the product's Developer ID identity and hardened
  runtime, sign the outer bundle after nested code, and notarize the complete
  product. Hardened runtime is a signing option, not an Accessibility grant.
- `XPCService`: `ServiceType = Application`, `JoinExistingSession = true`,
  and `RunLoopType = NSRunLoop` in this probe. Joining the caller's session is
  a documented Info.plist setting, not an entitlement.

Apple's [NSXPCConnection initializer](https://developer.apple.com/documentation/foundation/nsxpcconnection/init(servicename:))
and [XPC services guide](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html)
describe embedding, on-demand launch and session configuration. Apple DTS
explicitly recommends non-sandboxed XPC for direct distribution in
[The Case for Sandboxing a Directly Distributed App](https://developer.apple.com/forums/thread/776609),
and confirms the arrangement again in
[this recent answer](https://developer.apple.com/forums/thread/845853).

The helper must perform the actual AX reads and typing. The sandboxed main app
cannot perform the RFC's AX checks itself. The app still owns credential
selection and approval; the helper receives the approved value and expected
destination/field and checks the target immediately before typing. A production
interface should authenticate the containing app and expose only that bounded
operation, not an arbitrary event relay. The throwaway inspection service is
not a production security boundary or a fill implementation.

TCC logs on this Mac identify the containing sandboxed app as the helper's
responsible process and authorization subject. That supports a single
Agent Keyring Accessibility entry, rather than asking users to enable each
browser or the CLI. Successful permission inheritance remains unverified until
Josh grants access and the same signed arrangement is rerun.

**Trade-off:** one more target, signed binary and IPC hop; plaintext briefly
exists in two trusted processes. The sandbox still limits the main app, but
the helper itself is an ordinary unsandboxed user process. A narrow helper
reduces exposed functionality; it does not create a magical per-site macOS
permission.

## (c) Exceptions and entitlements

Apple's supported position is that cross-app Accessibility is incompatible
with App Sandbox. Adding an invented entitlement does not change that.
The documented [temporary exception reference](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)
contains Apple Events, Mach, filesystem, IOKit and preference exceptions,
not a public AX-control exception. The folklore key
`com.apple.security.temporary-exception.accessibility` produced the same AX
failures in this probe. Because no variant had TCC consent, this negative
result alone is not proof of every hypothetical exception's ineffectiveness;
the decision rests on Apple's supported API guidance.

Apple Events permissions enable scripting specific apps, not universal AX
inspection. `com.apple.security.automation.apple-events` permits hardened
runtime apps to request Apple Events consent; it does not enable AX or event
posting. [Apple entitlement reference](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events).
Input Monitoring allows supported event listening inside sandboxed apps;
listening does not provide the required page/field inspection and keyboard
injection. [Apple DTS answer](https://developer.apple.com/forums/thread/811443).
Private entitlements or custom sandbox profiles are not a supported shipping
solution.

# Primary-source excerpts

Each excerpt is at most 25 words; the older sources are identified as such.

| Source | Exact excerpt |
| --- | --- |
| [Apple: Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox), incompatible activities list | “Use of accessibility APIs in assistive apps.” |
| [Apple DTS, June 2025](https://developer.apple.com/forums/thread/789663) | “Sandboxed app cannot use the Accessibility APIs” |
| [Apple DTS: direct distribution, March 2025](https://developer.apple.com/forums/thread/776609) | “move that code to a non-sandboxed XPC service” |
| [Apple DTS: recent direct-distribution confirmation](https://developer.apple.com/forums/thread/845853) | “This approach is perfectly reasonable for your directly distributed app.” |
| [Apple DTS: real entitlements](https://developer.apple.com/forums/thread/799000) | “There’s no entitlement that gates access to the Accessibility APIs on macOS.” |
| [Apple Frameworks Engineer, June 2018](https://developer.apple.com/forums/thread/103992) | “We are changing the default system permissions for using CGEventTaps and CGEvent posting to remove this capability without explicit user permission.” |
| [Apple XPC guide, archived](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html) | “Each XPC service has its own sandbox” |
| [Apple TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) | “The file-based keychain uses access control lists (`SecAccess`).” |
| [Sparkle's own guide](https://sparkle-project.org/documentation/sandboxing/) | “If you choose to later disable application sandboxing, you should also undo enabling the services and entitlements mentioned in this guide.” |

# Mac probe and exact results

Environment, from `sw_vers` and `xcrun swiftc --version`:

```text
ProductName: macOS
ProductVersion: 27.0
BuildVersion: 26A428
swift-driver version: 1.167 Apple Swift version 6.4 (swiftlang-6.4.0.20.104 clang-2100.3.20.102)
Target: arm64-apple-macosx27.0.0
```

Build command: `python3 spike/fill-sandbox/build.py`. It invokes `xcrun swiftc`
with a worktree-local module cache and signs with `codesign --options runtime
--timestamp=none`. The macOS skill's `mobilebuildmcp` CLI was unavailable
(`zsh: command not found: mobilebuildmcp`); a direct standalone compile was
used. No installation, notarization upload, real vault access or TCC database
change was performed.

Signature verification command:

```sh
codesign --verify --deep --strict --verbose=2 \
  .build/fill-sandbox-spike/FillProbeSandboxWithHelper.app
```

Output, worktree prefix abbreviated to `$WORKTREE`:

```text
--prepared:$WORKTREE/.build/fill-sandbox-spike/FillProbeSandboxWithHelper.app/Contents/XPCServices/FillProbeHelper.xpc
--validated:$WORKTREE/.build/fill-sandbox-spike/FillProbeSandboxWithHelper.app/Contents/XPCServices/FillProbeHelper.xpc
$WORKTREE/.build/fill-sandbox-spike/FillProbeSandboxWithHelper.app: valid on disk
$WORKTREE/.build/fill-sandbox-spike/FillProbeSandboxWithHelper.app: satisfies its Designated Requirement
```

`codesign -d --entitlements :- <bundle>` yielded exactly these dictionary
contents (XML wrapper omitted):

```xml
<!-- Plain and embedded Helper -->
<dict></dict>
<!-- Sandbox and SandboxWithHelper -->
<dict><key>com.apple.security.app-sandbox</key><true/></dict>
<!-- UnsupportedException -->
<dict><key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.temporary-exception.accessibility</key><true/></dict>
```

The apps were launched with `/usr/bin/open -g <absolute-bundle-path>` outside
the command runner's sandbox. The first attempts inside that runner failed
with `kLSNoExecutableErr` despite an existing executable; direct execution of
the sandboxed binary exited 134 before a report. These are launch-environment
failures, not AX evidence. The LaunchServices runs succeeded.

Collected with `python3 spike/fill-sandbox/collect.py`. Full exact report text
is committed at `spike/fill-sandbox/observed-results.txt`. Core output:

```text
=== Plain ===
AXIsProcessTrustedWithOptions(prompt=false)=false
CGPreflightPostEventAccess=false
receiver.AXFocusedUIElement=-25211 (valuePresent=false)
receiver.AXFocusedWindow=-25211
CGEventPost=skipped (receiver not frontmost)
home=$HOME
applicationSupport=$HOME/Library/Application Support
outside-container sentinel read=success (22 bytes)

=== Sandbox ===
AXIsProcessTrustedWithOptions(prompt=false)=false
CGPreflightPostEventAccess=false
receiver.AXFocusedUIElement=-25204 (valuePresent=false)
receiver.AXFocusedWindow=-25204
CGEventPost=skipped (receiver not frontmost)
home=$HOME/Library/Containers/com.example.AgentKeyringFillProbe.Sandbox/Data
applicationSupport=$HOME/Library/Containers/com.example.AgentKeyringFillProbe.Sandbox/Data/Library/Application Support
outside-container sentinel read=NSCocoaErrorDomain 257; underlying=1

=== UnsupportedException ===
AXIsProcessTrustedWithOptions(prompt=false)=false
CGPreflightPostEventAccess=false
receiver.AXFocusedUIElement=-25204 (valuePresent=false)
receiver.AXFocusedWindow=-25204
outside-container sentinel read=NSCocoaErrorDomain 257; underlying=1

=== SandboxWithHelper (host) ===
receiver.AXFocusedUIElement=-25204 (valuePresent=false)
outside-container sentinel read=NSCocoaErrorDomain 257; underlying=1
--- embedded unsandboxed XPC ---
bundle=com.example.AgentKeyringFillProbe.Helper
AXIsProcessTrustedWithOptions(prompt=false)=false
CGPreflightPostEventAccess=false
receiver.AXFocusedUIElement=-25211 (valuePresent=false)
receiver.AXFocusedWindow=-25211
CGEventPost=skipped (receiver not frontmost)
home=$HOME
applicationSupport=$HOME/Library/Application Support
outside-container sentinel read=success (22 bytes)
```

The SDK defines `-25204` as `kAXErrorCannotComplete` and `-25211` as
`kAXErrorAPIDisabled`. The filesystem denial's underlying `1` is `EPERM`.
The contrasting file read verifies actual sandbox enforcement and actual
helper independence, beyond just reading entitlement files. No variant had
Accessibility consent, so none of the AX failures is a permission-granted
control test.

TCC attribution command (outside the command runner sandbox):

```sh
/usr/bin/log show --last 20m --style compact --predicate \
  'process == "tccd" AND eventMessage CONTAINS "AUTHREQ_SUBJECT" AND (eventMessage CONTAINS "43151." OR eventMessage CONTAINS "43150.")'
```

Exact helper-subject lines:

```text
2026-10-12 05:10:02.014 Df tccd[66300:1dc5eb6] [com.apple.TCC:access] AUTHREQ_SUBJECT: msgID=43151.1, subject=com.example.AgentKeyringFillProbe.SandboxWithHelper,
2026-10-12 05:10:02.018 Df tccd[66300:1dc5e77] [com.apple.TCC:access] AUTHREQ_SUBJECT: msgID=43151.2, subject=com.example.AgentKeyringFillProbe.SandboxWithHelper,
2026-10-12 05:10:02.021 Df tccd[66300:1dc5eb6] [com.apple.TCC:access] AUTHREQ_SUBJECT: msgID=43151.3, subject=com.example.AgentKeyringFillProbe.SandboxWithHelper,
2026-10-12 05:10:02.028 Df tccd[66300:1dc5eb6] [com.apple.TCC:access] AUTHREQ_SUBJECT: msgID=43151.4, subject=com.example.AgentKeyringFillProbe.SandboxWithHelper,
```

The corresponding attribution records name helper PID 43151 as accessing/
requesting and host PID 43150 as responsible. Only probe-specific logs were
queried; no TCC database was read or edited.

**Keyboard test limitation:** The receiver stayed in the background. The native
UI tool returned `Computer Use was not approved to use FillProbeReceiver` for
both its path and bundle identifier. The probe therefore deliberately skipped
global keyboard injection. `CGPreflightPostEventAccess=false` is an actual
API result; it is not a `CGEventPost` delivery result. A void return from
`CGEventPost` would not prove delivery anyway. The receiver was closed after
the run, and the committed version closes itself after two minutes.

# What Josh must do once

For a shipping implementation, grant **Agent Keyring** in System Settings →
Privacy & Security → Accessibility when the helper requests it. TCC attribution
above supports this app entry; the permission-granted proof must confirm it.
No browser-by-browser Automation grants, Input Monitoring, Screen Recording,
Full Disk Access or root helper is part of the proposed design.

For the disposable proof before implementation:

1. Build with `PROBE_REQUEST_ACCESSIBILITY=1 python3 spike/fill-sandbox/build.py`.
   Launch `FillProbeSandboxWithHelper.app` once; the helper requests permission.
2. Josh enables **FillProbeSandboxWithHelper** in Accessibility (or adds that
   app using the `+` button). The agent must not grant it. An unsandboxed
   comparison separately needs **FillProbePlain** enabled if tested.
3. Josh opens and focuses the disposable receiver field, then the host is
   launched in the background again. Confirm AX trust and role reads, posting
   preflight and the visible marker's arrival. The host and helper send
   distinguishable `probe-SandboxWithHelper` and `probe-Helper` markers, so
   the receiver reveals which process delivered input. This avoids assuming
   that a successful void call means either process actually typed.

Then use a local dummy sign-in page to prove addresses and secure-field roles
in each browser. Accessibility permission does not guarantee that Safari,
Chrome or an embedded web view exposes its active page address. That browser
coverage question remains a separate slice. The screen must be unlocked for
the visible proof; locking/session behaviour was not implemented here.

No `fill` implementation, app configuration change, credential import,
review-model call, push or merge is included in this spike.
