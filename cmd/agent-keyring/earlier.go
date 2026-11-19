// Written by AI on 2026.11.19 by model claude opus 5.5.
package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
)

const changed = "Agent Keyring has changed since your instructions were written. Run `agent-keyring skill` and follow it."

var reference = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`)

// earlier answers the commands of version 0.2.5's instructions, which agents
// that started before install keep using. Its read and clear go to the
// command install replaced: they use a value already in that version's
// buffer, and clear removes it. Everything else asks the agent to reread
// its instructions.
func earlier(args []string) (code int, handled bool, err error) {
	command, rest := args[0], args[1:]
	field := false
	for _, arg := range rest {
		if arg == "--" {
			break
		}
		name, _, _ := strings.Cut(arg, "=")
		switch name {
		case "--account", "--credential", "--expires":
			return 2, true, errors.New(changed)
		case "--field":
			field = true
		}
	}
	switch {
	case command == "acquire" || command == "copy" || (command == "status" && len(rest) == 0):
		return 2, true, errors.New(changed)
	case command == "clear" || (command == "read" && !field && len(rest) == 1 && reference.MatchString(rest[0])):
		if len(rest) == 1 && reference.MatchString(rest[0]) {
			if previous := replacedCommand(); previous != "" {
				fmt.Fprintln(os.Stderr, "Agent Keyring has changed since your instructions were written. This "+command+" uses the earlier version, for the value you already have; for anything else, run `agent-keyring skill` and follow it.")
				return 1, true, syscall.Exec(previous, append([]string{previous}, args...), os.Environ())
			}
		}
		return 2, true, errors.New(changed)
	}
	return 0, false, nil
}

// replacedCommand is the command ~/.local/bin/agent-keyring pointed to before
// install, if it still exists and is not this one.
func replacedCommand() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	record, err := loadRecord(home)
	link := filepath.Join(home, ".local/bin/agent-keyring")
	if err != nil || record[link].Previous == "" {
		return ""
	}
	previous := record[link].Previous
	if !filepath.IsAbs(previous) {
		previous = filepath.Join(filepath.Dir(link), previous)
	}
	resolved, err := filepath.EvalSymlinks(previous)
	if err != nil {
		return ""
	}
	self, err := os.Executable()
	if err != nil {
		return ""
	}
	if self, err = filepath.EvalSymlinks(self); err != nil || self == resolved {
		return ""
	}
	return resolved
}
