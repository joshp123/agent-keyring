// Written by AI on 2026.11.27 by model gpt-6.2-sol.
package e2e

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

type e2eTestExecutables struct{ command, apns, box string }

var bin e2eTestExecutables

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "akr-e2e-bin-")
	if err != nil {
		panic(err)
	}
	bin = e2eTestExecutables{filepath.Join(dir, "agent-keyring"), filepath.Join(dir, "test-apns"), filepath.Join(dir, "agent-keyring-box")}
	code := 1
	if err := buildPrograms(); err != nil {
		fmt.Fprintln(os.Stderr, err)
	} else {
		code = m.Run()
	}
	if err := os.RemoveAll(dir); err != nil {
		fmt.Fprintln(os.Stderr, err)
		code = 1
	}
	os.Exit(code)
}

func buildPrograms() error {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	for output, source := range map[string]string{
		bin.command: "./cmd/agent-keyring",
		bin.apns:    "./developer/test-apns",
		bin.box:     "./cmd/agent-keyring-box",
	} {
		command := exec.CommandContext(ctx, "go", "build", "-o", output, source)
		command.Dir = ".."
		if out, err := command.CombinedOutput(); err != nil {
			return fmt.Errorf("build %s: %w\n%s", source, err, out)
		}
	}
	return nil
}

type cliProcessResult struct {
	stdout, stderr string
	err            error
}

type lockedBuffer struct {
	mu   sync.Mutex
	data bytes.Buffer
}

func newBuffer() *lockedBuffer { return new(lockedBuffer) }

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.data.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.data.String()
}

func startCapturedCommand(cmd *exec.Cmd) chan cliProcessResult {
	var stdout bytes.Buffer
	stderr := newBuffer()
	return startWithStderr(cmd, &stdout, stderr)
}

func startWithStderr(cmd *exec.Cmd, stdout *bytes.Buffer, stderr *lockedBuffer) chan cliProcessResult {
	cmd.Stdout, cmd.Stderr = stdout, stderr
	done := make(chan cliProcessResult, 1)
	if err := cmd.Start(); err != nil {
		done <- cliProcessResult{err: err}
		return done
	}
	go func() {
		err := cmd.Wait()
		done <- cliProcessResult{stdout.String(), stderr.String(), err}
	}()
	return done
}

func waitForCapturedCommand(t *testing.T, done chan cliProcessResult, label string) cliProcessResult {
	t.Helper()
	select {
	case r := <-done:
		return r
	case <-time.After(45 * time.Second):
		t.Fatalf("%s did not finish", label)
		return cliProcessResult{}
	}
}

func eventually(t *testing.T, description string, predicate func() bool) {
	t.Helper()
	for deadline := time.Now().Add(15 * time.Second); ; time.Sleep(50 * time.Millisecond) {
		if predicate() {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", description)
		}
	}
}
