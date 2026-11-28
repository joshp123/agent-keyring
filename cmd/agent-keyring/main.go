// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"text/tabwriter"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/authority"
	"github.com/opentrawl/agent-keyring/internal/browserbridge"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"github.com/opentrawl/agent-keyring/internal/receiver"
	"github.com/opentrawl/agent-keyring/internal/remote"
)

const help = `Agent Keyring: use a saved login for one task.

  find SITE                  Find login IDs (example.com is enough)
  lease LOGIN --task TASK --reason REASON [--agent NAME]
                             Ask once; print the lease ID when active. NAME is
                             who the user sees asking, such as Claude Code
  status LEASE [--wait]      Inspect a lease, or wait for its decision
  tabs                       List tabs in profiles with the browser extension
  fields --tab TARGET        List visible fields and selectors, never values
  fill LEASE [--tab TARGET]
       [--username CSS] [--password CSS] [--code CSS] --submit CSS
                             Fill, submit this sign-in step, clear the fields
  read LEASE --field FIELD   Deliver a value to a private process pipe
  release LEASE             End permission when the task is done
  skill                     Print the bundled agent instructions
  install --undo            Put back the links an earlier version's install replaced
  install --browser-profile DIRECTORY
                            Register a helper only in this browser user-data directory
  complain --summary LINE [--command COMMAND] [--thread ID]
                            Tell whoever builds Agent Keyring it was annoying,
                            confusing or broken; more detail on standard input.
                            Kept on this computer. Never include a password or secret
  complaints [--since 24h]  Read agents' complaints kept on this computer
  enrol --name NAME --code CODE
                            Join this computer, with a code from Add Another
                            Computer on the Mac or iPhone
  invite                    On the Mac: print a one-time code for one computer to join
  push-key --key-id ID --team-id ID < AuthKey_ID.p8
                            On the Mac: give the app Apple's push key
  version                   Print this command's version and build number
  logs [--since 30m] [--request ID]
                            What this computer did and why, in time order; no secrets

A lease ends on release or 30 minutes after approval. It covers fill and read
for that login; reuse it through retries and two-factor steps. Automatic
logins approve without asking.

lease: --no-wait returns a pending reference; --request ID retains a
       caller-supplied retry ID.
fill:  targets come from tabs or fields and include the current document.
       Without --tab, exactly one tab must match the login's saved site.
       --again deliberately repeats an inspected step; --operation ID is
       an explicit retry key. These two options cannot be combined.
read:  fields are username, password and one-time-code. Never run read in a
       model-visible shell call. To give a program the password, pipe it:
       agent-keyring read LEASE --field password | gh auth login --with-token

Lease IDs and read values go to stdout; progress and outcomes go to stderr.
Find, tabs and fields print tables. Status without --wait prints readable state.
Exit status: 0 succeeded; 1 refused or unavailable; 2 incorrect usage;
             3 browser fill uncertain (inspect the page; do not retry blindly).
Environment: AGENT_KEYRING_SOCKET overrides the local authority socket.
             AGENT_KEYRING_STATE_DIR overrides this machine's private state directory.
             AGENT_KEYRING_RELAY_URL is the box relay to enrol through, if not
             https://push.opentrawl.sh (for example your own agent-keyring-box).
Run any command with --help for this guide.
`

type cliArguments struct {
	positionals []string
	options     map[string]string
	flags       map[string]bool
	extra       []string
}

func parseCLIArguments(args []string) (cliArguments, error) {
	result := cliArguments{options: map[string]string{}, flags: map[string]bool{}}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			result.extra = args[i+1:]
			break
		}
		if !strings.HasPrefix(arg, "-") {
			result.positionals = append(result.positionals, arg)
			continue
		}
		name, value, hasValue := strings.Cut(strings.TrimPrefix(arg, "--"), "=")
		switch name {
		case "no-wait", "wait", "again", "undo":
			if hasValue {
				return result, fmt.Errorf("--%s does not take a value.", name)
			}
			result.flags[name] = true
		case "task", "reason", "agent", "request", "since", "field", "tab", "username", "password", "code", "submit", "operation", "name", "browser-profile",
			"key-id", "team-id", "summary", "command", "thread":
			used, err := result.parseOption(name, value, hasValue, args[i+1:])
			if err != nil {
				return result, err
			}
			i += used
		default:
			return result, fmt.Errorf("Unknown option %s. Run 'agent-keyring --help'.", arg)
		}
	}
	return result, nil
}
func (a cliArguments) parseOption(name, value string, hasValue bool, rest []string) (int, error) {
	if _, exists := a.options[name]; exists {
		return 0, fmt.Errorf("Use --%s only once.", name)
	}
	used := 0
	if !hasValue && len(rest) > 0 && !strings.HasPrefix(rest[0], "--") {
		value, used = rest[0], 1
	}
	if value == "" {
		return 0, fmt.Errorf("--%s needs a value.", name)
	}
	a.options[name] = value
	return used, nil
}

