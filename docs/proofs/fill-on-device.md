Written by AI (GPT-6, Codex, 2026-10-12).

This is a manual proof procedure, not a claim of browser validation. Package
checks use a fake filler; the app build used `CODE_SIGNING_ALLOWED=NO`.
Accessibility consent, real browser addresses, focused-field roles and event
delivery still need this signed on-device proof. Use only the built-in example
login. Do not acquire/read a credential, inspect field values through browser
tools, or record a password field after unmasking it.

1. Quit the installed Agent Keyring through its menu. In this worktree, use
   the existing product signing configuration (copy
   `/Users/josh/code/agent-keyring/Config/Local.xcconfig` to
   `Config/Local.xcconfig` if it is not already present). It must identify the
   same bundle prefix/team as the installed app so the CLI uses its existing
   bridge directory. Build a signed proof copy; do not use the install scripts.

   ```sh
   cd /Users/josh/code/agent-keyring-worktrees/slice-fill
   CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" xcodebuild \
     -project AgentKeyring.xcodeproj -scheme AgentKeyring \
     -configuration Debug -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath "$PWD/.build/ProofDerivedData" \
     -allowProvisioningUpdates CODE_SIGN_IDENTITY='Developer ID Application' build
   proof_app="$PWD/.build/ProofDerivedData/Build/Products/Debug/AgentKeyring.app"
   proof_cli="$proof_app/Contents/Helpers/agent-keyring"
   codesign --verify --deep --strict "$proof_app"
   codesign -d --entitlements :- "$proof_app/Contents/XPCServices/AgentKeyringFiller.xpc"
   open "$proof_app"
   ```

   The helper must have hardened runtime and no App Sandbox/inherit entitlement;
   the app and credential-provider extension must retain App Sandbox. The service
   authenticates the caller using the containing app's designated requirement,
   through Apple's [XPC signing requirement API](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)).
   Confirm the proof copy is the only running Agent Keyring. In its main window,
   leave **Show example.com login** enabled. Confirm access rules in the Access
   window if requested, with the example login set to **Ask each time**. No import
   is needed for the example. Close the app windows.

2. Add that proof copy to **System Settings → Privacy & Security → Accessibility**
   and enable **Agent Keyring**. If an older entry points at the installed copy,
   select the proof app explicitly. Quit and reopen the proof app after changing
   permission. Consent is for Agent Keyring, not the CLI or each browser.

3. Prepare a local HTTPS page with the saved example.com host. These manual
   commands temporarily redirect example.com to loopback and trust a one-day
   test certificate in your login keychain. They are needed because the real
   example.com page has no sign-in form; remove them using step 7 after proof.

   ```sh
   mkdir -p .build/fill-proof
   openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
     -keyout .build/fill-proof/example-key.pem \
     -out .build/fill-proof/example-cert.pem \
     -subj '/CN=Agent Keyring fill proof' \
     -addext 'subjectAltName=DNS:example.com'
   chmod 600 .build/fill-proof/example-key.pem
   security add-trusted-cert -r trustRoot -p ssl \
     -k "$HOME/Library/Keychains/login.keychain-db" .build/fill-proof/example-cert.pem
   printf '\n127.0.0.1 example.com # agent-keyring-fill-proof\n' | sudo tee -a /etc/hosts
   sudo dscacheutil -flushcache
   sudo killall -HUP mDNSResponder
   python3 script/serve_fill_example.py \
     --cert .build/fill-proof/example-cert.pem --key .build/fill-proof/example-key.pem
   ```

   Keep the fixture server running. It binds only loopback, serves blank fields,
   checks only the built-in example login, and never logs submitted values.

4. In **Safari**, open `https://example.com:8443/login`. In a separate shell run
   the command below, then focus the page's Username field before the delay
   finishes. An agent can instead focus the field and invoke the CLI through
   its own shell tool immediately; a foreground terminal is not supported.

   ```sh
   (sleep 5; "$proof_cli" fill username example.com --account example@example.com; printf 'Exit: %s\n' "$?")
   ```

   Expect `Filled.` and exit 0, the example username visible in the field, and
   the form still open. Username delivery follows acquire's existing policy:
   it does not require biometric approval. Then run the following and focus
   the Password field before the delay ends.

   ```sh
   (sleep 5; "$proof_cli" fill password example.com --account example@example.com; printf 'Exit: %s\n' "$?")
   ```

   Approve the native Touch ID/Watch prompt. Expect approval status, `Filled.`,
   exit 0, and masked password characters. Browser focus should return after
   approval. The form must stay open: fill never presses Return. Click **Sign in**
   yourself and expect **Example login accepted.** Record only the safe CLI
   output and result, without reading the password DOM value.

5. Repeat step 4 in **Google Chrome**, then in **Claude Desktop's built-in browser
   pane**. For Claude, ask it to open that URL in its built-in pane, focus each
   field, and run the same `fill` commands through its shell tool; do not use its
   Chrome integration for this pane proof. Keep Claude frontmost while filling.
   After both fills, ask it to click Sign in, without reading either field value.
   Use **End all grants** from Agent Keyring's menu before each browser's password
   attempt to exercise the approval and focus-restoration path again. If a pane
   has no readable AX page address, expect exit 10 and the agent-browser sentence;
   record that as an unproved/unsupported fill path, not successful delivery.
   The same procedure can optionally be repeated in Codex's visible browser.

6. In each browser, reopen the form and focus Username; ask for `fill password`
   and expect exit 8 with no characters typed. Navigate to a different host and
   request the example login: expect exit 9 naming both hosts and no typing.
   Focus a native app field and expect exit 10. With permission disabled, expect
   exit 11 and the exact Accessibility grant sentence. Schedule a delayed fill,
   lock the Mac before it runs, and expect exit 12 without a prompt or typing.
   Restore Accessibility after its refusal check. The built-in example has no
   code seed: `fill code example.com` should report an unavailable field (exit 1).
   Fresh code generation is covered by a synthetic TOTP package test.

7. Stop the fixture server with Ctrl-C. Remove only this proof's hosts entry and
   certificate; quit the proof app and reopen the installed app if desired.
   The proof builds remain under `.build`; no app or CLI installation was changed.

   ```sh
   sudo sed -i '' '/# agent-keyring-fill-proof$/d' /etc/hosts
   sudo dscacheutil -flushcache
   sudo killall -HUP mDNSResponder
   security remove-trusted-cert .build/fill-proof/example-cert.pem
   proof_certificate_sha1="$(openssl x509 -in .build/fill-proof/example-cert.pem -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
   security delete-certificate -Z "$proof_certificate_sha1" "$HOME/Library/Keychains/login.keychain-db"
   ```
