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

	v2 "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/remote"
)

// complaints is the one switch for complain and complaints: "on" in Josh's
// own builds, where an agent's trouble is debugging for whoever builds the
// product; a public build sets it "off" with
// -ldflags '-X main.complaints=off'.
var complaints = "on"

// stamp is the version and build number every product of one commit shares,
// "0.5.0 (202611210311)", set at build (script/version.sh, nix/cli.nix).
var stamp string

// version is the command's own build: its stamp, else what Go recorded.
func version() string {
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

func complainClient(ctx context.Context) (*remote.Client, error) {
	if complaints != "on" {
		return nil, errors.New("Complaints are off in this build of Agent Keyring.")
	}
	store, err := clientstate.Default()
	if err != nil {
		return nil, err
	}
	client, err := remote.Load(ctx, store)
	if err != nil {
		return nil, fmt.Errorf("Complaints go to the Mac from a computer that joined it; on the Mac itself the app takes them. %w", err)
	}
	return client, nil
}

// complain files what was annoying, confusing or broken about Agent Keyring,
// for whoever builds it. Never a password or any secret.
func complain(ctx context.Context, a arguments) (int, error) {
	if err := a.check("summary command thread", ""); err != nil || len(a.positionals) > 0 || len(a.extra) > 0 || strings.TrimSpace(a.options["summary"]) == "" {
		return 2, errors.New("complain takes --summary \"one line\", and --command and --thread if you have them; more detail on standard input.")
	}
	client, err := complainClient(ctx)
	if err != nil {
		return 1, err
	}
	var detail []byte
	if !terminal(os.Stdin) {
		if detail, err = io.ReadAll(io.LimitReader(os.Stdin, 16<<10)); err != nil {
			return 1, err
		}
	}
	sent, err := client.Complain(ctx, &v2.Complaint{AtUnixSeconds: time.Now().Unix(), Version: version(), Command: a.options["command"],
		Thread: a.options["thread"], Summary: a.options["summary"], Detail: string(detail)})
	if err != nil {
		return 1, err
	}
	if sent {
		fmt.Fprintln(os.Stderr, "Complaint sent to the Mac. Thank you; carry on with your task.")
	} else {
		fmt.Fprintln(os.Stderr, "The Mac cannot be reached now, so the complaint is kept here and goes to the Mac at the next contact. Carry on with your task.")
	}
	return 0, nil
}

// listComplaints prints what agents have complained about, from the Mac.
func listComplaints(ctx context.Context, a arguments) (int, error) {
	if err := a.check("since", ""); err != nil || len(a.positionals) > 0 || len(a.extra) > 0 {
		return 2, errors.New("complaints takes --since DURATION, such as 24h (the default).")
	}
	window, err := 24*time.Hour, error(nil)
	if text := a.options["since"]; text != "" {
		if window, err = time.ParseDuration(text); err != nil || window <= 0 {
			return 2, errors.New("--since takes a duration such as 30m or 24h.")
		}
	}
	client, err := complainClient(ctx)
	if err != nil {
		return 1, err
	}
	found, err := client.Complaints(ctx, time.Now().Add(-window).Unix())
	if err != nil {
		return 1, err
	}
	if len(found) == 0 {
		fmt.Fprintln(os.Stderr, "No complaints in that time.")
	}
	for _, c := range found {
		fmt.Printf("%s  %s  %s  %s\n", time.Unix(c.AtUnixSeconds, 0).Format(time.RFC3339), safe(c.Computer), safe(c.Version), safe(c.Summary))
		for _, line := range []string{"command: " + c.Command, "thread: " + c.Thread} {
			if !strings.HasSuffix(line, ": ") {
				fmt.Println("    " + safe(line))
			}
		}
		for _, line := range strings.Split(strings.TrimSpace(c.Detail), "\n") {
			if line != "" {
				fmt.Println("    " + safe(line))
			}
		}
	}
	return 0, nil
}
