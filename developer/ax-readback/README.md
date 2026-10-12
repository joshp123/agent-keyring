Written by AI (GPT-6, 2026-10-12). Read-only Accessibility spike; never reads field values, types, or sends events.
Build from this worktree: `swift build --package-path developer/ax-readback`; run `developer/ax-readback/.build/debug/ax-readback --watch`.
Josh: open System Settings → Privacy & Security → Accessibility → +, press ⇧⌘G, enter this worktree's full `developer/ax-readback/.build/debug/ax-readback` path, add it and enable it; if macOS lists the launching app instead, enable that app, then restart the probe and check `Accessibility trusted: true`.
Safari: leave watch running, bring Safari forward, open a sign-in page and focus its username then password field; repeat the same steps in Google Chrome.
Claude: leave watch running, bring Claude forward, open a sign-in page in its built-in browser pane and focus username then password; compare labelled address candidates and roles (reliability remains unverified until these manual runs).
