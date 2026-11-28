// Written by AI on 2026.11.21 by model claude opus 5.5.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"runtime/debug"
	"strings"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"github.com/opentrawl/agent-keyring/internal/remote"
)

// complaints is the one switch for complain and complaints: "on" in Josh's
// own builds, where an agent's trouble is debugging for whoever builds the
// product; a public build sets it "off" with
// -ldflags '-X main.complaints=off'.
var complaints = "on"

// stamp is the version and build number every product of one commit shares,
// "0.5.0 (202611210311)", set at build (script/version.sh, nix/cli.nix).
var stamp string

// keyringBuildVersion is the command's own build: its stamp, else what Go recorded.
func keyringBuildVersion() string {
	if stamp != "" {
		return stamp
	}
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "unknown"
	}
	text := info.Main.Version
	for _, setting := range info.Settings {
		if setting.Key == "vcs.revision" && len(setting.Value) >= 12 {
			text += " " + setting.Value[:12]
		}
		if setting.Key == "vcs.modified" && setting.Value == "true" {
			text += "+changes"
		}
	}
	return text
}

func loadComplaintClient(ctx context.Context) (*remote.RemoteKeyringClient, error) {
	if complaints != "on" {
		return nil, errors.New("Complaints are off in this build of Agent Keyring.")
	}
	store, err := clientstate.DefaultClientStateStore()
	if err != nil {
		return nil, err
	}
	client, err := remote.LoadRemoteKeyringClient(ctx, store)
	if err != nil {
		return nil, fmt.Errorf("Complaints are kept on a computer that joined the user's devices; on the Mac itself the app keeps them. %w", err)
	}
	return client, nil
}

// runComplaintCommand records what was annoying, confusing or broken about Agent Keyring
// on this computer, for whoever builds it. Never a password or any secret.
func runComplaintCommand(ctx context.Context, a cliArguments) (int, error) {
	if err := a.checkCommandOptions("summary command thread", ""); err != nil || len(a.positionals) > 0 || len(a.extra) > 0 || strings.TrimSpace(a.options["summary"]) == "" {
		return 2, errors.New("complain takes --summary \"one line\", and --command and --thread if you have them; more detail on standard input.")
	}
	client, err := loadComplaintClient(ctx)
	if err != nil {
		return 1, err
	}
	var detail []byte
	if !isInteractiveTerminal(os.Stdin) {
		if detail, err = io.ReadAll(io.LimitReader(os.Stdin, 16<<10)); err != nil {
			return 1, err
		}
	}
	if err := client.RecordRemoteComplaint(ctx, &pb.Complaint{AtUnixSeconds: time.Now().Unix(), Version: keyringBuildVersion(), Command: a.options["command"],
		Thread: a.options["thread"], Summary: a.options["summary"], Detail: string(detail)}); err != nil {
		return 1, err
	}
	fmt.Fprintln(os.Stderr, "Kept on this computer. Thank you; carry on with your task.")
	return 0, nil
}

// listComplaints prints what agents on this computer have complained about.
func listComplaints(ctx context.Context, a cliArguments) (int, error) {
	if err := a.checkCommandOptions("since", ""); err != nil || len(a.positionals) > 0 || len(a.extra) > 0 {
		return 2, errors.New("complaints takes --since DURATION, such as 24h (the default).")
	}
	window, err := 24*time.Hour, error(nil)
	if text := a.options["since"]; text != "" {
		if window, err = time.ParseDuration(text); err != nil || window <= 0 {
			return 2, errors.New("--since takes a duration such as 30m or 24h.")
		}
	}
	client, err := loadComplaintClient(ctx)
	if err != nil {
		return 1, err
	}
	found, err := client.ReadRemoteComplaints(ctx, time.Now().Add(-window).Unix())
	if err != nil {
		return 1, err
	}
	if len(found) == 0 {
		fmt.Fprintln(os.Stderr, "No complaints in that time.")
	}
	for _, c := range found {
		fmt.Printf("%s  %s  %s  %s\n", time.Unix(c.AtUnixSeconds, 0).Format(time.RFC3339), sanitizeTerminalText(c.Computer), sanitizeTerminalText(c.Version), sanitizeTerminalText(c.Summary))
		for _, line := range []string{"command: " + c.Command, "thread: " + c.Thread} {
			if !strings.HasSuffix(line, ": ") {
				fmt.Println("    " + sanitizeTerminalText(line))
			}
		}
		for _, line := range strings.Split(strings.TrimSpace(c.Detail), "\n") {
			if line != "" {
				fmt.Println("    " + sanitizeTerminalText(line))
			}
		}
	}
	return 0, nil
}
