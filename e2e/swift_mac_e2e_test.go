// Written by AI on 2026.11.27 by model gpt-6.2-sol.
package e2e

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

var buildTestPeer = sync.OnceValues(func() (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	env := os.Environ()
	// A Nix SDK for building the Go CLI is not a standalone Xcode toolchain.
	if strings.HasPrefix(os.Getenv("SDKROOT"), "/nix/store/") {
		env = slices.DeleteFunc(env, func(entry string) bool {
			key, _, _ := strings.Cut(entry, "=")
			return key == "SDKROOT" || key == "MACOSX_DEPLOYMENT_TARGET" ||
				key == "DEVELOPER_DIR" && strings.HasPrefix(os.Getenv(key), "/nix/store/")
		})
	}
	swift := func(args ...string) *exec.Cmd {
		cmd := exec.CommandContext(ctx, "/usr/bin/swift", args...)
		cmd.Env = env
		return cmd
	}
	args := []string{"build", "--package-path", "../AgentKeyringPackage", "--product", "TestPeer"}
	if out, err := swift(args...).CombinedOutput(); err != nil {
		return "", fmt.Errorf("build TestPeer: %w\n%s", err, out)
	}
	dir, err := swift(append(args, "--show-bin-path")...).Output()
	if err != nil {
		return "", fmt.Errorf("locate TestPeer: %w", err)
	}
	return filepath.Join(strings.TrimSpace(string(dir)), "TestPeer"), nil
})

// A line from a real child process is its readiness signal or its reply.
// Keep stderr separate so errors never look like replies.
type lineProcess struct {
	name   string
	input  io.WriteCloser
	lines  chan string
	done   chan struct{}
	cancel context.CancelFunc
	stdout *lockedBuffer
	stderr *lockedBuffer
	err    error
}

func startLineProcess(t *testing.T, env []string, path string, args ...string) *lineProcess {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	cmd := exec.CommandContext(ctx, path, args...)
	cmd.Env = env
	p := &lineProcess{
		name: filepath.Base(path), cancel: cancel, stdout: newBuffer(), stderr: newBuffer(),
		lines: make(chan string, 1), done: make(chan struct{}),
	}
	cmd.Stderr = p.stderr
	var err error
	p.input, err = cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	go func() {
		scanner := bufio.NewScanner(io.TeeReader(output, p.stdout))
		for scanner.Scan() {
			select {
			case p.lines <- scanner.Text():
			case <-ctx.Done():
			}
		}
		p.err = cmd.Wait()
		close(p.lines)
		close(p.done)
	}()
	t.Cleanup(p.stopLineProcess)
	return p
}

func (p *lineProcess) stopLineProcess() {
	p.cancel()
	<-p.done
}

func (p *lineProcess) nextLine(t *testing.T, waitingFor string) string {
	t.Helper()
	select {
	case line, ok := <-p.lines:
		if !ok {
			t.Fatalf("%s exited waiting for %s: %v\n%s", p.name, waitingFor, p.err, p.stderr)
		}
		return line
	case <-time.After(20 * time.Second):
		t.Fatalf("%s did not reply to %s\n%s", p.name, waitingFor, p.stderr)
		return ""
	}
}

func (p *lineProcess) sendPeerCommand(t *testing.T, command string) string {
	t.Helper()
	if _, err := fmt.Fprintln(p.input, command); err != nil {
		t.Fatalf("send %s: %v\n%s", command, err, p.stderr)
	}
	return p.nextLine(t, command)
}

func (p *lineProcess) expectOK(t *testing.T, command string) {
	t.Helper()
	if got := p.sendPeerCommand(t, command); got != "OK" {
		t.Fatalf("%s: want OK, got %q", command, got)
	}
}

func (p *lineProcess) quitPeerProcess(t *testing.T) {
	t.Helper()
	p.expectOK(t, "QUIT")
	select {
	case <-p.done:
		if p.err != nil {
			t.Fatalf("%s quit: %v\n%s", p.name, p.err, p.stderr)
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("%s did not exit after QUIT\n%s", p.name, p.stderr)
	}
}

type realMac struct {
	executable, home, directory, socket, relay, apns, apnsDirectory string
}

func startRelay(t *testing.T, args ...string) string {
	t.Helper()
	box := startLineProcess(t, os.Environ(), bin.box, append([]string{"--listen", "127.0.0.1:0"}, args...)...)
	line := box.nextLine(t, "relay address")
	address, ok := strings.CutPrefix(line, "agent-keyring-box is serving boxes at ")
	if host, _, err := net.SplitHostPort(address); !ok || err != nil || host != "127.0.0.1" {
		t.Fatalf("unexpected relay readiness line %q", line)
	}
	t.Cleanup(func() { checkRelayLogs(t, box, line) })
	return "http://" + address
}

func newRealMac(t *testing.T, relayArgs ...string) realMac {
	t.Helper()
	if runtime.GOOS != "darwin" {
		t.Skip("TestPeer uses the macOS Mac engine")
	}
	executable, err := buildTestPeer()
	if err != nil {
		t.Fatal(err)
	}
	// Darwin's Unix socket path limit is shorter than many TMPDIRs.
	home, err := os.MkdirTemp("/tmp", "akr-mac-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(home); err != nil {
			t.Error(err)
		}
	})
	relay := startRelay(t, relayArgs...)
	apnsDir := filepath.Join(home, "apns")
	apns := startAPNs(t, apnsDir)
	return realMac{executable: executable, home: home, directory: filepath.Join(home, "mac"),
		socket: filepath.Join(home, "agent.sock"), relay: relay, apns: apns, apnsDirectory: apnsDir}
}