func (a cliArguments) checkCommandOptions(options, flags string) error {
	for key := range a.options {
		if !strings.Contains(" "+options+" ", " "+key+" ") {
			return fmt.Errorf("--%s is not an option for this command.", key)
		}
	}
	for key := range a.flags {
		if !strings.Contains(" "+flags+" ", " "+key+" ") {
			return fmt.Errorf("--%s is not an option for this command.", key)
		}
	}
	return nil
}
func (a cliArguments) requireOneArgument() (string, error) {
	if len(a.positionals) != 1 {
		return "", errors.New("Supply exactly one login or lease ID. Run 'agent-keyring --help'.")
	}
	return a.positionals[0], nil
}
func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()
	code, err := dispatchKeyringCommand(ctx, os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "agent-keyring:", err)
		if code == 0 {
			code = 1
		}
	}
	os.Exit(code)
}
func dispatchKeyringCommand(ctx context.Context, args []string) (int, error) {
	if len(args) > 0 && strings.HasPrefix(args[0], "chrome-extension://") {
		return 0, browserbridge.RunBrowserNativeHost(ctx, args[0], chooseAuthority)
	}
	if len(args) == 0 || args[0] == "help" {
		fmt.Print(help)
		return 0, nil
	}
	if args[0] == "version" || args[0] == "--version" {
		fmt.Println(keyringBuildVersion())
		return 0, nil
	}
	if wantsHelp(args) {
		fmt.Print(help)
		return 0, nil
	}
	command := args[0]
	a, err := parseCLIArguments(args[1:])
	if err != nil {
		return 2, err
	}
	if code, handled, err := runMacAuthorityCommand(ctx, command, a); handled {
		return code, err
	}
	switch command {
	case "skill", "install":
		return runIntegration(command, a, len(args))
	case "logs":
		return runLogs(ctx, a)
	case "complain":
		return runComplaintCommand(ctx, a)
	case "complaints":
		return listComplaints(ctx, a)
	case "tabs", "fields":
		return inspectBrowser(ctx, command, a)
	case "fill":
		return fillBrowser(ctx, a)
	case "enrol":
		return runEnrol(ctx, a)
	case "invite":
		return runInvite(ctx, len(args))
	case "find", "lease", "status", "release", "read":
		return runAuthorityCommand(ctx, command, a)
	default:
		return 2, fmt.Errorf("Unknown command %q. Run 'agent-keyring --help'.", command)
	}
}

func wantsHelp(args []string) bool {
	for _, arg := range args {
		switch arg {
		case "--help", "-h":
			return true
		case "--":
			return false
		}
	}
	return false
}

func runIntegration(command string, a cliArguments, argCount int) (int, error) {
	if command == "install" && a.options["browser-profile"] != "" {
		if err := a.checkCommandOptions("browser-profile", ""); err != nil || len(a.positionals) > 0 || len(a.extra) > 0 {
			return 2, errors.New("install --browser-profile takes only the browser's user-data directory.")
		}
		return 0, installNativeHost(a.options["browser-profile"])
	}
	if command == "install" && a.flags["undo"] {
		if argCount != 2 {
			return 2, errors.New("install --undo takes nothing else.")
		}
		return 0, undoInstall()
	}
	if argCount != 1 {
		return 2, errors.New("This command takes no arguments.")
	}
	return 0, runAgentIntegration(command)
}

