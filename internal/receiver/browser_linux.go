// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package receiver

import (
	"debug/elf"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

func browserIdentity(port string) (string, error) {
	portNumber, err := strconv.ParseUint(port, 10, 16)
	if err != nil {
		return "", errors.New("The browser debugging port is invalid.")
	}
	sockets := map[string]bool{}
	for _, table := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		data, err := os.ReadFile(table)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			fields := strings.Fields(line)
			if len(fields) > 9 && strings.HasSuffix(fields[1], fmt.Sprintf(":%04X", portNumber)) && fields[3] == "0A" {
				sockets[fields[9]] = false
			}
		}
	}
	if len(sockets) == 0 {
		return "", errors.New("No local browser debugging listener was found at that port.")
	}
	processes, err := os.ReadDir("/proc")
	if err != nil {
		return "", errors.New("Cannot identify the browser's local listener through /proc.")
	}
	owners := map[string]bool{}
	for _, process := range processes {
		if _, err := strconv.Atoi(process.Name()); err != nil {
			continue
		}
		root := filepath.Join("/proc", process.Name())
		info, err := os.Stat(root)
		if err != nil || info.Sys().(*syscall.Stat_t).Uid != uint32(os.Geteuid()) {
			continue
		}
		descriptors, _ := os.ReadDir(filepath.Join(root, "fd"))
		for _, descriptor := range descriptors {
			link, _ := os.Readlink(filepath.Join(root, "fd", descriptor.Name()))
			if strings.HasPrefix(link, "socket:[") && strings.HasSuffix(link, "]") {
				inode := strings.TrimSuffix(strings.TrimPrefix(link, "socket:["), "]")
				if _, found := sockets[inode]; found {
					sockets[inode] = true
					owners[process.Name()] = true
				}
			}
		}
	}
	for _, found := range sockets {
		if !found {
			return "", errors.New("Cannot identify the browser listener. Run the receiver as the user who owns the browser, with access to its /proc entries.")
		}
	}
	if len(owners) != 1 {
		return "", errors.New("Cannot bind this endpoint to one browser process.")
	}
	for pid := range owners {
		root := filepath.Join("/proc", pid)
		path, err := os.Readlink(filepath.Join(root, "exe"))
		if err != nil {
			return "", errors.New("Cannot identify the browser executable through /proc.")
		}
		if err = verifyBrowserExecutable(path); err != nil {
			return "", errors.New("This endpoint is not owned by a supported browser installation. Use Google Chrome, Chrome for Testing or Chromium on this machine.")
		}
		status, err := os.ReadFile(filepath.Join(root, "stat"))
		if err != nil {
			return "", errors.New("The browser process disappeared.")
		}
		fields := strings.Fields(string(status)[strings.LastIndexByte(string(status), ')')+1:])
		if len(fields) < 20 {
			return "", errors.New("Cannot identify the browser instance.")
		}
		return fmt.Sprintf("chrome:%s:%s", pid, fields[19]), nil
	}
	return "", errors.New("Cannot identify the browser instance.")
}

func verifyBrowserExecutable(path string) error {
	switch filepath.Base(path) {
	case "chrome", "chromium", ".chromium-wrapped", ".chrome-wrapped":
	default:
		return errors.New("unsupported browser executable")
	}
	file, err := elf.Open(path)
	if err != nil {
		return err
	}
	file.Close()
	if err = verifyChromiumResources(filepath.Dir(path)); err != nil {
		return err
	}
	return verifyNixInstallation(path)
}
