// Written by AI on 2026.11.20 by model claude opus 5.5.
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// focusHint is Josh's hint for an agent whose request waits while a Focus is
// on, with the Focus named: Apple may be holding the notification back. It
// reads macOS's own record of the Focus in use, which Apple does not
// document; anything it cannot read means "unknown" and gives no hint.
func focusHint() string {
	if runtime.GOOS != "darwin" {
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	mode := activeFocus(filepath.Join(home, "Library/DoNotDisturb/DB"))
	if mode == "" {
		return ""
	}
	return "Vibe coding late at night? If Sleep or Driving Focus is on, Apple holds back notifications unless Agent Keyring is allowed in that Focus. " +
		"A Focus is on now (" + mode + "): if Josh doesn't answer, tell him that may be why."
}

// activeFocus names the Focus in use, from Assertions.json and its name in ModeConfigurations.json.
func activeFocus(folder string) string {
	var assertions struct {
		Data []struct {
			Records []struct {
				Details struct {
					Mode string `json:"assertionDetailsModeIdentifier"`
				} `json:"assertionDetails"`
			} `json:"storeAssertionRecords"`
		} `json:"data"`
	}
	raw, err := os.ReadFile(filepath.Join(folder, "Assertions.json"))
	if err != nil || json.Unmarshal(raw, &assertions) != nil {
		return ""
	}
	mode := ""
	for _, data := range assertions.Data {
		for _, record := range data.Records {
			if record.Details.Mode != "" {
				mode = record.Details.Mode
			}
		}
	}
	if mode == "" {
		return ""
	}
	var configurations struct {
		Data []struct {
			Modes map[string]struct {
				Mode struct {
					Name string `json:"name"`
				} `json:"mode"`
			} `json:"modeConfigurations"`
		} `json:"data"`
	}
	if raw, err := os.ReadFile(filepath.Join(folder, "ModeConfigurations.json")); err == nil && json.Unmarshal(raw, &configurations) == nil {
		for _, data := range configurations.Data {
			if name := data.Modes[mode].Mode.Name; name != "" {
				return name
			}
		}
	}
	switch {
	case strings.Contains(mode, "sleep"):
		return "Sleep"
	case strings.Contains(mode, "driving"):
		return "Driving"
	case strings.HasSuffix(mode, ".default"):
		return "Do Not Disturb"
	}
	return "a Focus"
}
