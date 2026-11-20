// Written by AI on 2026.11.16 by model gpt-6.1-terra.
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"unicode"
)

// requesterLabel names who is asking, for Josh to read: Claude Code or Codex
// found among this command's parent processes, else the name the agent gave
// with --agent, else the script or program that ran it. Processes that
// only carry a session (sshd, login, tmux, launchd) name nobody, so a request
// typed over SSH reads "an agent", never "sshd-session". A display claim,
// never an authorization credential.
func requesterLabel(given string) string {
	if os.Getenv("CLAUDECODE") == "1" {
		return "Claude Code"
	}
	pid := os.Getppid()
	fallback := ""
	for i := 0; i < 32 && pid > 1; i++ {
		out, err := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "ppid=", "-o", "comm=", "-o", "args=").Output()
		if err != nil {
			break
		}
		fields := strings.Fields(string(out))
		if len(fields) < 2 {
			break
		}
		parent, err := strconv.Atoi(fields[0])
		if err != nil {
			break
		}
		name := strings.ToLower(strings.TrimRight(filepath.Base(fields[1]), ":"))
		switch name {
		case "claude", "claude-code":
			return "Claude Code"
		case "codex", "codex-code-mode-host":
			return "Codex"
		}
		if sessionOnly(name) {
			break // Above this, nothing is the agent's.
		}
		if given != "" {
			pid = parent
			continue // Still looking for Claude Code or Codex, which beat a given name.
		}
		interpreter := name == "sh" || name == "bash" || name == "zsh" || name == "dash" || name == "fish" || name == "node" || strings.HasPrefix(name, "python") || name == "ruby" || name == "perl"
		wrapper := interpreter || name == "env"
		if fallback == "" && interpreter && len(fields) > 3 {
			script := fields[3]
			if !strings.HasPrefix(script, "-") && !strings.Contains(script, "=") && strings.ContainsAny(script, "/.") {
				fallback = filepath.Base(script)
			}
		}
		if fallback == "" && !wrapper {
			fallback = strings.TrimRight(filepath.Base(fields[1]), ":")
		}
		pid = parent
	}
	if name := cleanLabel(given); name != "" {
		return name
	}
	if name := cleanLabel(fallback); name != "" {
		return name
	}
	return "an agent"
}

// sessionOnly is a process that starts a session for a person, not an agent.
func sessionOnly(name string) bool {
	switch name {
	case "sshd", "sshd-session", "sshd-auth", "login", "launchd", "systemd", "tmux", "tmux: server", "screen", "mosh-server", "su", "sudo", "init":
		return true
	}
	return strings.HasPrefix(name, "sshd")
}

// cleanLabel drops control characters, stray punctuation and anything too long to show.
func cleanLabel(label string) string {
	label = strings.Trim(strings.TrimSpace(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, label)), ":;,. ")
	if label == "" || len(label) > 100 {
		return ""
	}
	return label
}

// requesterProject is the main folder's name of the Git repository the
// command runs in, the same for every checkout of it; empty outside one.
func requesterProject() string {
	out, err := exec.Command("git", "rev-parse", "--path-format=absolute", "--git-common-dir").Output()
	if err != nil {
		return ""
	}
	return filepath.Base(filepath.Dir(strings.TrimSpace(string(out))))
}
