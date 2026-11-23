# Contributing to Agent Keyring

Agent Keyring is fully open source (MIT). You are welcome to fork it, inspect it,
and run it.

At the same time, Agent Keyring is maintained by a small team with a tight
security and architectural vision. **We are not accepting unsolicited feature
pull requests.**

We are bottlenecked by review capacity and security review, not by code or
tokens. In almost every case, reviewing a pull request takes more effort than
writing it ourselves.

## What we do not accept (closed without review)

Unless a maintainer explicitly asked you to open a PR, we will close pull
requests for:

- New features
- UI or app overhauls (Mac, iPhone, Apple Watch, or browser extension)
- Architecture or protocol changes (cryptography, Secure Enclave handling,
  Tailscale transport, rule signing, or browser bridge wire formats)
- Support for additional operating systems or password managers
- AI-generated drive-by refactors, lint sweeps, or synthetic test suites

A pull request that changes how the product behaves is a feature, even if it is
labelled as a fix.

## Reporting security vulnerabilities

**Do not report security issues in public GitHub Issues.** Use GitHub's private
vulnerability reporting on this repository (**Security -> Advisories -> Report a
vulnerability**) so we can investigate and ship a fix before disclosure. Never
include real passwords, two-factor seeds, or private keys in any report.

## How to help

- **Report non-security bugs** in GitHub Issues with clear reproduction steps
  and your Agent Keyring version (`agent-keyring version`). Never paste real
  passwords, two-factor seeds, account names, or private identifiers into public
  issues.
- **Share ideas** in GitHub Issues or Discussions instead of opening a PR.
- **Fix a real bug.** Daily users hitting a concrete crash or regression may
  open a small, focused PR fixing that one bug.

## Rules for bug-fix pull requests

Every external PR, including drafts, must follow these rules. Following them
does not guarantee review or merge; we may close any PR without review.

1. **One bug per PR.** Keep the diff minimal and link the issue for anything
   beyond an obvious one-line fix.
2. **No private data or secrets.** Never commit real credentials, keys,
   certificates, or personal device identifiers.
3. **Verify locally.** Build and test your change against the real affected
   path before opening the PR.
4. **Disclose AI assistance** and verify every line yourself. Unreviewed
   AI-generated PRs will be closed immediately.

## Building from source

- **Mac app:** Requires Xcode 27, an Apple Developer team, and
  [devenv](https://devenv.sh). Copy `Config/Local.xcconfig.example` to
  `Config/Local.xcconfig`, add your team ID, then run:

  ```sh
  devenv shell -- ./script/build_cli.sh
  ./script/build_and_run.sh --verify
  ```

- **Browser extension (Chrome, Chromium, Brave, Edge, Arc):** Open
  `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and
  select `BrowserExtension/`.
- **iPhone and Apple Watch app:** Open `AgentKeyringPhone.xcodeproj` in Xcode or
  run `./script/build_iphone.sh device`. For Apple Push Notification delivery on
  your own developer team build, supply your `.p8` key via
  `agent-keyring push-key --key-id KEY_ID --team-id TEAM_ID < AuthKey_KEY_ID.p8`.
- **Standalone CLI on Linux or macOS:** Install via Nix flakes:

  ```sh
  nix profile add github:opentrawl/agent-keyring#agent-keyring
  ```

  Run `agent-keyring skill` for the full agent instructions and
  `agent-keyring --help` for every command and exit code.