func runLogs(ctx context.Context, a cliArguments) (int, error) {
	if err := a.checkCommandOptions("since request", ""); err != nil || len(a.positionals) != 0 || len(a.extra) != 0 {
		return 2, errors.New("logs takes --since DURATION (such as 30m) and --request ID, both optional.")
	}
	var since int64
	if text := a.options["since"]; text != "" {
		duration, e := time.ParseDuration(text)
		if e != nil || duration <= 0 {
			return 2, errors.New("--since takes a duration such as 10m or 2h.")
		}
		since = time.Now().Add(-duration).Unix()
	}
	lines, e := gatherLogs(ctx, since, a.options["request"])
	for _, line := range lines {
		fmt.Println(sanitizeTerminalText(line))
	}
	if e == nil && len(lines) == 0 {
		fmt.Fprintln(os.Stderr, "No log lines match.")
	}
	if e != nil {
		return 1, e
	}
	return 0, nil
}

func runEnrol(ctx context.Context, a cliArguments) (int, error) {
	if err := a.checkCommandOptions("name code", ""); err != nil {
		return 2, err
	}
	if len(a.positionals) > 0 || len(a.extra) > 0 || strings.TrimSpace(a.options["name"]) == "" || a.options["code"] == "" {
		return 2, errors.New("enrol takes --name NAME and --code CODE, the code Add Another Computer shows on the Mac or iPhone.")
	}
	store, e := clientstate.DefaultClientStateStore()
	if e != nil {
		return 1, e
	}
	return 0, remote.EnrolComputerWithCode(ctx, store, a.options["code"], a.options["name"], os.Stderr)
}

func runInvite(ctx context.Context, argCount int) (int, error) {
	if argCount != 1 {
		return 2, errors.New("invite takes nothing else.")
	}
	local, e := localSetupAuthority(ctx)
	if e != nil {
		return 1, e
	}
	result, e := local.CallKeyringAuthority(ctx, &pb.AgentRequest{Request: &pb.AgentRequest_Setup{Setup: &pb.SetupRequest{Action: pb.SetupRequest_INVITE}}})
	if e != nil {
		return 1, e
	}
	if result.GetSetup() == nil {
		return 1, errors.New("Agent Keyring did not confirm setup.")
	}
	fmt.Println(result.GetSetup().GetInvite())
	return 0, nil
}

func runAuthorityCommand(ctx context.Context, command string, a cliArguments) (int, error) {
	client, connectionError := chooseAuthority(ctx)
	if connectionError != nil {
		// Usage errors remain useful on machines that have not enrolled yet.
		client.Exchange = func(context.Context, *pb.AgentRequest, func(*pb.AgentResponse) bool) error { return connectionError }
	}
	if command == "find" {
		return runFind(ctx, client, a)
	}
	id, err := a.requireOneArgument()
	if err != nil {
		return 2, err
	}
	if len(a.extra) > 0 {
		return 2, errors.New("Nothing goes after --. To give a program the password, pipe read into it.")
	}
	switch command {
	case "lease":
		return runLease(ctx, client, a, id)
	case "status":
		return runStatus(ctx, client, a, id)
	case "release":
		return runRelease(ctx, client, a, id)
	case "read":
		return runRead(ctx, client, a, id)
	}
	return 2, fmt.Errorf("Unknown command %q. Run 'agent-keyring --help'.", command)
}

func runFind(ctx context.Context, client authority.KeyringAuthorityClient, a cliArguments) (int, error) {
	if err := a.checkCommandOptions("", ""); err != nil {
		return 2, err
	}
	query, e := a.requireOneArgument()
	if e != nil {
		return 2, e
	}
	r, e := client.CallKeyringAuthority(ctx, &pb.AgentRequest{Request: &pb.AgentRequest_FindLogins{FindLogins: &pb.FindLoginsRequest{Query: query}}})
	if e != nil {
		return 1, e
	}
	if r.GetLogins() == nil {
		return 1, errors.New("Agent Keyring did not return search results.")
	}
	logins := r.GetLogins()
	if len(logins.Logins) == 0 {
		return 1, errors.New("No matching logins. Try a shorter site or account name, or import the login from Apple Passwords.")
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	if _, err := fmt.Fprintln(w, "LOGIN\tSITE\tACCOUNT\tACCESS\tCODE"); err != nil {
		return 1, err
	}
	for _, login := range logins.Logins {
		rule := map[pb.Rule]string{1: "Ask", 2: "Automatic", 3: "Blocked"}[login.Rule]
		if _, err := fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%t\n", sanitizeTerminalText(login.LoginId), sanitizeTerminalText(strings.Join(login.Sites, ", ")), sanitizeTerminalText(login.Account), rule, login.HasOneTimeCode); err != nil {
			return 1, err
		}
	}
	return 0, w.Flush()
}

