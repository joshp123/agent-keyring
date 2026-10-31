// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package receiver

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

func browserIdentity(port string) (string, error) {
	output, err := exec.Command("/usr/sbin/lsof", "-nP", "-a", "-iTCP:"+port, "-sTCP:LISTEN", "-Fp").Output()
	if err != nil {
		return "", errors.New("No local Chrome debugging listener was found at that port.")
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
	output, err = exec.Command("/bin/ps", "-p", pid, "-o", "comm=").Output()
	if err != nil {
		return "", errors.New("The browser process disappeared.")
	}
	path := strings.TrimSpace(string(output))
	requirement := `anchor apple generic and identifier "com.google.Chrome" and certificate leaf[subject.OU] = "EQHXZ8M8AV"`
	if err = exec.Command("/usr/bin/codesign", "--verify", "--strict", "--test-requirement=="+requirement, path).Run(); err != nil {
		return "", errors.New("This endpoint is not owned by a verified Google Chrome process. Use a supported local Chrome debugging endpoint.")
	}
	output, err = exec.Command("/bin/ps", "-p", pid, "-o", "lstart=").Output()
	if err != nil {
		return "", errors.New("Cannot identify the browser instance.")
	}
	return fmt.Sprintf("chrome:%s:%s", pid, strings.TrimSpace(string(output))), nil
}
