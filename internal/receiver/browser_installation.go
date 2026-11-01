// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package receiver

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Installation checks identify a native Chromium installation. Unpacked and
// ad-hoc builds have no publisher trust; these checks do not isolate same-user
// software that deliberately impersonates a browser or reads its memory.
func verifyChromiumResources(directory string) error {
	for _, name := range []string{"resources.pak", "icudtl.dat"} {
		info, err := os.Stat(filepath.Join(directory, name))
		if err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
			return errors.New("browser installation is missing its Chromium resources")
		}
	}
	return nil
}

func verifyNixInstallation(path string) error {
	if !strings.HasPrefix(path, "/nix/store/") {
		return nil
	}
	root := "/nix/store/" + strings.Split(strings.TrimPrefix(path, "/nix/store/"), "/")[0]
	command, err := exec.LookPath("nix-store")
	if err != nil {
		for _, candidate := range []string{"/nix/var/nix/profiles/default/bin/nix-store", "/run/current-system/sw/bin/nix-store"} {
			if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() {
				command = candidate
				break
			}
		}
	}
	if command == "" {
		return errors.New("Nix is needed to check this browser's store registration")
	}
	if err := exec.Command(command, "--query", "--hash", root).Run(); err != nil {
		return errors.New("browser installation is not registered in the Nix store")
	}
	return nil
}
