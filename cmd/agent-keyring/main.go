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

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/browserbridge"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/receiver"
	"github.com/joshp123/agent-keyring/internal/remote"
)

const help = `Agent Keyring: use a saved login for one task.

  find SITE                  Find login IDs (example.com is enough)
  lease LOGIN --task TASK --reason REASON [--agent NAME]
                             Ask once; print the lease ID when active. NAME is
                             who Josh sees asking, such as Claude Code
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
                            Never include a password or secret
  complaints [--since 24h]  Read agents' complaints, from the Mac
  machines                  List the computers on this Tailscale network
  enrol --name NAME --invite LINK
                            Join this computer, with a link from 'invite' on the Mac
  invite                    On the Mac: print a one-time link for one computer to join
  push-key --key-id ID --team-id ID < AuthKey_ID.p8
                            On the Mac: give the app Apple's push key
  logs [--since 30m] [--request ID]
                            What this computer, the Mac, the iPhone and the Apple
                            Watch did and why, in time order; no secrets

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
Run any command with --help for this guide.
`

type arguments struct {
	positionals []string
	options     map[string]string
	flags       map[string]bool
	extra       []string
}

func parse(args []string) (arguments, error) {
	result := arguments{options: map[string]string{}, flags: map[string]bool{}}
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
		case "task", "reason", "agent", "request", "since", "field", "tab", "username", "password", "code", "submit", "operation", "name", "invite", "browser-profile",
			"key-id", "team-id", "summary", "command", "thread":
			if _, exists := result.options[name]; exists {
				return result, fmt.Errorf("Use --%s only once.", name)
			}
			if !hasValue {
				i++
				if i >= len(args) || strings.HasPrefix(args[i], "--") {
					return result, fmt.Errorf("--%s needs a value.", name)
				}
				value = args[i]
			}
			if value == "" {
				return result, fmt.Errorf("--%s needs a value.", name)
			}
			result.options[name] = value
		default:
			return result, fmt.Errorf("Unknown option %s. Run 'agent-keyring --help'.", arg)
		}
	}
	return result, nil
}
func (a arguments) check(options, flags string) error {
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
func (a arguments) one() (string, error) {
	if len(a.positionals) != 1 {
		return "", errors.New("Supply exactly one login or lease ID. Run 'agent-keyring --help'.")
	}
	return a.positionals[0], nil
}
func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()
	code, err := run(ctx, os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "agent-keyring:", err)
		if code == 0 {
			code = 1
		}
	}
	os.Exit(code)
}
func run(ctx context.Context, args []string) (int, error) {
	if len(args) > 0 && strings.HasPrefix(args[0], "chrome-extension://") {
		return 0, browserbridge.Native(ctx, args[0], chooseAuthority)
	}
	if len(args) == 0 || args[0] == "help" {
		fmt.Print(help)
		return 0, nil
	}
	for _, arg := range args {
		if arg == "--help" || arg == "-h" {
			fmt.Print(help)
			return 0, nil
		}
		if arg == "--" {
			break
		}
	}
	if code, handled, err := earlier(args); handled {
		return code, err
	}
	command := args[0]
	a, err := parse(args[1:])
	if err != nil {
		return 2, err
	}
	if command == "skill" || command == "install" {
		if command == "install" && a.options["browser-profile"] != "" {
			if err = a.check("browser-profile", ""); err != nil || len(a.positionals) > 0 || len(a.extra) > 0 {
				return 2, errors.New("install --browser-profile takes only the browser's user-data directory.")
			}
			return 0, installNativeHost(a.options["browser-profile"])
		}
		if command == "install" && a.flags["undo"] {
			if len(args) != 2 {
				return 2, errors.New("install --undo takes nothing else.")
			}
			return 0, undoInstall()
		}
		if len(args) != 1 {
			return 2, errors.New("This command takes no arguments.")
		}
		return 0, integration(command)
	}
	if command == "machines" {
		if len(args) != 1 {
			return 2, errors.New("This command takes no arguments.")
		}
		if err = machines(); err != nil {
			return 1, err
		}
		return 0, nil
	}
	if command == "logs" {
		if err = a.check("since request", ""); err != nil || len(a.positionals) != 0 || len(a.extra) != 0 {
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
			fmt.Println(safe(line))
		}
		if e == nil && len(lines) == 0 {
			fmt.Fprintln(os.Stderr, "No log lines match.")
		}
		if e != nil {
			return 1, e
		}
		return 0, nil
	}
	if code, handled, e := onMac(ctx, command, a); handled {
		return code, e
	}
	if command == "complain" {
		return complain(ctx, a)
	}
	if command == "complaints" {
		return listComplaints(ctx, a)
	}
	if command == "tabs" || command == "fields" {
		return inspectBrowser(ctx, command, a)
	}
	if command == "fill" {
		return fillBrowser(ctx, a)
	}
	if command == "enrol" {
		if err = a.check("name invite", ""); err != nil {
			return 2, err
		}
		if len(a.positionals) > 0 || len(a.extra) > 0 || strings.TrimSpace(a.options["name"]) == "" || a.options["invite"] == "" {
			return 2, errors.New("enrol takes --name NAME and --invite LINK, the link 'agent-keyring invite' printed on the Mac.")
		}
		invite, e := remote.ParseInvite(a.options["invite"])
		if e != nil {
			return 2, e
		}
		store, e := clientstate.Default()
		if e != nil {
			return 1, e
		}
		return 0, remote.Enrol(ctx, store, invite, a.options["name"], os.Stderr)
	}
	if command == "invite" {
		if len(args) != 1 {
			return 2, errors.New("invite takes nothing else.")
		}
		local, e := localSetupAuthority(ctx)
		if e != nil {
			return 1, e
		}
		result, e := local.Call(ctx, &pb.WireRequest{Request: &pb.WireRequest_Setup{Setup: &pb.SetupRequest{Action: pb.SetupRequest_INVITE}}})
		if e != nil {
			return 1, e
		}
		if result.GetSetup() == nil {
			return 1, errors.New("Agent Keyring did not confirm setup.")
		}
		fmt.Println(result.GetSetup().GetInvite())
		return 0, nil
	}
	if !strings.Contains(" find lease status release read ", " "+command+" ") {
		return 2, fmt.Errorf("Unknown command %q. Run 'agent-keyring --help'.", command)
	}
	client, connectionError := chooseAuthority(ctx)
	defer remote.Close() // Lets this computer's door go once any answer being taken is saved.
	if connectionError != nil {
		// Usage errors remain useful on machines that have not enrolled yet.
		client.Exchange = func(context.Context, *pb.WireRequest, func(*pb.WireResponse) bool) error { return connectionError }
	}
	if command == "find" {
		if err = a.check("", ""); err != nil {
			return 2, err
		}
		query, e := a.one()
		if e != nil {
			return 2, e
		}
		r, e := client.Call(ctx, &pb.WireRequest{Request: &pb.WireRequest_FindLogins{FindLogins: &pb.FindLoginsRequest{Query: query}}})
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
		fmt.Fprintln(w, "LOGIN\tSITE\tACCOUNT\tACCESS\tCODE")
		for _, login := range logins.Logins {
			rule := map[pb.AccessRule]string{1: "Ask", 2: "Automatic", 3: "Blocked"}[login.Rule]
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%t\n", safe(login.LoginId), safe(strings.Join(login.Sites, ", ")), safe(login.Account), rule, login.HasOneTimeCode)
		}
		w.Flush()
		return 0, nil
	}
	id, err := a.one()
	if err != nil {
		return 2, err
	}
	if len(a.extra) > 0 {
		return 2, errors.New("Nothing goes after --. To give a program the password, pipe read into it.")
	}
	switch command {
	case "lease":
		if err = a.check("task reason request agent", "no-wait"); err != nil {
			return 2, err
		}
		if strings.TrimSpace(a.options["task"]) == "" || strings.TrimSpace(a.options["reason"]) == "" {
			return 2, errors.New("Supply --task for this job and --reason explaining why it needs the login.")
		}
		requestID := a.options["request"]
		if requestID == "" {
			requestID = receiver.NewID()
		}
		r, e := client.Call(ctx, &pb.WireRequest{Request: &pb.WireRequest_RequestLease{RequestLease: &pb.RequestLeaseRequest{LoginId: id, TaskRef: a.options["task"], Reason: a.options["reason"], RequestId: requestID, AgentLabel: requesterLabel(a.options["agent"]), Project: requesterProject()}}})
		if e != nil {
			return 1, e
		}
		lease := r.GetLease()
		if lease == nil || lease.LeaseId == "" {
			return 1, errors.New("Agent Keyring did not return a lease.")
		}
		if lease.TaskRef != a.options["task"] || lease.Reason != a.options["reason"] {
			fmt.Fprintf(os.Stderr, "Joined the existing lease for task %s: %s\n", safe(lease.TaskRef), safe(lease.Reason))
		}
		if a.flags["no-wait"] {
			if lease.State != pb.LeaseState_LEASE_STATE_ACTIVE && lease.State != pb.LeaseState_LEASE_STATE_PENDING {
				return 1, leaseError(lease)
			}
			fmt.Println(lease.LeaseId)
			return 0, nil
		}
		return 0, waitLease(ctx, client, lease)
	case "status":
		if err = a.check("", "wait"); err != nil {
			return 2, err
		}
		lease, e := client.Lease(ctx, id)
		if e != nil {
			return 1, e
		}
		if a.flags["wait"] {
			return 0, waitLease(ctx, client, lease)
		}
		fmt.Printf("%s: %s\nTask: %s\n", safe(lease.LeaseId), leaseOutcome(lease), safe(lease.TaskRef))
		if lease.NotAfterUnixSeconds > 0 {
			fmt.Println("Ends:", time.Unix(lease.NotAfterUnixSeconds, 0).Local().Format(time.RFC3339))
		}
		if lease.Reply != "" {
			fmt.Println("Reply:", safe(lease.Reply))
		}
		return 0, nil
	case "release":
		if err = a.check("", ""); err != nil {
			return 2, err
		}
		r, e := client.Call(ctx, &pb.WireRequest{Request: &pb.WireRequest_EndLease{EndLease: &pb.LeaseReference{LeaseId: id}}})
		if e != nil {
			return 1, e
		}
		if r.GetLease() == nil {
			return 1, errors.New("Agent Keyring did not confirm release.")
		}
		fmt.Fprintln(os.Stderr, "Lease", leaseOutcome(r.GetLease())+".")
		return 0, nil
	case "read":
		if err = a.check("field", ""); err != nil {
			return 2, err
		}
		field, e := receiver.Field(a.options["field"])
		if e != nil {
			return 2, e
		}
		if terminal(os.Stdout) {
			return 2, errors.New("read requires a private receiving process, not a terminal. Read 'agent-keyring skill' before using it.")
		}
		lease, e := client.Lease(ctx, id)
		if e != nil {
			return 1, e
		}
		return 0, receiver.Read(ctx, client, lease, field, os.Stdout)
	default:
		return 2, fmt.Errorf("Unknown command %q. Run 'agent-keyring --help'.", command)
	}
}
func safe(value string) string {
	return strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return ' '
		}
		return r
	}, value)
}
func terminal(file *os.File) bool {
	info, err := file.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}
