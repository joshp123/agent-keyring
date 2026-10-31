// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package receiver

import (
	"bytes"
	"debug/macho"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

func browserIdentity(port string) (string, error) {
	output, err := exec.Command("/usr/sbin/lsof", "-nP", "-a", "-iTCP:"+port, "-sTCP:LISTEN", "-Fp").Output()
	if err != nil {
		return "", errors.New("No local browser debugging listener was found at that port.")
	}
	pids := map[string]bool{}
	for _, line := range strings.Split(string(output), "\n") {
		if strings.HasPrefix(line, "p") {
			pids[line[1:]] = true
		}
	}
	if len(pids) != 1 {
		return "", errors.New("Cannot bind this endpoint to one browser process.")
	}
	var pid string
	for key := range pids {
		pid = key
	}
	processID, _ := strconv.Atoi(pid)
	arguments, err := unix.SysctlRaw("kern.procargs2", processID)
	if err != nil || len(arguments) < 5 {
		return "", errors.New("The browser process disappeared.")
	}
	end := bytes.IndexByte(arguments[4:], 0)
	if end < 0 {
		return "", errors.New("Cannot identify the browser executable.")
	}
	path, err := filepath.EvalSymlinks(string(arguments[4 : 4+end]))
	if err != nil || verifyBrowserBundle(path) != nil {
		return "", errors.New("This endpoint is not owned by a supported browser installation. Use Google Chrome, Chrome for Testing or Chromium on this machine.")
	}
	output, err = exec.Command("/bin/ps", "-p", pid, "-o", "lstart=").Output()
	if err != nil {
		return "", errors.New("Cannot identify the browser instance.")
	}
	return fmt.Sprintf("chrome:%s:%s", pid, strings.TrimSpace(string(output))), nil
}

func bundleValue(info, key string) string {
	value, err := exec.Command("/usr/bin/plutil", "-extract", key, "raw", "-o", "-", info).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(value))
}

func verifyBrowserBundle(path string) error {
	contents := filepath.Dir(filepath.Dir(path))
	info := filepath.Join(contents, "Info.plist")
	identifier := bundleValue(info, "CFBundleIdentifier")
	framework := ""
	switch identifier {
	case "com.google.Chrome":
		requirement := `anchor apple generic and identifier "com.google.Chrome" and certificate leaf[subject.OU] = "EQHXZ8M8AV"`
		return exec.Command("/usr/bin/codesign", "--verify", "--strict", "--test-requirement=="+requirement, path).Run()
	case "com.google.chrome.for.testing":
		framework = "Google Chrome for Testing Framework"
	case "org.chromium.Chromium":
		framework = "Chromium Framework"
	default:
		return errors.New("unsupported browser bundle")
	}
	if filepath.Dir(path) != filepath.Join(contents, "MacOS") || bundleValue(info, "CFBundleExecutable") != filepath.Base(path) {
		return errors.New("browser executable does not match its bundle")
	}
	engine := filepath.Join(contents, "Frameworks", framework+".framework")
	version := bundleValue(info, "CFBundleShortVersionString")
	if version == "" || version != bundleValue(filepath.Join(engine, "Resources", "Info.plist"), "CFBundleShortVersionString") {
		return errors.New("browser framework does not match its bundle")
	}
	for _, binary := range []string{path, filepath.Join(engine, framework)} {
		file, err := macho.Open(binary)
		if err != nil {
			return errors.New("browser installation has no native executable or framework")
		}
		file.Close()
		// These builds have linker signatures, not publisher signatures or a
		// sealed resource envelope. Check their code without claiming otherwise.
		if err = exec.Command("/usr/bin/codesign", "--verify", "--strict", "--ignore-resources", binary).Run(); err != nil {
			return errors.New("browser code signature is invalid")
		}
	}
	if err := verifyChromiumResources(filepath.Join(engine, "Resources")); err != nil {
		return err
	}
	return verifyNixInstallation(path)
}
