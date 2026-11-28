// Written by AI on 2026.11.20 by model claude opus 5.5.
package main

import (
	"strings"
	"testing"
)

// A request typed over SSH must show the agent's name, never the session program.
func TestWhoIsAskingIsAPersonsWordNotASessionProgram(t *testing.T) {
	for _, test := range []struct {
		name, given, want string
		parents           map[int]string
	}{
		{"explicit name", "  Claude Code ", "Claude Code", map[int]string{3: "2 sshd-session:"}},
		{"SSH without a name", "", "an agent", map[int]string{3: "2 sshd-session:"}},
		{"detected agent wins", "Other", "Codex", map[int]string{3: "2 sh sh", 2: "1 codex codex"}},
		{"script name", "", "request.py", map[int]string{3: "2 python3 python3 ./request.py", 2: "1 sshd:"}},
	} {
		t.Run(test.name, func(t *testing.T) {
			got := labelFromParents(test.given, 3, func(pid int) []string {
				return strings.Fields(test.parents[pid])
			})
			if got != test.want {
				t.Errorf("requester label = %q, want %q", got, test.want)
			}
		})
	}
	for _, name := range []string{"sshd-session", "sshd", "login", "tmux", "mosh-server"} {
		if !sessionOnly(name) {
			t.Errorf("%s was taken for the agent", name)
		}
	}
	if got := cleanLabel("sshd-session:"); got != "sshd-session" {
		t.Errorf("stray colon kept: %q", got)
	}
}