func startAPNs(t *testing.T, dir string) string {
	t.Helper()
	server := startLineProcess(t, os.Environ(), bin.apns, "--dir", dir)
	line := server.nextLine(t, "APNs address")
	address, ok := strings.CutPrefix(line, "test-apns ready ")
	address, expectedCA := strings.CutSuffix(address, " "+filepath.Join(dir, "apple-ca.pem"))
	if !ok || !expectedCA || !strings.HasPrefix(address, "https://127.0.0.1:") {
		t.Fatalf("unexpected APNs readiness line %q", line)
	}
	if err := os.WriteFile(filepath.Join(dir, "gateway"), []byte(address), 0600); err != nil {
		t.Fatal(err)
	}
	return address
}

func (m realMac) startMacTestPeer(t *testing.T) *lineProcess {
	t.Helper()
	env := append(os.Environ(), "HOME="+m.home, "CFFIXED_USER_HOME="+m.home, "AGENT_KEYRING_RELAY_URL="+m.relay)
	peer := startLineProcess(t, env, m.executable, "--dir", m.directory, "--socket", m.socket, "--relay", m.relay, "--apns", m.apnsDirectory)
	if got := peer.nextLine(t, "READY"); got != "READY" {
		t.Fatalf("TestPeer did not become ready: %q", got)
	}
	return peer
}

type testComputer struct {
	home, state string
	env         []string
}

func (m realMac) testComputer(name string, local bool) testComputer {
	socket := ""
	if local {
		socket = m.socket
	}
	state := filepath.Join(m.home, name)
	return testComputer{home: m.home, state: state, env: append(os.Environ(),
		"HOME="+m.home, "AGENT_KEYRING_STATE_DIR="+state, "AGENT_KEYRING_SOCKET="+socket,
		"AGENT_KEYRING_RELAY_URL="+m.relay, "AGENT_KEYRING_TEST_LOOPBACK=1", "AGENT_KEYRING_PUSH_RELAY_URL=",
		"AGENT_KEYRING_TEST_APNS_GATEWAY="+m.apns, "AGENT_KEYRING_TEST_APNS_CA="+filepath.Join(m.apnsDirectory, "apple-ca.pem"),
		"AGENT_KEYRING_TEST_ANSWER_WITHIN=20s")}
}

func (c testComputer) buildComputerCommand(ctx context.Context, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, bin.command, args...)
	if args[0] == "read" {
		// Send the bytes to a consumer, keeping the CLI's failure status.
		shellArgs := []string{"-c", `set -o pipefail; "$@" | /bin/sh -c cat`, "read", bin.command}
		cmd = exec.CommandContext(ctx, "/bin/sh", append(shellArgs, args...)...)
		cmd.WaitDelay = time.Second
	}
	cmd.Dir = c.home
	cmd.Env = c.env
	return cmd
}

func (c testComputer) beginComputerCommand(t *testing.T, args ...string) func() cliProcessResult {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	done := startCapturedCommand(c.buildComputerCommand(ctx, args...))
	finish := sync.OnceValue(func() cliProcessResult { return <-done })
	t.Cleanup(func() { cancel(); finish() })
	return func() cliProcessResult { defer cancel(); return finish() }
}

func (c testComputer) runComputerCommand(t *testing.T, args ...string) cliProcessResult {
	t.Helper()
	return c.beginComputerCommand(t, args...)()
}

func (c testComputer) enrolTestComputer(t *testing.T, peer *lineProcess, name string) {
	t.Helper()
	code := peer.sendPeerCommand(t, "INVITE_CODE")
	wait := c.beginComputerCommand(t, "enrol", "--name", name, "--code", code)
	peer.expectOK(t, "APPROVE_JOIN")
	assertSuccess(t, wait())
}

func (c testComputer) requestTestLease(t *testing.T, login, task string, flags ...string) func() cliProcessResult {
	t.Helper()
	args := []string{"lease", login, "--task", task, "--reason", "Verify access to the test login"}
	return c.beginComputerCommand(t, append(args, flags...)...)
}

func assertSuccess(t *testing.T, got cliProcessResult) {
	t.Helper()
	if got.err != nil {
		t.Fatalf("command failed: %v\n%s%s", got.err, got.stdout, got.stderr)
	}
}

