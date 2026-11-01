---
written_by: AI (Claude Opus 5.5, 2026-11-01); revised after two cold reviews by GPT-6 Astra
status: design for review; no code yet
depends_on: 0004 (leases), 0005 (relay), 0009 (browser extension)
changes: the program receiver and the agent-process purpose in 0004
---

# RFC 0010: saved logins outside the browser

## The problem

RFC 0009 fills sign-in forms in browsers. Agents also need saved logins in
other places: a command-line tool or script that wants a password, a
scheduled job, a desktop app's sign-in sheet. Today the product has two
answers for those, and both are weak:

- `exec` gives one field to a program on its standard input and discards
  everything the program prints. Programs often need an account and a
  password, many read environment variables instead of standard input, and
  the agent nearly always needs the program's output to carry on.
- `read` writes the value to its standard output for the agent's own code to
  consume. In a shell call whose output the agent's tool captures, the value
  lands in the agent's conversation.

Josh, 30 October: "maximally secure; keeping p/w's away from agents where
possible; but also maximally efficient in the sense that agents should be able
to just do stuff i tell them to without struggling. security should beat
practicality tho". On 1 November: "whatever we have needs to work in claude AND
codex AND other 3rd party browsers AND via the command line if the browsers
aren't present". On a proposal to delete `read` without looking further: "there
are other things than browsers that have passwords?"

Scope is logins saved in Apple Passwords and their saved two-factor codes. API
keys and passkeys are out.

## Requirements

A search of agent transcripts found the needs below. The cases, their sources
and the limits of the search are kept privately; they are cases found, not a
complete inventory.

1. **Command-line use.** A program needs one or more fields of a saved login,
   on standard input or as environment variables, and the agent needs the
   program's output. This is Josh's explicit requirement, and the search found
   workflows of this shape; they are not numerous.
2. **Browsers an agent or job launches itself.** Where no filler reached the
   browser, agents have entered passwords by their own means. RFC 0009's
   extension covers any browser that can load it, including a headless one a
   job starts.
3. **Password fields outside a browser page:** desktop app sign-in sheets and
   embedded browsers that cannot load the extension. Real, but thinly
   evidenced for saved logins.
4. **Two-factor codes** saved with a login, wherever the login is used. None
   were found outside a browser, and supporting them costs nothing extra.

## How others do it

**1Password** (developer.1password.com/docs/cli, support.1password.com):

- `op run -- COMMAND` starts the command with secrets as environment
  variables for the life of that process, and masks secrets the command prints
  on standard output or error unless told `--no-masking`. 1Password describes
  masking as best effort, and warns that processes of the same user can read
  each other's environment.
- `op inject` writes secrets into a config file from a template; the file then
  holds the plaintext.
- `op read` writes a secret to standard output or a file, typically inside
  `$(...)`. Whether it is shown depends on what consumes it.
- Shell plugins wrap common CLIs so that running one asks for Touch ID once
  per terminal session and injects its credential as environment variables.
- The SSH agent signs with keys that never leave 1Password; approval is per
  key and per application, remembered for a session.
- Universal Autofill fills usernames and passwords into Mac apps,
  administrator prompts and `sudo` in Terminal, using the Accessibility
  permission, after the person presses a shortcut.

**Bitwarden's agent access** (github.com/bitwarden/agent-access) carries
credentials encrypted to a remote process, which then holds the plaintext.
**HashiCorp Vault's agent** renders secrets into files or environment
variables, like `op inject` and `op run`.

The shape to copy is `op run` with masking, for programs. Whatever receives a
password can keep it; none of these products claims otherwise.

## The design

Each lease has one purpose and one receiver: a browser fill, a program, or
(later, if proven) a Mac app field. The agent finds a login, leases it for its
task, uses it as often as that receiver allows, and releases it (RFC 0004).

| Route | For | Command | Status |
| --- | --- | --- | --- |
| Browser | Sign-in pages in any browser with the extension, including headless browsers that agents or jobs launch | `fill --tab` | RFC 0009 |
| Program | Command-line tools, scripts, scheduled jobs; SSH and `sudo` through their standard input or environment options | `exec` | This RFC |
| App field | A password field in a Mac app or an embedded browser the extension cannot reach | `fill --app` | Feasibility first |

### Program route

A program lease approves **one exact command**: the executable, its arguments
and how each field reaches it. The approval shows all three, and `exec` runs
exactly that, as often as the task needs, without asking again.

