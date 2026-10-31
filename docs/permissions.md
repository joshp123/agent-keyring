---
written_by: ai (gpt-6.1-sol, 2026-10-31), from the current entitlements and call paths
---

# What Agent Keyring is allowed to do

## On the Mac

| Part | Permission | Used for |
| --- | --- | --- |
| Agent Keyring app | App Sandbox | Keeps its encrypted mirror, rules and task history in its own container. |
| | AutoFill credential provider | Receives the logins you export from Apple Passwords. It cannot start an export or read Apple Passwords directly. |
| | Its own Keychain items | Holds the mirror encryption key, Secure Enclave signing keys and checkpoints for rules and leases. These items do not synchronize with iCloud. |
| | Incoming and outgoing network access | Serves local agents over `agent.sock` and connects to the paired relay. The app checks that the relay connection uses a tailnet address before sending data. |
| | Notifications | Offers a reminder when the mirrored copy is out of date. |
| `agent-keyring` command | No macOS privacy permission | Requests a lease and sends approved values to a program's stdin, a private process pipe or a Chrome debugging connection. |

**Agent Keyring does not request Accessibility permission.** Browser filling uses the CLI's Chrome debugging connection. It does not inspect the frontmost app or post keyboard events. Accessibility labels in Agent Keyring's own windows remain available to assistive tools.

Other agents' computer-use permissions are separate from Agent Keyring. A process receiving a credential can retain it; a lease limits future deliveries, not an existing website session or a copied password. The CLI's browser and destination checks do not create a security boundary against another process running as the same user.

## On the iPhone

| Permission or key | Used for |
| --- | --- |
| Face ID and a Secure Enclave key | Authorizes and signs an approval or a denial containing a reply. |
| Notifications | Shows requests forwarded through the relay. Delivery requires the relay's push configuration. |
| Network access | Connects to the paired relay over the tailnet. |

The relay approval flow can use the iPhone without importing passwords there: the Mac sends the approved credential from its mirror. The current Mac and phone approval flow does not use iCloud or a camera for pairing.

## When approval is needed

- Apple Passwords authorizes an export before handing selected logins to Agent Keyring.
- Ask logins require approval for the task. Automatic logins do not prompt.
- Confirming rules and pairing an approving device require owner authentication. A password-only refresh does not change the approved rules or require another confirmation.
- A denial without a reply needs no biometric check. A reply is an instruction to the agent and requires a signed, authenticated answer.

Agent Keyring never needs Accessibility permission to perform these steps.