func leaseID(t *testing.T, got cliProcessResult) string {
	t.Helper()
	assertSuccess(t, got)
	id := strings.TrimSpace(got.stdout)
	if id == "" {
		t.Fatalf("CLI did not print a lease ID: %s", got.stderr)
	}
	return id
}

func importRealMac(t *testing.T, peer *lineProcess) (github, docs string) {
	t.Helper()
	reply := peer.sendPeerCommand(t, "IMPORT_SELECTIVE")
	ids := strings.Fields(reply)
	if len(ids) != 2 || ids[0] == ids[1] {
		t.Fatalf("want two distinct imported login IDs, got %q", reply)
	}
	return ids[0], ids[1]
}

func assertFind(t *testing.T, got cliProcessResult, id, site, rule string) {
	t.Helper()
	if got.err == nil {
		for _, line := range strings.Split(got.stdout, "\n") {
			fields := strings.Fields(line)
			if len(fields) == 5 && fields[0] == id && fields[1] == "https://"+site && fields[3] == rule {
				return
			}
		}
	}
	t.Fatalf("find %s: want %s with rule %s, got %v\n%s%s", site, id, rule, got.err, got.stdout, got.stderr)
}

func assertPassword(t *testing.T, got cliProcessResult, expected string) {
	t.Helper()
	if got.err != nil || got.stdout != expected {
		t.Fatalf("read: want %q, got %q (%v)\n%s", expected, got.stdout, got.err, got.stderr)
	}
}

func assertRefused(t *testing.T, got cliProcessResult, reason string) {
	t.Helper()
	var exit *exec.ExitError
	if !errors.As(got.err, &exit) || exit.ExitCode() != 1 || got.stdout != "" || !strings.Contains(got.stderr, reason) {
		t.Fatalf("want refusal containing %q, got %v\n%s%s", reason, got.err, got.stdout, got.stderr)
	}
}

func TestRealMacCLILocalFlowAndRestart(t *testing.T) {
	mac := newRealMac(t)
	peer := mac.startMacTestPeer(t)
	cli := mac.testComputer("local", true)
	github, docs := importRealMac(t, peer)

	const excluded = "my.1password.com"
	assertAbsentFromDisk(t, mac.directory, excluded)
	assertRefused(t, cli.runComputerCommand(t, "find", excluded), "No matching logins")

	peer.quitPeerProcess(t)
	peer = mac.startMacTestPeer(t)
	assertFind(t, cli.runComputerCommand(t, "find", "github.example"), github, "github.example", "Ask")
	assertFind(t, cli.runComputerCommand(t, "find", "docs.example"), docs, "docs.example", "Automatic")
	assertRefused(t, cli.runComputerCommand(t, "find", excluded), "No matching logins")

	waiting := cli.requestTestLease(t, github, "local-approval")
	id := peer.sendPeerCommand(t, "APPROVE_WAITING_LEASE")
	if got := leaseID(t, waiting()); got != id {
		t.Fatalf("lease ID: want %s, got %s", id, got)
	}
	assertPassword(t, cli.runComputerCommand(t, "read", id, "--field", "password"), "pw-github.example")
	assertStatus(t, cli, id, "active")
	fillInBrowser(t, cli, id)
	peer.expectOK(t, "STOP_LEASE "+id)
	assertRefused(t, cli.runComputerCommand(t, "read", id, "--field", "password"), "The lease is not active")

	released := leaseID(t, cli.requestTestLease(t, docs, "local-release")())
	assertSuccess(t, cli.runComputerCommand(t, "release", released))
	assertRefused(t, cli.runComputerCommand(t, "read", released, "--field", "password"), "The lease is not active")
	waiting = cli.requestTestLease(t, github, "local-denial")
	peer.sendPeerCommand(t, "DENY_WAITING_LEASE Use the invoice in email.")
	assertRefused(t, waiting(), "Use the invoice in email.")
	peer.quitPeerProcess(t)
}

func assertAbsentFromDisk(t *testing.T, dir, excluded string) {
	t.Helper()
	if err := filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if strings.Contains(entry.Name(), excluded) {
			return fmt.Errorf("excluded site %s appears in path %s", excluded, path)
		}
		if entry.Type().IsRegular() {
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			if bytes.Contains(data, []byte(excluded)) {
				return fmt.Errorf("excluded site %s appears in %s", excluded, path)
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

func assertStatus(t *testing.T, cli testComputer, id, expected string) {
	t.Helper()
	got := cli.runComputerCommand(t, "status", id)
	assertSuccess(t, got)
	if !strings.Contains(got.stdout, id+": "+expected) {
		t.Fatalf("status: want %q, got %q", expected, got.stdout)
	}
}

func waitForFind(t *testing.T, cli testComputer, id, site, rule string) {
	t.Helper()
	var got cliProcessResult
	for deadline := time.Now().Add(15 * time.Second); ; time.Sleep(100 * time.Millisecond) {
		got = cli.runComputerCommand(t, "find", site)
		if got.err == nil && strings.Contains(got.stdout, rule) || time.Now().After(deadline) {
			break
		}
	}
	assertFind(t, got, id, site, rule)
}
