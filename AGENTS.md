# Working on Agent Keyring

<!-- Written by AI on 2026.11.28 by model claude opus 5.5. -->

## No users yet, so no compatibility code

Agent Keyring has no users. Until it does:

- Never add backwards compatibility, readers for older saved formats, migrations, or shims for older builds of the Mac, iPhone or Watch app. Change the format and the code that reads it together.
- Saved state this build cannot decode is logged once and replaced with a fresh state. The app heals itself and never waits for a person to reset it.
- Hold writes only while the operating system keeps saved state locked: the iPhone before its first unlock after a restart, or a Mac keychain that cannot be read. Read the state again when it unlocks.

## State machines

- Put every state a feature can be in into one enum, and switch over it exhaustively. No `default:` in a switch over domain state: a new case must fail to compile wherever it is not handled. `script/check_boundaries.py` enforces this in the reducers.
- Never let a set of Booleans or optionals stand for a state. One named value says where something is up to.
- Saved state and messages between our own programs are protobuf (`proto/`), never JSON or property lists. JSON is read only at the outside boundaries `script/check_boundaries.py` allows.

## UI and domain stay apart

- `AgentKeyringApprovalUI` draws plain values from `AgentKeyringApprovalCore` and `AgentKeyringDesign`; it never imports Security, LocalAuthentication, CloudKit, WatchConnectivity, the protocol, `AgentKeyringSealing`, or `AgentKeyringEngine`. `AgentKeyringWatchUI` draws plain Watch values and never imports CloudKit, LocalAuthentication, Security, WatchConnectivity, or `AgentKeyringEngine`. Domain modules never import SwiftUI, AppKit, UIKit, or the UI modules. `script/check_boundaries.py` enforces all of these.
- Build and check screens against `SandboxWorld` / `SandboxBundleCodec` (in `AgentKeyringApprovalCore` and `AgentKeyringSealing/Sandbox`), a keyring whose every password is "hunter2", and the galleries the design checks render. Never against a real keyring.

## Names and comments

- Name every type, function and file with 2 to 4 specific, plain domain words that find it uniquely with `rg`, with no comment needed to say what it is ([how coding agents read code](https://modem.dev/blog/how-coding-agents-read-your-code)). The same idea has the same name in Swift and Go.
- Comments say what is true now and why. Never write history ("moved from", "used to", "renamed"): `git log` holds it.
- Diagnostic lines go through `KeyringDiagnosticLog`. They carry IDs, states and reasons, never a secret, a site or an account name.

## Checks

- The checks run locally only, through `.githooks` (`git config core.hooksPath .githooks`). `pre-commit` runs `./script/check.sh --fast`, and `pre-push` runs `./script/check.sh --full`. There is no CI.
- There are no lint waivers. Fix the code, never the rule.
- A test follows a path a person takes. Write no test where it would only check a proxy.
