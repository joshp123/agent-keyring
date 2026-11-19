// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The whole path an agent and Josh take, with the real relay, the real
// command, and a stand-in device whose software keys take the place of the
// iPhone's chip. Two machines join; on them agents ask, and get the login
// once, a denial with Josh's words, a plain denial, no answer, or an
// Automatic login with no question; an approval keeps working while the relay
// is down, until it is released. Every program runs as its own process.
//
// By default everything runs here on loopback. To run it across real machines,
// see developer/e2e/run.sh, which uses the same steps.
package e2e

import (
	"bytes"
	"context"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type programs struct{ relay, command, device string }

func build(t *testing.T) programs {
	t.Helper()
	dir := t.TempDir()
	p := programs{filepath.Join(dir, "agent-keyring-relay"), filepath.Join(dir, "agent-keyring"), filepath.Join(dir, "test-device")}
	for output, source := range map[string]string{p.relay: "./cmd/agent-keyring-relay", p.command: "./cmd/agent-keyring", p.device: "./developer/test-device"} {
		command := exec.Command("go", "build", "-o", output, source)
		command.Dir = ".."
		if out, err := command.CombinedOutput(); err != nil {
			t.Fatalf("build %s: %v\n%s", source, err, out)
		}
	}
	return p
}

type run struct {
	t           *testing.T
	programs    programs
	relay       string
	deviceState string
}

// machine is one asking machine's private state directory.
type machine struct {
	run   *run
	state string
}

func (r *run) newMachine() *machine {
	state := r.t.TempDir()
	os.Chmod(state, 0o700) // The command refuses state others could read.
	return &machine{r, state}
}

func (m *machine) command(args ...string) *exec.Cmd {
	command := exec.Command(m.run.programs.command, args...)
	command.Env = append(os.Environ(), "AGENT_KEYRING_STATE_DIR="+m.state, "AGENT_KEYRING_SOCKET=", "AGENT_KEYRING_RELAY=")
	return command
}

type result struct {
	stdout, stderr string
	err            error
}

func start(command *exec.Cmd) chan result {
	var stdout, stderr bytes.Buffer
	command.Stdout, command.Stderr = &stdout, &stderr
	done := make(chan result, 1)
	if err := command.Start(); err != nil {
		done <- result{err: err}
		return done
	}
	go func() { err := command.Wait(); done <- result{stdout.String(), stderr.String(), err} }()
	return done
}

func (r *run) device(args ...string) string {
	r.t.Helper()
	out, err := exec.Command(r.programs.device, append(args[:1:1], append([]string{"--state", r.deviceState}, args[1:]...)...)...).CombinedOutput()
	if err != nil {
		r.t.Fatalf("test-device %v: %v\n%s", args, err, out)
	}
	return string(out)
}

func wait(t *testing.T, done chan result, label string) result {
	t.Helper()
	select {
	case r := <-done:
		return r
	case <-time.After(30 * time.Second):
		t.Fatalf("%s did not finish", label)
		return result{}
	}
}

func freePort(t *testing.T) string {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	return listener.Addr().String()
}

// startRelay runs the relay until stop is called, and shows its log if the
// test failed.
func startRelay(t *testing.T, p programs, address, state string) (stop func()) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	relay := exec.CommandContext(ctx, p.relay, "--listen", address, "--state", state, "--loopback-test", "--answer-within", "4s")
	relayLog := &bytes.Buffer{}
	relay.Stderr = relayLog
	if err := relay.Start(); err != nil {
		t.Fatal(err)
	}
	stop = func() {
		cancel()
		relay.Wait()
		if t.Failed() {
			t.Logf("relay log:\n%s", relayLog)
		}
	}
	for deadline := time.Now().Add(10 * time.Second); !strings.Contains(relayLog.String(), "listening"); time.Sleep(50 * time.Millisecond) {
		if time.Now().After(deadline) {
			stop()
			t.Fatal("relay did not start")
		}
	}
	return stop
}

