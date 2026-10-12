Written by AI (GPT-6, Codex, 2026-10-12).

This is a manual proof procedure. Package tests use fake typing; an unsigned app
build does not prove Accessibility consent, browser address reading, field
recognition or event delivery. Use only the built-in example login. Do not read
field values through browser tools or unmask the password.

1. Quit the installed Agent Keyring through its menu. Use its existing product
   signing configuration in this worktree: copy
   `/Users/josh/code/agent-keyring/Config/Local.xcconfig` to `Config/Local.xcconfig`
   if needed. Keep the same bundle prefix/team so the CLI uses the existing bridge.
   Build a signed **Debug** copy with the normal Automatic signing configuration;
   do not run the install scripts. Debug adds loopback origins to the example
   login; Release retains only example.com.

   ```sh
   cd /Users/josh/code/agent-keyring-worktrees/slice-fill
   CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" xcodebuild \
     -project AgentKeyring.xcodeproj -scheme AgentKeyring \
     -configuration Debug -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath "$PWD/.build/ProofDerivedData" -allowProvisioningUpdates build
   proof_app="$PWD/.build/ProofDerivedData/Build/Products/Debug/AgentKeyring.app"
   proof_cli="$proof_app/Contents/Helpers/agent-keyring"
   example_credential_id='00000000-0000-0000-0000-000000000301'
   codesign --verify --deep --strict "$proof_app"
   codesign -dv --verbose=4 "$proof_app/Contents/XPCServices/AgentKeyringFiller.xpc"
   codesign -d --entitlements :- "$proof_app/Contents/XPCServices/AgentKeyringFiller.xpc"
   open "$proof_app"
   ```

   The helper must show hardened runtime and no App Sandbox/inherit entitlement.
   The app and credential-provider extension must retain App Sandbox. Keep only
   this copy running. Leave **Show example.com login** enabled in the main window.
   Confirm access rules in the Access window if requested, and leave the example
   set to **Ask each time**. No password import is needed. Close the app windows.

2. Enable the proof app in **System Settings → Privacy & Security → Accessibility**.
   Select the proof copy explicitly if an older entry points at the installed app.
   Quit and reopen the proof app after changing permission.

3. In a second shell, start the existing HTTP fixture on loopback. The example
   mode uses the built-in example credentials and skips the verification-code
   step. It logs only paths and safe results, never submitted values. Do not read
   the generated fixture configuration file.

   ```sh
   cd /Users/josh/code/agent-keyring-worktrees/slice-fill
   python3 script/test_login_server.py --example --port 8443
   ```

   Open `http://127.0.0.1:8443/login`. This uses the resolver's existing HTTP
   exception for loopback; no hosts-file changes or certificate setup is needed.

4. In **Safari**, open that URL. In the first shell run the command below, then
   focus the page's Username field before the delay ends. An agent can instead
   focus the field and invoke the CLI through its own shell tool immediately.

   ```sh
   (sleep 5; "$proof_cli" fill username http://127.0.0.1:8443 --credential "$example_credential_id"; printf 'Exit: %s\n' "$?")
   ```

   Expect `Filled.`, exit 0, the example username visible, and no submission.
   Username delivery follows acquire's existing policy and needs no biometric
   approval. Run the next command and focus Password before the delay ends:

   ```sh
   (sleep 5; "$proof_cli" fill password http://127.0.0.1:8443 --credential "$example_credential_id"; printf 'Exit: %s\n' "$?")
   ```

   Approve the native Touch ID/Watch prompt. Expect approval status, `Filled.`,
   exit 0 and masked password characters. Browser focus should return after
   approval. The form must stay open: fill never presses Return. Click **Sign in**
   yourself and expect **Signed in**. The safe counters at
   `http://127.0.0.1:8443/results` should show a password acceptance and no text
   received by the unrelated field. Record only CLI status and the safe outcome.

5. Repeat step 4 in **Google Chrome**, then in **Claude Desktop's built-in browser
   pane**. For Claude, ask it to open the loopback URL in that pane, focus each
   input and run the same fill commands through its shell tool. Keep Claude
   frontmost; use the built-in pane for this proof, not its Chrome integration.
   Ask it to click Sign in after both fills, without reading field values.
   Before each browser's password attempt, use **End all grants** in Agent
   Keyring's menu to exercise approval and focus restoration again.

   If no AX page address is readable from the focused field's nearest web area,
   expect exit 10 and the agent-browser sentence. Record that browser path as
   unverified, not successful delivery. The same procedure can also test Codex's
   visible browser.

6. Check refusals after ending grants. In each browser, reopen the form, focus
   Username and request a password: expect exit 8 and **no approval prompt**.
   Navigate to another host, then request the loopback example login: expect
   exit 9 naming both hosts, again without prompting or typing. With a browser
   pane still open, focus a native app field outside it and request the username:
   expect a refusal, with no fallback to the pane's page address.

   With Accessibility disabled, expect exit 11 and the grant sentence. Schedule
   a delayed fill, then lock the Mac before it runs: expect exit 12 without
   prompting or typing. Restore Accessibility after its refusal check. The
   built-in example has no code seed; `fill code http://127.0.0.1:8443 --credential`
   followed by the example ID reports an unavailable field (exit 1). Synthetic
   package tests cover fresh codes, deadlines and changes during typing.

7. Stop the server with Ctrl-C, close the fixture tabs and end all grants. Quit
   the proof app and reopen the installed app if desired. Remove the proof copy's
   Accessibility entry if you added it separately. No app or CLI installation
   was changed; proof builds stay under `.build`.