func runLease(ctx context.Context, client authority.KeyringAuthorityClient, a cliArguments, id string) (int, error) {
	if err := a.checkCommandOptions("task reason request agent", "no-wait"); err != nil {
		return 2, err
	}
	if strings.TrimSpace(a.options["task"]) == "" || strings.TrimSpace(a.options["reason"]) == "" {
		return 2, errors.New("Supply --task for this job and --reason explaining why it needs the login.")
	}
	requestID := a.options["request"]
	if requestID == "" {
		requestID = receiver.GenerateOperationID()
	}
	r, e := client.CallKeyringAuthority(ctx, &pb.AgentRequest{Request: &pb.AgentRequest_RequestLease{RequestLease: &pb.RequestLeaseRequest{LoginId: id, TaskRef: a.options["task"], Reason: a.options["reason"], RequestId: requestID, AgentLabel: requesterLabel(ctx, a.options["agent"]), Project: requesterProject(ctx)}}})
	if e != nil {
		return 1, e
	}
	lease := r.GetLease()
	if lease == nil || lease.RequestId == "" {
		return 1, errors.New("Agent Keyring did not return a lease.")
	}
	if lease.GetAuthorityContext().GetTaskRef() != a.options["task"] || lease.GetAuthorityContext().GetReason() != a.options["reason"] {
		fmt.Fprintf(os.Stderr, "Joined the existing lease for task %s: %s\n", sanitizeTerminalText(lease.GetAuthorityContext().GetTaskRef()), sanitizeTerminalText(lease.GetAuthorityContext().GetReason()))
	}
	if a.flags["no-wait"] {
		if lease.State != pb.LeaseState_LEASE_STATE_APPROVED && lease.State != pb.LeaseState_LEASE_STATE_WAITING {
			return 1, leaseError(lease)
		}
		fmt.Println(lease.RequestId)
		return 0, nil
	}
	return 0, waitLease(ctx, client, lease)
}

func runStatus(ctx context.Context, client authority.KeyringAuthorityClient, a cliArguments, id string) (int, error) {
	if err := a.checkCommandOptions("", "wait"); err != nil {
		return 2, err
	}
	lease, e := client.FetchAuthorityLease(ctx, id)
	if e != nil {
		return 1, e
	}
	if a.flags["wait"] {
		return 0, waitLease(ctx, client, lease)
	}
	fmt.Printf("%s: %s\nTask: %s\n", sanitizeTerminalText(lease.RequestId), leaseOutcome(lease), sanitizeTerminalText(lease.GetAuthorityContext().GetTaskRef()))
	if lease.NotAfterUnixSeconds > 0 {
		fmt.Println("Ends:", time.Unix(lease.NotAfterUnixSeconds, 0).Local().Format(time.RFC3339))
	}
	if lease.Reply != "" {
		fmt.Println("Reply:", sanitizeTerminalText(lease.Reply))
	}
	return 0, nil
}

func runRelease(ctx context.Context, client authority.KeyringAuthorityClient, a cliArguments, id string) (int, error) {
	if err := a.checkCommandOptions("", ""); err != nil {
		return 2, err
	}
	r, e := client.CallKeyringAuthority(ctx, &pb.AgentRequest{Request: &pb.AgentRequest_EndLease{EndLease: &pb.LeaseReference{LeaseId: id}}})
	if e != nil {
		return 1, e
	}
	if r.GetLease() == nil {
		return 1, errors.New("Agent Keyring did not confirm release.")
	}
	fmt.Fprintln(os.Stderr, "Lease", leaseOutcome(r.GetLease())+".")
	return 0, nil
}

func runRead(ctx context.Context, client authority.KeyringAuthorityClient, a cliArguments, id string) (int, error) {
	if err := a.checkCommandOptions("field", ""); err != nil {
		return 2, err
	}
	field, e := receiver.ParseCredentialFieldName(a.options["field"])
	if e != nil {
		return 2, e
	}
	if isInteractiveTerminal(os.Stdout) {
		return 2, errors.New("read requires a private receiving process, not a terminal. Read 'agent-keyring skill' before using it.")
	}
	lease, e := client.FetchAuthorityLease(ctx, id)
	if e != nil {
		return 1, e
	}
	return 0, receiver.ReadDeliveredCredential(ctx, client, lease, field, os.Stdout)
}