func TestAnAgentAsksAndJoshAnswers(t *testing.T) {
	p := build(t)
	address, relayState := freePort(t), t.TempDir()
	stopRelay := startRelay(t, p, address, relayState)
	defer func() { stopRelay() }()
	r := &run{t: t, programs: p, relay: address, deviceState: t.TempDir()}
	r.device("init", "--relay", address)

	// Two machines ask to join; Josh approves both on his device.
	linux, mini := r.newMachine(), r.newMachine()
	joiningLinux := start(linux.command("enrol", "--name", "Linux server", "--invite", strings.TrimSpace(r.device("invite"))))
	joiningMini := start(mini.command("enrol", "--name", "Mac mini", "--invite", strings.TrimSpace(r.device("invite"))))
	pending := map[string]chan result{"Linux server": joiningLinux, "Mac mini": joiningMini}
	for deadline := time.Now().Add(20 * time.Second); len(pending) > 0; time.Sleep(300 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("machines still waiting to join: %v", pending)
		}
		exec.Command(p.device, "approve-joins", "--state", r.deviceState).Run()
		for label, joining := range pending {
			select {
			case got := <-joining:
				if got.err != nil || !strings.Contains(got.stderr, "Joined") {
					t.Fatalf("%s did not join: %v\n%s", label, got.err, got.stderr)
				}
				delete(pending, label)
			default:
			}
		}
	}

	t.Run("approved, a program gets the password through a pipe", func(t *testing.T) {
		output := filepath.Join(t.TempDir(), "received")
		asking := start(linux.command("lease", "login-ask", "--task", "invoice", "--reason", "You asked me to download October's invoice."))
		r.device("answer", "--approve")
		got := wait(t, asking, "lease")
		if got.err != nil {
			t.Fatalf("lease: %v\n%s", got.err, got.stderr)
		}
		lease := strings.TrimSpace(got.stdout)
		piped := linux.command("read", lease, "--field", "password")
		piped.Path, piped.Args = "/bin/sh", []string{"/bin/sh", "-c", `"$0" read "$1" --field password | cat > "$2"`, p.command, lease, output}
		if used := wait(t, start(piped), "read | program"); used.err != nil {
			t.Fatalf("read | program: %v\n%s", used.err, used.stderr)
		}
		if received, _ := os.ReadFile(output); string(received) != "example-ask-password" {
			t.Fatalf("the program received %d bytes, not the password", len(received))
		}
	})

	t.Run("an approval keeps working while the relay is down, until it is released", func(t *testing.T) {
		asking := start(linux.command("lease", "login-ask", "--task", "offline", "--reason", "You asked me to download November's invoice."))
		r.device("answer", "--approve")
		got := wait(t, asking, "lease")
		if got.err != nil {
			t.Fatalf("lease: %v\n%s", got.err, got.stderr)
		}
		lease := strings.TrimSpace(got.stdout)

		stopRelay()
		restarted := false
		defer func() {
			if !restarted { // The later steps need the relay.
				stopRelay = startRelay(t, p, address, relayState)
			}
		}()
		read := wait(t, start(linux.command("read", lease, "--field", "password")), "read")
		if read.err != nil || read.stdout != "example-ask-password" {
			t.Fatalf("with the relay down, read: %v, %d bytes\n%s", read.err, len(read.stdout), read.stderr)
		}
		released := wait(t, start(linux.command("release", lease)), "release")
		if released.err == nil || !strings.Contains(released.stderr, "Released on this machine") {
			t.Fatalf("with the relay down, release: %v\n%s", released.err, released.stderr)
		}

		// The relay comes back still thinking the approval stands; this machine does not.
		stopRelay, restarted = startRelay(t, p, address, relayState), true
		read = wait(t, start(linux.command("read", lease, "--field", "password")), "read")
		if read.err == nil || read.stdout != "" || !strings.Contains(read.stderr, "This lease was released.") {
			t.Fatalf("after release, read: %v, %d bytes\n%s", read.err, len(read.stdout), read.stderr)
		}
		released = wait(t, start(linux.command("release", lease)), "release")
		if released.err != nil || !strings.Contains(released.stderr, "Lease released.") {
			t.Fatalf("release with the relay back: %v\n%s", released.err, released.stderr)
		}
	})

	t.Run("devices added after the machines joined approve for them", func(t *testing.T) {
		second := t.TempDir()
		joining := start(exec.Command(p.device, "join", "--state", second, "--invite", strings.TrimSpace(r.device("invite"))))
		for joined := false; !joined; {
			exec.Command(p.device, "approve-joins", "--state", r.deviceState).Run()
			select {
			case got := <-joining:
				if got.err != nil {
					t.Fatalf("the second device did not join: %v\n%s", got.err, got.stderr)
				}
				joined = true
			case <-time.After(300 * time.Millisecond):
			}
		}
		// A third device, added by the second, which the machines never saw sign anything.
		third := t.TempDir()
		invite, err := exec.Command(p.device, "invite", "--state", second).Output()
		if err != nil {
			t.Fatal(err)
		}
		joining = start(exec.Command(p.device, "join", "--state", third, "--invite", strings.TrimSpace(string(invite))))
		for joined := false; !joined; {
			exec.Command(p.device, "approve-joins", "--state", second).Run()
			select {
			case got := <-joining:
				if got.err != nil {
					t.Fatalf("the third device did not join: %v\n%s", got.err, got.stderr)
				}
				joined = true
			case <-time.After(300 * time.Millisecond):
			}
		}
		asking := start(linux.command("lease", "login-ask", "--task", "second", "--reason", "Second device."))
		if out, err := exec.Command(p.device, "answer", "--state", third, "--approve").CombinedOutput(); err != nil {
			t.Fatalf("the second device could not answer: %v\n%s", err, out)
		}
		got := wait(t, asking, "lease")
		if got.err != nil {
			t.Fatalf("lease: %v\n%s", got.err, got.stderr)
		}
		read := wait(t, start(linux.command("read", strings.TrimSpace(got.stdout), "--field", "password")), "read")
		if read.err != nil || read.stdout != "example-ask-password" {
			t.Fatalf("read: %v\n%s", read.err, read.stderr)
		}
	})

	t.Run("nobody answers", func(t *testing.T) {
		asking := start(linux.command("lease", "login-ask", "--task", "invoice", "--reason", "Second try."))
		r.device("answer", "--ignore")
		got := wait(t, asking, "lease")
		if got.err == nil || !strings.Contains(got.stderr, "No answer. Nobody answered within 10 minutes. This is not a refusal.") {
			t.Fatalf("want no answer, got %v\n%s", got.err, got.stderr)
		}
	})

	t.Run("denied with Josh's words", func(t *testing.T) {
		asking := start(linux.command("lease", "login-ask", "--task", "invoice", "--reason", "Third try."))
		r.device("answer", "--deny", "The invoice is in my email. Use that.")
		got := wait(t, asking, "lease")
		if got.err == nil || !strings.Contains(got.stderr, "denied. Reply: The invoice is in my email. Use that.") {
			t.Fatalf("want a denial with words, got %v\n%s", got.err, got.stderr)
		}
		again := wait(t, start(linux.command("lease", "login-ask", "--task", "invoice", "--reason", "Fourth try.")), "lease")
		if again.err == nil || !strings.Contains(again.stderr, "Josh denied this login for this machine") {
			t.Fatalf("a denial holds the login off for 30 minutes; got %v\n%s", again.err, again.stderr)
		}
	})

	t.Run("denied with no words", func(t *testing.T) {
		asking := start(mini.command("lease", "login-ask", "--task", "invoice", "--reason", "From the mini."))
		r.device("answer", "--deny-plain")
		got := wait(t, asking, "lease")
		if got.err == nil || !strings.Contains(got.stderr, "This lease is denied.") || strings.Contains(got.stderr, "Reply:") {
			t.Fatalf("want a plain denial, got %v\n%s", got.err, got.stderr)
		}
	})

	t.Run("a device tests itself at first run", func(t *testing.T) {
		if out := r.device("self-test"); !strings.Contains(out, "Test request: LEASE_STATE_APPROVED") {
			t.Fatalf("self-test said %q", out)
		}
	})
	t.Run("Automatic, with no question", func(t *testing.T) {
		got := wait(t, start(mini.command("lease", "login-automatic", "--task", "report", "--reason", "Nightly report.")), "lease")
		if got.err != nil {
			t.Fatalf("Automatic lease: %v\n%s", got.err, got.stderr)
		}
		read := wait(t, start(mini.command("read", strings.TrimSpace(got.stdout), "--field", "password")), "read")
		if read.err != nil || read.stdout != "example-automatic-password" {
			t.Fatalf("read: %v, %d bytes\n%s", read.err, len(read.stdout), read.stderr)
		}
	})
}
