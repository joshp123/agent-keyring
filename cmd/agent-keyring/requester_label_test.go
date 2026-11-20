// Written by AI on 2026.11.20 by model claude opus 5.5.
package main

import "testing"

// A request typed over SSH reached Josh as "sshd-session: on Mac mini wants".
// The name an agent gives wins; a session program names nobody; stray
// punctuation goes.
func TestWhoIsAskingIsAPersonsWordNotASessionProgram(t *testing.T) {
	if got := requesterLabel("  Claude Code "); got != "Claude Code" {
		t.Fatalf("the agent's own name gave %q", got)
	}
	for _, name := range []string{"sshd-session", "sshd", "login", "tmux", "mosh-server"} {
		if !sessionOnly(name) {
			t.Fatalf("%s was taken for the agent", name)
		}
	}
	if got := cleanLabel("sshd-session:"); got != "sshd-session" {
		t.Fatalf("stray colon kept: %q", got)
	}
	if got := requesterLabel(""); got == "" || got == "sshd-session" {
		t.Fatalf("no name for who is asking: %q", got)
	}
}
