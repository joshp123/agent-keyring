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

	agentskill "github.com/joshp123/agent-keyring/AgentSkill"
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
func integration(command string) error {
	if command == "skill" {
		_, err := os.Stdout.WriteString(agentskill.Text)
		return err
	}
	// Agent Keyring no longer changes anyone's links or settings: an agent is
	// told where the command is and runs it from there.
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	if executable, err = filepath.EvalSymlinks(executable); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "Agent Keyring no longer links itself into your folders. Run it from where it is:\n  %q\n"+
		"and read the instructions with: %q skill\n", executable, executable)
	return nil
}

// replaced is one link an earlier `install` changed, as it was before, so
// that 'install --undo' can still put it back exactly.
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

// undoInstall puts back every link an earlier install replaced, as it was,
// if it still points where install put it.
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
