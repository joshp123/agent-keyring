// Written by AI on 2026.11.21 by model claude opus 5.5.
package clientstate

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const logName = "agent-keyring.log"

// Log keeps one line of what this computer's command did and why, with no
// secrets and no site or account names, in the format the devices use:
// "<UTC time, ms, ISO 8601> <computer> command <event> key=value ...".
// The last half megabyte or so is kept.
func (s Store) Log(computer, event string) {
	line := time.Now().UTC().Format("2006-01-02T15:04:05.000Z") + " " + strings.ReplaceAll(computer, " ", "_") + " command " + event + "\n"
	path := filepath.Join(s.Directory, logName)
	if info, err := os.Lstat(path); err == nil && info.Size() > 1<<20 {
		if data, err := os.ReadFile(path); err == nil {
			kept := data[len(data)-512<<10:]
			if cut := bytes.IndexByte(kept, '\n'); cut >= 0 {
				kept = kept[cut+1:]
			}
			os.WriteFile(path+".new", kept, 0o600)
			os.Rename(path+".new", path)
		}
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return
	}
	defer file.Close()
	file.WriteString(line)
}

// LogLines is this computer's own log, oldest first.
func (s Store) LogLines() []string {
	data, err := os.ReadFile(filepath.Join(s.Directory, logName))
	if err != nil {
		return nil
	}
	return strings.Split(strings.TrimRight(string(data), "\n"), "\n")
}
