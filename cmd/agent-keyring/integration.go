// Written by AI on 2026.10.31 by model gpt-6.1-sol; managed skill folders by Claude Opus 5.5.
package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
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
	destinations := []struct {
		source, destination string
		preserve            bool
	}{{executable, filepath.Join(home, ".local/bin/agent-keyring"), false}, {filepath.Dir(source), filepath.Join(home, ".codex/skills/agent-keyring"), true}, {filepath.Dir(source), filepath.Join(home, ".claude/skills/agent-keyring"), true}}
	for _, link := range destinations {
		info, e := os.Lstat(link.destination)
		if e == nil && info.Mode()&os.ModeSymlink == 0 && !link.preserve {
			return fmt.Errorf("%s already exists. Move it aside, then run install again.", link.destination)
		}
		if e != nil && !os.IsNotExist(e) {
			return e
		}
	}
	for _, link := range destinations {
		if linksTo(link.destination, link.source) {
			fmt.Fprintln(os.Stderr, "Already linked:", link.destination)
			continue
		}
		if err = os.MkdirAll(filepath.Dir(link.destination), 0755); err != nil {
			return err
		}
		if info, e := os.Lstat(link.destination); e == nil && info.Mode()&os.ModeSymlink == 0 {
			backup := link.destination + ".previous-" + time.Now().Format("20060102-150405.000000000")
			if err = os.Rename(link.destination, backup); err != nil {
				return err
			}
			fmt.Fprintln(os.Stderr, "Preserved previous skill:", backup)
		}
		temporary := link.destination + ".link-" + fmt.Sprint(os.Getpid())
		if err = os.Symlink(link.source, temporary); err != nil {
			if errors.Is(err, fs.ErrPermission) || errors.Is(err, syscall.EROFS) {
				return fmt.Errorf("%s is read-only, so something else manages it. Link %s there as %s.",
					filepath.Dir(link.destination), link.source, filepath.Base(link.destination))
			}
			return err
		}
		if err = os.Rename(temporary, link.destination); err != nil {
			return err
		}
		fmt.Fprintln(os.Stderr, "Linked:", link.destination)
	}
	fmt.Fprintln(os.Stderr, "For sign-ins, use Agent Keyring. Run `agent-keyring skill` for the workflow.")
	return nil
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