func leaseState(state pb.LeaseState) string {
	switch state {
	case 1:
		return "pending"
	case 2:
		return "active"
	case 3:
		return "denied"
	case 4:
		return "expired"
	case 5:
		return "released"
	case 6:
		return "ended early"
	case 7:
		return "cancelled"
	case 8:
		return "unanswered"
	}
	return "unknown"
}
// leaseOutcome is the state's word, and for a lease ended early, what ended
// it, in the words of whoever ended it: Josh's Stop, a rule he changed, or a
// password that left the list. Never "stopped by Josh" when he did not.
func leaseOutcome(lease *pb.Lease) string {
	if lease.State == pb.LeaseState_LEASE_STATE_REVOKED && len(lease.StatusLines) > 0 {
		return "ended: " + strings.TrimSuffix(safe(lease.StatusLines[0]), ".")
	}
	return leaseState(lease.State)
}

func leaseError(lease *pb.Lease) error {
	if lease.State == pb.LeaseState_LEASE_STATE_UNANSWERED {
		return errors.New("No answer. Nobody answered within 10 minutes. This is not a refusal. You can ask again.")
	}
	text := "This lease is " + leaseOutcome(lease) + "."
	if lease.Reply != "" {
		text += " Reply: " + safe(lease.Reply)
	}
	if lease.State == pb.LeaseState_LEASE_STATE_DENIED && lease.RetryNotBeforeUnixSeconds > 0 {
		text += " You may ask again after " + time.Unix(lease.RetryNotBeforeUnixSeconds, 0).Format("15:04:05") + "."
	}
	if lease.State == pb.LeaseState_LEASE_STATE_EXPIRED || lease.State == pb.LeaseState_LEASE_STATE_REVOKED {
		text += " Request a new lease only if this task still needs the login."
	}
	return errors.New(text)
}
func waitLease(ctx context.Context, client authority.Client, lease *pb.Lease) error {
	for lease.State == pb.LeaseState_LEASE_STATE_PENDING {
		fmt.Fprintln(os.Stderr, "Waiting for approval. Rejoin with: agent-keyring status", lease.LeaseId, "--wait")
		if hint := focusHint(); hint != "" {
			fmt.Fprintln(os.Stderr, hint)
		}
		var next *pb.Lease
		err := client.Stream(ctx, &pb.WireRequest{Request: &pb.WireRequest_WatchLease{WatchLease: &pb.LeaseReference{LeaseId: lease.LeaseId}}}, func(r *pb.WireResponse) bool {
			next = r.GetLease()
			if next == nil {
				return false
			}
			for _, line := range next.StatusLines {
				fmt.Fprintln(os.Stderr, safe(line))
			}
			return next.State == pb.LeaseState_LEASE_STATE_PENDING
		})
		if err != nil {
			return err
		}
		if next == nil {
			return errors.New("Agent Keyring did not return lease status.")
		}
		lease = next
	}
	if lease.State != pb.LeaseState_LEASE_STATE_ACTIVE {
		return leaseError(lease)
	}
	fmt.Println(lease.LeaseId)
	return nil
}
