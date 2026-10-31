// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"text/tabwriter"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/receiver"
	"github.com/joshp123/agent-keyring/internal/remote"
)

const help = `Agent Keyring: use a saved login for one task.

  find SITE                  Find login IDs (example.com is enough)
  lease LOGIN --task TASK --reason REASON
                             Ask once; print the lease ID when active
  status LEASE [--wait]      Inspect a lease, or wait for its decision
  fields --browser ENDPOINT [--tab TAB]
                             List page tabs, or their visible fields and selectors
  fill LEASE --browser ENDPOINT --tab TAB
       [--username CSS] [--password CSS] [--code CSS] --submit CSS
                             Fill, submit this sign-in step, clear the fields
  exec LEASE --field FIELD   Send a field to the approved program's stdin
  read LEASE --field FIELD   Deliver a value to a private process pipe
  release LEASE             End permission when the task is done
  skill                     Print the bundled agent instructions
  install                   Link the command and skills for Codex and Claude
  enrol --name NAME --relay HOST:PORT
                            Enrol this machine with your approving device

A lease ends on release or 30 minutes after approval. Reuse it through retries
and two-factor steps. Automatic logins approve without asking.

lease: --for browser (default), program or agent-process; --no-wait returns
       a pending reference; --request ID retains a caller-supplied retry ID.
       Program leases bind the command after --, resolved before approval:
       lease LOGIN --task TASK --reason REASON --for program -- client login --password-stdin
fill:  --frame ID and --document LOADER are optional preconditions.
fill/exec: --again deliberately repeats an inspected step; --operation ID is
       an explicit retry key. These two options cannot be combined.
read:  fields are username, password and one-time-code. Never run read in a
       model-visible shell call. A pipe alone does not make output private.

Lease IDs and read values go to stdout; progress and outcomes go to stderr.
Find and fields print tables. Status without --wait prints readable state.
Exit status: 0 succeeded; 1 refused, unavailable or uncertain; 2 incorrect usage.
exec returns the approved child's exit status when it exits normally.
Environment: AGENT_KEYRING_SOCKET overrides the local authority socket.
             AGENT_KEYRING_RELAY selects the enrolled relay (and supplies enrol's address).
             AGENT_KEYRING_STATE_DIR overrides this machine's private state directory.
Run any command with --help for this guide.
`

type arguments struct {
	positionals []string
	options     map[string]string
	flags       map[string]bool
	program     []string
}