func sanitizeTerminalText(value string) string {
	return strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return ' '
		}
		return r
	}, value)
}
func isInteractiveTerminal(file *os.File) bool {
	info, err := file.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}
func leaseState(state pb.LeaseState) string {
	switch state {
	case pb.LeaseState_LEASE_STATE_WAITING:
		return "pending"
	case pb.LeaseState_LEASE_STATE_APPROVED:
		return "active"
	case pb.LeaseState_LEASE_STATE_DENIED:
		return "denied"
	case pb.LeaseState_LEASE_STATE_EXPIRED:
		return "expired"
	case pb.LeaseState_LEASE_STATE_RELEASED:
		return "released"
	case pb.LeaseState_LEASE_STATE_ENDED:
		return "ended early"
	case pb.LeaseState_LEASE_STATE_CANCELLED:
		return "cancelled"
	case pb.LeaseState_LEASE_STATE_UNANSWERED:
		return "unanswered"
	}
	return "unknown"
}

// leaseOutcome is the state's word, and for a lease ended early, what ended
// it, in the words of whoever ended it: Josh's Stop, a rule he changed, or a
// password that left the list. Never "stopped by Josh" when he did not.
func leaseOutcome(lease *pb.Lease) string {
	if lease.State == pb.LeaseState_LEASE_STATE_ENDED {
		if lines := lease.GetAuthorityContext().GetStatusLines(); len(lines) > 0 {
			return "ended: " + strings.TrimSuffix(sanitizeTerminalText(lines[0]), ".")
		}
		if lease.EndedBy != "" {
			return "ended: The user stopped it on " + sanitizeTerminalText(lease.EndedBy)
		}
	}
	return leaseState(lease.State)
}

func leaseError(lease *pb.Lease) error {
	if lease.State == pb.LeaseState_LEASE_STATE_UNANSWERED {
		return errors.New("No answer. Nobody answered within 10 minutes. This is not a refusal. You can ask again.")
	}
	text := "This lease is " + leaseOutcome(lease) + "."
	if lease.Reply != "" {
		text += " Reply: " + sanitizeTerminalText(lease.Reply)
	}
	if lease.State == pb.LeaseState_LEASE_STATE_DENIED && lease.RetryNotBeforeUnixSeconds > 0 {
		text += " You may ask again after " + time.Unix(lease.RetryNotBeforeUnixSeconds, 0).Format("15:04:05") + "."
	}
	if lease.State == pb.LeaseState_LEASE_STATE_EXPIRED || lease.State == pb.LeaseState_LEASE_STATE_ENDED {
		text += " Request a new lease only if this task still needs the login."
	}
	return errors.New(text)
}
func waitLease(ctx context.Context, client authority.KeyringAuthorityClient, lease *pb.Lease) error {
	for lease.State == pb.LeaseState_LEASE_STATE_WAITING {
		fmt.Fprintln(os.Stderr, "Waiting for approval. Rejoin with: agent-keyring status", lease.RequestId, "--wait")
		if hint := focusHint(); hint != "" {
			fmt.Fprintln(os.Stderr, hint)
		}
		var next *pb.Lease
		err := client.StreamKeyringAuthority(ctx, &pb.AgentRequest{Request: &pb.AgentRequest_WatchLease{WatchLease: &pb.LeaseReference{LeaseId: lease.RequestId}}}, func(r *pb.AgentResponse) bool {
			next = r.GetLease()
			if next == nil {
				return false
			}
			if next.State == pb.LeaseState_LEASE_STATE_WAITING && next.PushedUnixSeconds > 0 {
				fmt.Fprintln(os.Stderr, "Apple took the notification for the user's iPhone and Apple Watch.")
			}
			for _, line := range next.GetAuthorityContext().GetStatusLines() {
				fmt.Fprintln(os.Stderr, sanitizeTerminalText(line))
			}
			return next.State == pb.LeaseState_LEASE_STATE_WAITING
		})
		if err != nil {
			return err
		}
		if next == nil {
			return errors.New("Agent Keyring did not return lease status.")
		}
		lease = next
	}
	if lease.State != pb.LeaseState_LEASE_STATE_APPROVED {
		return leaseError(lease)
	}
	fmt.Println(lease.RequestId)
	return nil
}
