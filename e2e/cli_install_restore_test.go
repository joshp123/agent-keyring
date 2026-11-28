// Written by AI on 2026.11.18 by model claude opus 5.5.
// Fixture factored on 2026.11.27 by model gpt-6.2-sol.
package e2e

import (
	"context"
	"encoding/json"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// An earlier install recorded the links it changed. Install leaves these links
// alone, while install --undo still restores them.
func TestLinksAnEarlierInstallChangedStayHisToPutBack(t *testing.T) {
	home, executable, original, installed := earlierInstall(t)
	agent := func(args ...string) cliProcessResult {
		ctx, cancel := context.WithCancel(t.Context())
		defer cancel()
		command := exec.CommandContext(ctx, executable, args...)
		command.Env = append(os.Environ(), "HOME="+home, "XDG_STATE_HOME=", "XDG_CONFIG_HOME=", "AGENT_KEYRING_STATE_DIR=", "CODEX_HOME=")
		return waitForCapturedCommand(t, startCapturedCommand(command), strings.Join(args, " "))
	}
	got := agent("install")
	assertSuccess(t, got)
	if !strings.Contains(got.stderr, "no longer links itself") || !strings.Contains(got.stderr, "skill") {
		t.Fatalf("install: %s", got.stderr)
	}
	assertLinks(t, installed)
	assertSuccess(t, agent("install", "--undo"))
	assertLinks(t, original)
	assertRefused(t, agent("install", "--undo"), "Nothing to undo")
}

func earlierInstall(t *testing.T) (string, string, map[string]string, map[string]string) {
	t.Helper()
	scratch := t.TempDir()
	home := filepath.Join(scratch, "home")
	app := filepath.Join(scratch, "Applications/Agent Keyring.app/Contents")
	old := filepath.Join(scratch, "Applications/AgentKeyring.app/Contents")
	const skills = "/Resources/AgentTools/"
	const helper = "/Helpers/agent-keyring"
	executable := app + helper
	command, err := os.ReadFile(bin.command)
	if err != nil {
		t.Fatal(err)
	}
	writeInstallFixture(t, executable, command, 0755)
	writeInstallFixture(t, app+skills+"AgentSkill/agent-keyring/SKILL.md", []byte("new skill\n"), 0600)
	writeInstallFixture(t, app+skills+"BrowserExtension/manifest.json", []byte("{}\n"), 0600)
	writeInstallFixture(t, old+skills+"CodexSkill/agent-keyring/SKILL.md", []byte("0.2.5 skill\n"), 0600)
	writeInstallFixture(t, old+helper, []byte("#!/bin/sh\nexit 0\n"), 0755)
	original := map[string]string{
		home + "/.local/bin/agent-keyring":     old + helper,
		home + "/.codex/skills/agent-keyring":  old + skills + "CodexSkill/agent-keyring",
		home + "/.claude/skills/agent-keyring": old + skills + "CodexSkill/agent-keyring",
	}
	installed := maps.Clone(original)
	installed[home+"/.local/bin/agent-keyring"] = resolveFixtureLink(t, executable)
	installed[home+"/.codex/skills/agent-keyring"] = resolveFixtureLink(t, app+skills+"AgentSkill/agent-keyring")
	recordEarlierInstall(t, home, installed, original)
	return home, executable, original, installed
}

func recordEarlierInstall(t *testing.T, home string, installed, original map[string]string) {
	t.Helper()
	record := map[string]map[string]string{}
	for link, target := range installed {
		if err := os.MkdirAll(filepath.Dir(link), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, link); err != nil {
			t.Fatal(err)
		}
		if original[link] != target {
			record[link] = map[string]string{"previous": original[link], "installed": target}
		}
	}
	dir := home + "/.claude/skills"
	if err := os.Chmod(dir, 0555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.Chmod(dir, 0755); err != nil {
			t.Error(err)
		}
	})
	recorded, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	writeInstallFixture(t, home+"/.local/state/agent-keyring/replaced-links.json", recorded, 0600)
}

func resolveFixtureLink(t *testing.T, path string) string {
	t.Helper()
	found, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	return found
}

func writeInstallFixture(t *testing.T, path string, data []byte, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, mode); err != nil {
		t.Fatal(err)
	}
}

func assertLinks(t *testing.T, expected map[string]string) {
	t.Helper()
	for link, target := range expected {
		if got, err := os.Readlink(link); err != nil || got != target {
			t.Errorf("%s links to %q, want %q: %v", link, got, target, err)
		}
	}
}