func parse(args []string) (arguments, error) {
	result := arguments{options: map[string]string{}, flags: map[string]bool{}}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			result.program = args[i+1:]
			break
		}
		if !strings.HasPrefix(arg, "-") {
			result.positionals = append(result.positionals, arg)
			continue
		}
		name, value, hasValue := strings.Cut(strings.TrimPrefix(arg, "--"), "=")
		switch name {
		case "no-wait", "wait", "again":
			if hasValue {
				return result, fmt.Errorf("--%s does not take a value.", name)
			}
			result.flags[name] = true
		case "task", "reason", "for", "request", "field", "browser", "tab", "username", "password", "code", "submit", "frame", "document", "operation", "name", "relay":
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
	command := args[0]
	a, err := parse(args[1:])
	if err != nil {
		return 2, err
	}
	if command == "skill" || command == "install" {
		if len(args) != 1 {
			return 2, errors.New("This command takes no arguments.")
		}
		return 0, integration(command)
	}
	if command == "fields" {
		if err = a.check("browser tab", ""); err != nil {
			return 2, err
		}
		if len(a.positionals) > 0 || len(a.program) > 0 {
			return 2, errors.New("fields takes --browser ENDPOINT and optionally --tab TAB, without positional arguments.")
		}
		if a.options["browser"] == "" {
			return 2, errors.New("Supply --browser ENDPOINT, such as 127.0.0.1:9222.")
		}
		return 0, printFields(ctx, a.options["browser"], a.options["tab"])
	}
	if command == "enrol" {
		if err = a.check("name relay", ""); err != nil {
			return 2, err
		}
		if len(a.positionals) > 0 || len(a.program) > 0 {
			return 2, errors.New("enrol takes --name NAME and --relay HOST:PORT, without positional arguments.")
		}
		if strings.TrimSpace(a.options["name"]) == "" {
			return 2, errors.New("Give this machine a name with --name NAME.")
		}
		store, e := clientstate.Default()
		if e != nil {
			return 1, e
		}
		address := a.options["relay"]
		if address == "" {
			address = os.Getenv("AGENT_KEYRING_RELAY")
		}
		if address == "" {
			state, e := store.Load(ctx)
			if e != nil {
				return 1, e
			}
			address = state.RelayAddress
			if address == "" {
				return 2, errors.New("Supply --relay HOST:PORT to enrol this machine.")
			}
		}
		if err = remote.ValidateAddress(address); err != nil {
			return 2, err
		}
		return 0, remote.Enrol(ctx, store, address, a.options["name"], os.Stderr)
	}
	if !strings.Contains(" find lease status release read exec fill ", " "+command+" ") {
		return 2, fmt.Errorf("Unknown command %q. Run 'agent-keyring --help'.", command)
	}
	client, connectionError := chooseAuthority(ctx)
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
		if len(a.program) > 0 {
			return 2, errors.New("find takes a site, not a command.")
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
	if command != "lease" && len(a.program) > 0 {
		return 2, errors.New("Only a program lease accepts a command after --.")
	}
	switch command {
	case "lease":
		if err = a.check("task reason for request", "no-wait"); err != nil {
			return 2, err
		}
		if strings.TrimSpace(a.options["task"]) == "" || strings.TrimSpace(a.options["reason"]) == "" {
			return 2, errors.New("Supply --task for this job and --reason explaining why it needs the login.")
		}
		purpose := pb.Purpose_PURPOSE_BROWSER_SIGN_IN
		switch a.options["for"] {
		case "", "browser":
		case "program":
			purpose = pb.Purpose_PURPOSE_PROGRAM
		case "agent-process":
			purpose = pb.Purpose_PURPOSE_AGENT_PROCESS
		default:
			return 2, errors.New("Choose --for browser, program or agent-process.")
		}
		var program *pb.ProgramCommand
		if purpose == pb.Purpose_PURPOSE_PROGRAM {
			if len(a.program) == 0 {
				return 2, errors.New("A program lease needs its command after --.")
			}
			path, e := exec.LookPath(a.program[0])
			if e != nil {
				return 2, errors.New("Cannot find the program. Supply an installed executable after --.")
			}
			path, e = filepath.Abs(path)
			if e != nil {
				return 2, e
			}
			path, e = filepath.EvalSymlinks(path)
			if e != nil {
				return 2, e
			}
			program = &pb.ProgramCommand{Executable: path, Arguments: a.program[1:]}
		} else if len(a.program) > 0 {
			return 2, errors.New("A command after -- requires --for program.")
		}
		requestID := a.options["request"]
		if requestID == "" {
			requestID = receiver.NewID()
		}
		r, e := client.Call(ctx, &pb.WireRequest{Request: &pb.WireRequest_RequestLease{RequestLease: &pb.RequestLeaseRequest{LoginId: id, TaskRef: a.options["task"], Reason: a.options["reason"], Purpose: purpose, RequestId: requestID, Program: program}}})
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
		fmt.Printf("%s: %s\nTask: %s\n", safe(lease.LeaseId), leaseState(lease.State), safe(lease.TaskRef))
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
		fmt.Fprintln(os.Stderr, "Lease", leaseState(r.GetLease().State)+".")
		return 0, nil
	case "read", "exec":
		if err = a.check("field operation", "again"); err != nil {
			return 2, err
		}
		field, e := receiver.Field(a.options["field"])
		if e != nil {
			return 2, e
		}
		if command == "read" {
			if _, exists := a.options["operation"]; exists || a.flags["again"] {
				return 2, errors.New("read makes a fresh delivery on each explicit call; it takes no retry options.")
			}
			if terminal(os.Stdout) {
				return 2, errors.New("read requires a private receiving process, not a terminal. Read 'agent-keyring skill' before using it.")
			}
		}
		key, e := receiver.OperationKey(a.options["operation"], a.flags["again"])
		if e != nil {
			return 2, e
		}
		lease, e := client.Lease(ctx, id)
		if e != nil {
			return 1, e
		}
		if command == "read" {
			return 0, receiver.Read(ctx, client, lease, field, os.Stdout)
		}
		code, e := receiver.Execute(ctx, client, lease, field, key)
		if e == nil {
			fmt.Fprintln(os.Stderr, "Program exited with status", code)
		}
		return code, e
	case "fill":
		if err = a.check("browser tab username password code submit frame document operation", "again"); err != nil {
			return 2, err
		}
		if a.options["browser"] == "" || a.options["tab"] == "" || a.options["submit"] == "" {
			return 2, errors.New("fill needs --browser, --tab and --submit. Inspect the page with your browser tools first.")
		}
		key, e := receiver.OperationKey(a.options["operation"], a.flags["again"])
		if e != nil {
			return 2, e
		}
		request := &pb.FillRequest{LeaseId: id, OperationId: key, SubmitSelector: a.options["submit"], Target: &pb.Target{Kind: &pb.Target_Chromium{Chromium: &pb.ChromiumTarget{Endpoint: a.options["browser"], TargetId: a.options["tab"], FrameId: a.options["frame"], LoaderId: a.options["document"]}}}}
		for _, binding := range []struct {
			name  string
			field pb.CredentialField
		}{{"username", 1}, {"password", 2}, {"code", 3}} {
			if selector := a.options[binding.name]; selector != "" {
				request.Fields = append(request.Fields, &pb.FieldBinding{Field: binding.field, Selector: selector})
			}
		}
		if len(request.Fields) == 0 {
			return 2, errors.New("Select at least one field with --username, --password or --code.")
		}
		lease, e := client.Lease(ctx, id)
		if e != nil {
			return 1, e
		}
		result := receiver.Fill(ctx, client, lease, request)
		fmt.Fprintln(os.Stderr, result.Detail)
		if result.Outcome != pb.FillOutcome_FILL_OUTCOME_SUBMITTED {
			return 1, nil
		}
		return 0, nil
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
		return "revoked"
	case 7:
		return "cancelled"
	case 8:
		return "unanswered"
	}
	return "unknown"
}
func leaseError(lease *pb.Lease) error {
	text := "This lease is " + leaseState(lease.State) + "."
	if lease.Reply != "" {
		text += " Reply: " + safe(lease.Reply)
	}
	if lease.State == pb.LeaseState_LEASE_STATE_EXPIRED {
		text += " Request a new lease only if this task still needs the login."
	}
	return errors.New(text)
}
func waitLease(ctx context.Context, client authority.Client, lease *pb.Lease) error {
	for lease.State == pb.LeaseState_LEASE_STATE_PENDING {
		fmt.Fprintln(os.Stderr, "Waiting for approval. Rejoin with: agent-keyring status", lease.LeaseId, "--wait")
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
