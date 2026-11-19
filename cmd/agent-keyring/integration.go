// Written by AI on 2026.10.31 by model gpt-6.1-sol; managed skill folders by Claude Opus 5.5; the way back on 2026.11.19 by model claude opus 5.5.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"syscall"
	"time"

)

func contentsPath() string {
	executable, e := os.Executable()
	if e != nil {
		return ""
	}
	executable, e = filepath.EvalSymlinks(executable)
	if e != nil {
		return ""
	}
	directory := filepath.Dir(executable)
	if filepath.Base(directory) == "Helpers" && filepath.Base(filepath.Dir(directory)) == "Contents" {
		return filepath.Dir(directory)
	}
	return ""
}
func bundleID(contents string) string {
	if runtime.GOOS != "darwin" {
		return ""
	}
	data, err := exec.Command("/usr/bin/plutil", "-extract", "CFBundleIdentifier", "raw", "-o", "-", filepath.Join(contents, "Info.plist")).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}
func skillPath() (string, error) {
	if contents := contentsPath(); contents != "" {
		path := filepath.Join(contents, "Resources/AgentTools/AgentSkill/agent-keyring/SKILL.md")
		if _, err := os.Stat(path); err == nil {
			return path, nil
		}
		return "", errors.New("This app is missing its agent skill. Rebuild or update Agent Keyring with its AgentSkill resource.")
	}
	// Development binaries use the canonical source file; release bundles always
	// read their own resource, so replacing the prose never changes Go source.
	executable, _ := os.Executable()
	executable, err := filepath.EvalSymlinks(executable)
	if err != nil {
		return "", err
	}
	packaged := filepath.Join(filepath.Dir(filepath.Dir(executable)), "share/agent-keyring/skills/agent-keyring/SKILL.md")
	if _, err := os.Stat(packaged); err == nil {
		return packaged, nil
	}
	for directory := filepath.Dir(executable); directory != "/" && directory != "."; directory = filepath.Dir(directory) {
		path := filepath.Join(directory, "AgentSkill/agent-keyring/SKILL.md")
		if _, err := os.Stat(path); err == nil {
			return path, nil
		}
	}
	return "", errors.New("The bundled skill is missing. Reinstall the Agent Keyring CLI package or Mac app.")
}
func integration(command string) error {
	source, err := skillPath()
	if err != nil {
		return err
	}
	if command == "skill" {
		data, e := os.ReadFile(source)
		if e != nil {
			return e
		}
		_, e = os.Stdout.Write(data)
		return e
	}
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	executable, err = filepath.EvalSymlinks(executable)
	if err != nil {
		return err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	if err = install(home, executable, filepath.Dir(source)); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "For sign-ins, use Agent Keyring. Run `agent-keyring skill` for the workflow.")
	if os.Getenv("APP_SANDBOX_CONTAINER_ID") != "" {
		return nil // Run by the app's own button: its sandbox reaches only the agents' folders.
	}
	return installBrowserHosts()
}

// replaced is one link install changed, as it was before, so that
// 'install --undo' can put it back exactly.
type replaced struct {
	Previous  string `json:"previous,omitempty"` // The link's own text; empty if nothing was there.
	Moved     string `json:"moved,omitempty"`    // A real folder that was there, moved aside to here.
	Installed string `json:"installed"`          // What install linked it to.
}

// The record lives under HOME alone, so every harness finds the same one.
func recordPath(home string) string {
	return filepath.Join(home, ".local/state/agent-keyring/replaced-links.json")
}

func loadRecord(home string) (map[string]replaced, error) {
	record := map[string]replaced{}
	data, err := os.ReadFile(recordPath(home))
	if errors.Is(err, fs.ErrNotExist) {
		return record, nil
	}
	if err != nil {
		return nil, err
	}
	return record, json.Unmarshal(data, &record)
}