```sh
lease=$(agent-keyring lease LOGIN --task "$task" --for program \
  --reason "Download the statement the user asked for" \
  --env SERVICE_USER=username --stdin password \
  -- /usr/local/bin/statement-client download --month 2026-10)
agent-keyring exec "$lease"
agent-keyring release "$lease"
```

**Several steps.** When a task needs the login in more than one command, the
agent writes one script that runs them all and leases that script. The
approval then shows a script path, which says where it is, not what it does,
and the script receives the values. One lease cannot run other commands:
allowing that would make the command on the approval meaningless.

- **Delivery.** `--stdin FIELD` writes one field to standard input, then
  closes it. `--env NAME=FIELD`, repeatable, sets environment variables. They
  can be combined. Fields are `username`, `password` and `one-time-code`; for
  a code, the current one is selected when `exec` runs. Values never go in
  the command's arguments. A program that wants a password file can often be
  given `/dev/stdin`.
- **Output.** `exec` passes the program's standard output and error through,
  each stream separately, replacing verbatim occurrences of each delivered
  value with `<hidden by Agent Keyring>`. Each stream holds back only trailing
  bytes that could be the start of a value, until the next write or the
  program's exit shows they aren't, so a value split across writes is still
  replaced. This is best effort: it catches a program printing the value as
  it is, not encoded or altered. `exec` exits with the program's exit status.
- **Repeats.** A repeated `exec` under the same lease does not run the program
  again and does not replay output. It prints "Already ran at TIME and exited
  with status N; its output was not kept. Inspect the result, or use --again
  to run it again." and exits with that status. If the earlier run may have
  started but recorded no result, it says so and exits 1. Output is never
  stored.
- **Where it runs.** On the machine whose `agent-keyring` command asked, as
  the requesting user. The CLI receives the values, sealed through the relay
  for other machines (RFC 0005), starts the program and streams its output
  locally. The relay carries nothing new.
- **Long-running programs.** The lease limits when values are handed out, not
  how long a program runs.
- **Prompts on a terminal.** Programs that ask at a terminal usually have an
  input or environment option: `sudo -S`, `sshpass -e` with `--env
  SSHPASS=password`, `ssh` with `SSH_ASKPASS`. No terminal emulation is built
  until a real case lacks such an option.

### App field route: feasibility first

Sending keystrokes to an app's process keeps them out of other apps, not
inside one field: the app, or a page inside it, can move focus between a check
and the app handling the keys, and deleting afterwards cannot take back what
the app already received or showed. Checking focus before each character has
the same race. Pressing Return does not mean the app accepted the password. A
secure field shows dots while typing; it does not stop the app revealing or
copying the value later. No current code delivers to app fields.

Slice A0 asks one question: can Agent Keyring set a value on one chosen
Accessibility element, so that no other field can receive it? It covers an
ordinary native sign-in sheet, a sign-in page in an embedded browser the
extension cannot reach, and focus moving to another field inside the same app.
Passing a finite race test is evidence about a mechanism, not proof of an
atomic guarantee, so a surface counts only where the mechanism itself targets
the element. Surfaces that would need keystroke typing are refused; no further
focus polling is added. Slice A1 then builds the route for the surfaces A0
supports, with the approval naming the app and its signer. Results report what
was done ("value set and Return pressed"), not that sign-in succeeded.

### `read` is removed, after its uses have a route

What removing `read` buys: one fewer way to write plaintext to standard
output, the easiest way for a value to land in an agent's conversation by
accident, and one supported interface for programs instead of two. What it
does not buy: an authorised client running as the same user can still ask the
authority to deliver the values for an approved lease, browser or program,
because the authority checks the lease's purpose and recipient, not which
receiver code is asking. `exec` also hands the values to a program the agent
chose. An approved agent that sets out to obtain a value can.

Removal gate, in order:

1. P1 ships the wider `exec`.
2. Every known use of `read` has a working route: programs through `exec`,
   browsers that can load the extension through `fill --tab`. Uses in browsers
   that cannot load it are not covered until A1 supports that surface; until
   then the skill tells agents to use a browser with the extension. The
   repository's proof scripts move from the agent-process purpose to `exec`,
   and machines where agents run are checked for scripts calling `read`.
3. `read` and `--for agent-process` are removed and field number 3 of
   `Purpose` is reserved. No compatibility layer is built.

## Who can reach the value

The supported CLI does not return credential values in its normal results.
That promise does not cover page content, other tools, or an authorised client
requesting delivery directly, as described above.

