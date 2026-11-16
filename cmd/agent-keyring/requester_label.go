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

// requesterLabel is a display claim, never an authorization credential.
func requesterLabel() string {
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
		name := strings.ToLower(filepath.Base(fields[1]))
		switch name {
		case "claude", "claude-code":
			return "Claude Code"
		case "codex", "codex-code-mode-host":
			return "Codex"
		}
		wrapper := name == "sh" || name == "bash" || name == "zsh" || name == "dash" || name == "fish" || name == "env" || name == "node" || strings.HasPrefix(name, "python") || name == "ruby" || name == "perl"
		if fallback == "" && wrapper && len(fields) > 3 {
			script := fields[3]
			if !strings.HasPrefix(script, "-") {
				fallback = filepath.Base(script)
			}
		}
		if fallback == "" && !wrapper {
			fallback = filepath.Base(fields[1])
		}
		pid = parent
	}
	fallback = strings.TrimSpace(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, fallback))
	if fallback == "" || fallback == "." {
		return "an agent"
	}
	if len(fallback) > 100 {
		return "an agent"
	}
	return fallback
}