func saveRecord(home string, record map[string]replaced) error {
	if len(record) == 0 {
		err := os.Remove(recordPath(home))
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		return err
	}
	if err := os.MkdirAll(filepath.Dir(recordPath(home)), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(record, "", "  ")
	if err != nil {
		return err
	}
	temporary := recordPath(home) + ".new"
	if err = os.WriteFile(temporary, data, 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, recordPath(home))
}

func readOnly(err error) bool {
	return errors.Is(err, fs.ErrPermission) || errors.Is(err, syscall.EROFS)
}

// install links the command and the skill for this user's agents. Each link
// it changes is written down first; a link in a folder it cannot write, or
// one Nix made, is left as it is and named.
func install(home, executable, skill string) error {
	links := []struct{ source, destination string }{
		{executable, filepath.Join(home, ".local/bin/agent-keyring")},
		{skill, filepath.Join(home, ".codex/skills/agent-keyring")},
		{skill, filepath.Join(home, ".claude/skills/agent-keyring")},
	}
	if info, e := os.Lstat(links[0].destination); e == nil && info.Mode()&os.ModeSymlink == 0 {
		return fmt.Errorf("%s already exists and is not a link. Move it aside, then run install again.", links[0].destination)
	}
	record, err := loadRecord(home)
	if err != nil {
		return fmt.Errorf("Cannot read %s: %w", recordPath(home), err)
	}
	var left []string
	leave := func(destination, why, target, source string) {
		left = append(left, fmt.Sprintf("Not changed: %s. %s It still links to %s; agents that read it there keep those instructions until it links to %s.",
			destination, why, target, source))
	}
	for _, link := range links {
		if linksTo(link.destination, link.source) {
			fmt.Fprintln(os.Stderr, "Already linked:", link.destination)
			continue
		}
		previous, readErr := os.Readlink(link.destination)
		_, statErr := os.Lstat(link.destination)
		folder := statErr == nil && readErr != nil
		if readErr == nil && strings.HasPrefix(previous, "/nix/store/") {
			leave(link.destination, "Nix made it, so Nix or Home Manager manages it.", previous, link.source)
			continue
		}
		if err = os.MkdirAll(filepath.Dir(link.destination), 0o755); err != nil && !readOnly(err) {
			return err
		}
		temporary := link.destination + ".link-" + fmt.Sprint(os.Getpid())
		if err = os.Symlink(link.source, temporary); err != nil {
			if !readOnly(err) {
				return err
			}
			target := previous
			if readErr != nil {
				target = "nothing"
			}
			leave(link.destination, "Its folder is read-only, so something else, such as Nix or Home Manager, manages it.", target, link.source)
			continue
		}
		entry, known := record[link.destination]
		if !known {
			entry = replaced{Previous: previous}
			if folder { // Kept beside it.
				entry.Moved = link.destination + ".previous-" + time.Now().Format("20060102-150405.000000000")
			}
		}
		entry.Installed = link.source
		record[link.destination] = entry
		if err = saveRecord(home, record); err != nil {
			os.Remove(temporary)
			return err
		}
		if folder {
			if err = os.Rename(link.destination, entry.Moved); err != nil {
				os.Remove(temporary)
				return err
			}
			fmt.Fprintln(os.Stderr, "Moved the folder that was there to", entry.Moved)
		}
		if err = os.Rename(temporary, link.destination); err != nil {
			return err
		}
		fmt.Fprintln(os.Stderr, "Linked:", link.destination)
	}
	for _, line := range left {
		fmt.Fprintln(os.Stderr, line)
	}
	if len(record) > 0 {
		fmt.Fprintf(os.Stderr, "To put back the links this replaced, run: %q install --undo\n", executable)
	}
	return nil
}

// undoInstall puts back every link install replaced, as it was, if it still
// points where install put it.
func undoInstall() error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	record, err := loadRecord(home)
	if err != nil {
		return fmt.Errorf("Cannot read %s: %w", recordPath(home), err)
	}
	if len(record) == 0 {
		return errors.New("Nothing to undo: install has not replaced any links for this user.")
	}
	destinations := make([]string, 0, len(record))
	for destination := range record {
		destinations = append(destinations, destination)
	}
	sort.Strings(destinations)
	for _, destination := range destinations {
		entry := record[destination]
		if current, e := os.Readlink(destination); e != nil || current != entry.Installed {
			fmt.Fprintln(os.Stderr, "Left as it is, because it changed after install:", destination)
			continue
		}
		var done string
		switch {
		case entry.Moved != "":
			if err = os.Remove(destination); err == nil {
				err = os.Rename(entry.Moved, destination)
			}
			done = "Put back the folder that was at " + destination
		case entry.Previous != "":
			temporary := destination + ".link-" + fmt.Sprint(os.Getpid())
			if err = os.Symlink(entry.Previous, temporary); err == nil {
				err = os.Rename(temporary, destination)
			}
			done = "Put back: " + destination + " -> " + entry.Previous
		default:
			err = os.Remove(destination)
			done = "Removed, as nothing was there before install: " + destination
		}
		if err != nil {
			return err
		}
		fmt.Fprintln(os.Stderr, done)
	}
	return saveRecord(home, nil)
}

// A configuration such as Home Manager may already provide the link, in a
// folder this command cannot write.
func linksTo(link, target string) bool {
	resolved, err := filepath.EvalSymlinks(link)
	if err != nil {
		return false
	}
	wanted, err := filepath.EvalSymlinks(target)
	return err == nil && resolved == wanted
}

func startApp(ctx context.Context, contents string) error {
	if runtime.GOOS != "darwin" {
		return errors.New("This saved authority is a Mac app. Enrol this machine with your relay instead.")
	}
	application := filepath.Dir(contents)
	if _, err := os.Stat(application); err != nil {
		return errors.New("Agent Keyring is not installed. Install the Mac app before requesting logins.")
	}
	if err := exec.CommandContext(ctx, "/usr/bin/open", "-g", application).Run(); err != nil {
		return errors.New("Could not start Agent Keyring. Open the app, then try this command again.")
	}
	return nil
}
