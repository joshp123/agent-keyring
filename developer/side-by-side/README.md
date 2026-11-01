<!-- Written by AI on 2026.11.01 by model gpt-6.1-sol. -->

# Isolated session with the real Mac app

This packages the Release app, its Go CLI and its bundled skill under
`com.joshpalmer.KeyringTest.AgentKeyring`. It never installs or launches anything.
The credential extension is omitted. The only runtime configuration differences
are the identity/display name and an inactive updater pointed at loopback port 9.
No fake authorizer, software signing key, fixture authority or DEBUG path is used.

Josh's source is the full parent thread:
`python3 -I -B ~/.agents/skills/raw-steering/scripts/josh_words.py t3 389b6a41-ae24-4f80-bda2-e899b765c617 --both`.
His current scope holds browser sign-in until the replacement browser design
exists. It permits launch, rules, Touch ID, program delivery and denial.

## Build and signing

Read `~/code/nix/nixos-config/docs/runbooks/apple-signing-certificates.md` and the
Apple documentation it links before signing. The current existing Apple
Development identity is used; private keys stay on the MacBook. Nothing is
revoked or replaced. Do not use the production app identifier or keychain group.

Export a recorded clean revision to a private directory on the verified Darwin
host `mac-mini`. Build the CLI using `script/build_cli.sh`, then build:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -workspace AgentKeyring.xcworkspace -scheme AgentKeyring -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$proof/DerivedData" \
  AGENT_KEYRING_BUNDLE_ID_PREFIX=com.joshpalmer.KeyringTest \
  AGENT_KEYRING_TEAM_ID=7M8BR7R488 PRODUCT_DISPLAY_NAME='Agent Keyring Test' \
  MARKETING_VERSION=0.4.1 CURRENT_PROJECT_VERSION=202611010812 \
  CODE_SIGNING_ALLOWED=NO build
```

Trash `Contents/PlugIns` on the mini before transferring the unsigned app.
Transfer a `ditto` zip, not recursive scp: preserve framework symlinks.

The signing-only project does not run the product or any fixture. Xcode uses the
existing App Store Connect key to manage its development profile. On 1 November
it supplied a new wildcard profile using the existing development certificate;
no new certificate was needed. Run on the MacBook:

```sh
python3 developer/side-by-side/request_profile.py --output "$proof/signing"
```

Inspect the generated profile: team, application-identifier wildcard, the
current certificate's SHA-1, expiry and this Mac's registered device. Stop if
Xcode cannot use the existing certificate. Do not create one to make the check
pass. Copy its `Contents/embedded.provisionprofile` out, then trash the unused
`Signing.app` so only the real test app remains for this identity.

```sh
python3 developer/side-by-side/prepare.py \
  --source-app "$proof/unsigned/AgentKeyring.app" \
  --output "$HOME/AgentKeyring-Tests/round12/Agent Keyring Test.app" \
  --source-commit "$source_commit" --profile "$profile" --identity "$development_sha1"
```

This signs the nested code, gives the real app the runbook's team-based
designated requirement and verifies the package. It writes a manifest beside
it with the revision and SHA-256 hashes of the app executable, CLI and skill.
Nothing calls `open`, `install` or a global CLI.

## Session with Josh

Estimated attention: 5–8 minutes, depending on the panels; up to four touches.
Use the app's built-in **example.com** login. No Apple Passwords export, real
account, real password or test mirror is needed for this reduced scope.

1. Open **Agent Keyring Test** by its full path. Check the menu bar, Rules and
   Machines windows. Check the test PID's executable path and socket owner.
   The test has its own container, preference domain and exact Keychain group.
2. A fresh Codex, then Claude, uses its bundled CLI to lease the example login
   for the harmless stdin consumer. Josh approves each through the actual panel
   with Touch ID. The consumer records success without printing a value.
3. Deny another request with a distinctive reply. Verify the waiting agent gets
   that exact reply, stops and never runs the consumer.
4. Change the example login to Automatic in Rules and confirm with Touch ID.
   A program lease must finish with no approval panel. Put it back on Ask if
   continuing the isolated relay test.

Each agent gets its own work directory and client state. **Full path alone is
not enough**: the current CLI otherwise initially prefers the installed app.
Use these supported overrides in the agent's environment, without changing HOME
or the real agent skills:

```sh
export AGENT_KEYRING_SOCKET="$HOME/Library/Containers/com.joshpalmer.KeyringTest.AgentKeyring/Data/agent.sock"
export AGENT_KEYRING_STATE_DIR="$proof/receiver-codex" # a fresh directory per agent
unset AGENT_KEYRING_RELAY
cli="$HOME/AgentKeyring-Tests/round12/Agent Keyring Test.app/Contents/Helpers/agent-keyring"
"$cli" skill
```

Check these paths before starting an agent; never run `agent-keyring install`.
Supply the unchanged `skill` output, full CLI path, program path and the plain
task. Do not coach its command sequence or answer the app from a fixture. The
program is `python3 developer/side-by-side/check_program.py "$proof/received-count"`
using an absolute Python executable and absolute paths. It reads only stdin,
checks the synthetic value and records the number of successful invocations.
No secret or password length is printed. A repeated CLI operation should leave
the count at one. Record the real agent's commands and whether it kept `lease`
running until Josh answered. A stopped waiting command is a failure.

Browser sign-in, a remote agent sign-in and phone hardware delivery remain
unproved by this session. Do not describe a program-route pass as a sign-in.
An optional relay session uses a newly built relay under a separate state root
and ephemeral tailnet port on the mini; no service, CLI link or installed phone
is repointed. A phone needs its own safely isolated signing setup first.

## Evidence and cleanup

Before and after, record production bundle hashes, CLI/skill link targets,
production state-file sizes/timestamps, and
`pluginkit -mAv -p com.apple.authentication-services-credential-provider-ui`.
Never read production Keychain values for this check. Capture actual windows
with the computer-use tool during the session. Save paths, hashes, PID/socket
owner, agent transcripts, stdin consumer counts and the exact denial reply.

Quit only the test app. Trash its package and test data after the session.
Do not use a Keychain deletion command with constant production service names:
the authority services share their names and are isolated by access group.
The prepared `Test Keychain Cleanup.app` contains only `ClearTestKeychain.swift`,
compiled on the mini and signed under the same isolated identity and exact
Keychain group. After quitting the real test app, run its main executable
directly with `--clear-test-keychain`; it opens no window. It deletes only
non-synchronizable generic-password/key items in that exact test group and the
classic mirror-key service named by the test bundle ID. It has not been run
during preparation. Then trash the test container and both test bundles.
Never unregister, launch, alter or trash the live 0.2.5 app or its extension.