| Route | Not in the CLI's normal results or chat | Also reachable by the agent | Holders of plaintext |
| --- | --- | --- | --- |
| Browser | The value | The page while the value is in a field; direct delivery for the approved lease | The CLI's native host and receiver, the extension, the page, and the destination site, which may keep it after submission |
| Program, standard input | The value; verbatim echoes are hidden | The value, through the program it chose; direct delivery for the approved lease | The CLI's receiver and the program, for as long as it runs or wherever it stores it |
| Program, environment variable | As above | As above, and the process environment, which other processes of the same user can read while the program runs | As above |

- **Standard input is preferred**; environment variables are for programs
  that only take them.
- **The program is the agent's choice.** A misaligned agent can name a program
  that keeps or transforms the value. The approval shows the exact command and
  bindings, so Josh can refuse it; an Automatic login shows nobody.
- **All routes.** Agent Keyring keeps values out of the agent's conversation,
  command arguments and normal tool output where that is possible. It does not
  claim to keep them from software that controls the receiving machine.

## Contract and approval changes

Nothing is released, so fields can be removed.

- `ProgramCommand` gains `stdin_field` (optional, one `CredentialField`) and
  repeated `EnvBinding { name, field }`. A program request needs at least one
  binding. Environment names match `[A-Za-z_][A-Za-z0-9_]*` and are unique.
  The same field may be bound more than once. Bindings are part of the
  approved request; joining a task's lease with a different command or
  bindings is refused, as for a different command today.
- `ExecuteProgramRequest.field` is removed. `exec` requests exactly the
  distinct fields the bindings name, with `OPERATION_KIND_EXECUTE_PROGRAM`.
- Both authorities accept that multi-field delivery for a program lease and
  refuse fields the bindings don't name: the Mac app's lease store
  (`CredentialLeaseStore`) and the relay (`internal/relay/leases.go`), which
  today allow several fields only for a browser fill.
- The receiver's retry identity covers the executable, arguments and
  bindings, replacing today's execution-time field.
- The program receipt keeps outcome, exit status and time, never output. No
  output travels in the protocol.
- Approval screens on the Mac and iPhone show each binding ("password on
  standard input; username as SERVICE_USER") beside the command; today they
  show only the command.
- `Purpose`: remove `PURPOSE_AGENT_PROCESS` and reserve 3, at the removal
  gate. The app field purpose is added only by A1.

## Build slices

Proofs use real agents (Claude Code and Codex CLI), programs already on the
machine, dummy logins and dummy services, and the isolated test setup from
the extension proof: nothing installed globally, no real account. Approval in
these proofs comes from the scripted stand-in authority, so "asks once" proves
the protocol, not Touch ID or the iPhone. A check on a real approval device
remains outstanding and does not block this plumbing.

| Slice | What | Done when |
| --- | --- | --- |
| P1 | Bindings, multi-field delivery on both authorities, hidden output on both streams, no replay, approval screens, skill | The program proof below passes on a Mac against the local authority and on a Linux machine through the relay |
| P2 | Scheduled browser helpers move to the extension: the job's own browser build and profile load it, and its custom typing code is deleted | A dummy sign-in in that same browser build and profile arrangement completes through `fill --tab`. If it cannot, the concrete blocker is recorded before any interim program migration is considered |
| P3 | Remove `read` once the gate above is met | `read` and `--for agent-process` are refused and absent from `--help`; the proof scripts pass using `exec` |
| A0 | App field feasibility | The three cases above each have a result: supported by element targeting, or refused |
| A1 | App field route for the surfaces A0 supports | Real agents complete a dummy sign-in in each supported surface, and a same-app focus change leaves nothing in the other field |

### Program proof (P1)

Each agent gets only the task, the skill and a dummy login, without being
told which route to use. On both machines:

- "Use my saved login for the test service to fetch my account page and tell
  me the balance it shows." The dummy service requires both the account name
  and the password. Expected: one lease with both fields bound, for example
  `curl` reading its credentials from a config on standard input built by a
  small script from `--env` values; the agent reports the balance from the
  output.
- An Ask login asks once. A repeated `exec` does not run the command again and
  prints the completed-result message; `--again` runs it without a second
  approval.
- Through the real CLI, leasing the same task with a different command, and
  again with different bindings, is refused.
- A dummy program writes the password split across two writes on standard
  output, then split again on standard error, between ordinary lines, and
  exits 3. The agent sees the ordinary lines, `<hidden by Agent Keyring>` in
  both places, and exit status 3.
- The dummy password and account name appear in no transcript, tool output or
  command arguments captured during the run.

On the Mac, a second task uses a native program: "Make an encrypted disk
image of this folder with my backup login, then open it and tell me where it
mounted." Expected: one leased script running `hdiutil create` and `hdiutil
attach` with `-stdinpass`.
