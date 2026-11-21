// Written by AI on 2026.11.18 by model claude opus 5.5; the direct design (no relay) on 2026.11.21.
//
// The whole path an agent and Josh take, with the real command and
// stand-ins for Josh's Mac, iPhone and Apple Watch and for Apple's push
// service, whose software keys take the place of the devices' chips
// (developer/test-device). A computer joins the Mac's door; agents there
// ask; the command pushes each request to the iPhone and Apple Watch itself
// and takes their answers at its own door. Every program runs as its own
// process, on loopback, with made-up passwords and a made-up push key.
package e2e

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"testing"
	"time"
)

type programs struct{ command, device string }

// bin is the command and the stand-ins, built once for every test.
var bin programs

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "akr-e2e-bin-")
	if err != nil {
		panic(err)
	}
	bin = programs{filepath.Join(dir, "agent-keyring"), filepath.Join(dir, "test-device")}
	for output, source := range map[string]string{bin.command: "./cmd/agent-keyring", bin.device: "./developer/test-device"} {
		command := exec.Command("go", "build", "-o", output, source)
		command.Dir = ".."
		if out, err := command.CombinedOutput(); err != nil {
			os.RemoveAll(dir)
			fmt.Fprintf(os.Stderr, "build %s: %v\n%s", source, err, out)
			os.Exit(1)
		}
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
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

func wait(t *testing.T, done chan result, label string) result {
	t.Helper()
	select {
	case r := <-done:
		return r
	case <-time.After(45 * time.Second):
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

// lockedBuffer is a background program's output, read while it runs.
type lockedBuffer struct {
	mu  chan struct{}
	buf bytes.Buffer
}

func newBuffer() *lockedBuffer { return &lockedBuffer{mu: make(chan struct{}, 1)} }
func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu <- struct{}{}
	defer func() { <-b.mu }()
	return b.buf.Write(p)
}
func (b *lockedBuffer) String() string {
	b.mu <- struct{}{}
	defer func() { <-b.mu }()
	return b.buf.String()
}

// world is Josh's devices: the Mac's door and Apple, each its own process.
type world struct {
	t       *testing.T
	devices string // The stand-ins' state.
	apple   string
	macLog  *lockedBuffer
	stopMac func()
}

func newWorld(t *testing.T, macFlags ...string) *world {
	w := &world{t: t, devices: t.TempDir(), apple: freePort(t)}
	w.device("init", "--door", freePort(t))
	w.background("apple", "--listen", w.apple)
	for deadline := time.Now().Add(10 * time.Second); ; time.Sleep(50 * time.Millisecond) {
		if _, err := os.Stat(filepath.Join(w.devices, "apple-ca.pem")); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the stand-in for Apple did not start")
		}
	}
	w.macLog, w.stopMac = w.background(append([]string{"mac"}, macFlags...)...)
	return w
}

// background runs a stand-in until the test ends, or until stop.
func (w *world) background(args ...string) (*lockedBuffer, func()) {
	ctx, cancel := context.WithCancel(context.Background())
	command := exec.CommandContext(ctx, bin.device, append(args[:1:1], append([]string{"--state", w.devices}, args[1:]...)...)...)
	output := newBuffer()
	command.Stdout, command.Stderr = output, output
	if err := command.Start(); err != nil {
		w.t.Fatal(err)
	}
	stopped := false
	stop := func() {
		if !stopped {
			stopped = true
			cancel()
			command.Wait()
		}
	}
	w.t.Cleanup(func() {
		stop()
		if w.t.Failed() {
			w.t.Logf("test-device %s:\n%s", args[0], output)
		}
	})
	return output, stop
}

func (w *world) device(args ...string) string {
	w.t.Helper()
	out, err := w.tryDevice(args...)
	if err != nil {
		w.t.Fatalf("test-device %v: %v\n%s", args, err, out)
	}
	return out
}

func (w *world) tryDevice(args ...string) (string, error) {
	out, err := exec.Command(bin.device, append(args[:1:1], append([]string{"--state", w.devices}, args[1:]...)...)...).CombinedOutput()
	return string(out), err
}

// computer is one computer without the Mac app: its private state and the
// loopback address that stands in for its Tailscale IP.
type computer struct {
	w           *world
	state, door string
	env         []string
}

func (w *world) newComputer() *computer {
	state := w.t.TempDir()
	os.Chmod(state, 0o700) // The command refuses state others could read.
	c := &computer{w: w, state: state, door: freePort(w.t)}
	c.env = []string{"AGENT_KEYRING_STATE_DIR=" + state, "AGENT_KEYRING_SOCKET=", "AGENT_KEYRING_TEST_DOOR=" + c.door,
		"AGENT_KEYRING_TEST_APNS_GATEWAY=https://" + w.apple, "AGENT_KEYRING_TEST_APNS_CA=" + filepath.Join(w.devices, "apple-ca.pem"),
		"AGENT_KEYRING_TEST_ANSWER_WITHIN=8s"}
	return c
}

func (c *computer) command(args ...string) *exec.Cmd {
	command := exec.Command(bin.command, args...)
	command.Env = append(os.Environ(), c.env...)
	return command
}

func (c *computer) run(args ...string) result {
	c.w.t.Helper()
	return wait(c.w.t, start(c.command(args...)), strings.Join(args, " "))
}

// enrol joins the computer to the Mac's door, Josh approving on the Mac.
func (c *computer) enrol(name string) {
	t := c.w.t
	t.Helper()
	joining := start(c.command("enrol", "--name", name, "--invite", strings.TrimSpace(c.w.device("invite"))))
	for deadline := time.Now().Add(20 * time.Second); ; time.Sleep(200 * time.Millisecond) {
		c.w.tryDevice("approve-joins")
		select {
		case got := <-joining:
			if got.err != nil || !strings.Contains(got.stderr, "Joined") {
				t.Fatalf("%s did not join: %v\n%s", name, got.err, got.stderr)
			}
			return
		default:
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s is still waiting to join", name)
		}
	}
}

// visiblePushes is how many requests Apple delivered to a device to be shown.
func (w *world) visiblePushes(device string) int {
	entries, _ := os.ReadDir(filepath.Join(w.devices, "pushes", device))
	count := 0
	for _, entry := range entries {
		if raw, err := os.ReadFile(filepath.Join(w.devices, "pushes", device, entry.Name())); err == nil && strings.HasSuffix(entry.Name(), ".json") &&
			bytes.Contains(raw, []byte(`"visible":true`)) {
			count++
		}
	}
	return count
}

// waitForPushes waits until a device has had n requests to show.
func (w *world) waitForPushes(device string, n int) {
	w.t.Helper()
	for deadline := time.Now().Add(15 * time.Second); w.visiblePushes(device) < n; time.Sleep(50 * time.Millisecond) {
		if time.Now().After(deadline) {
			w.t.Fatalf("the %s has %d requests to show, not %d", device, w.visiblePushes(device), n)
		}
	}
}

var requestLine = regexp.MustCompile(`Request ([0-9a-f]{32}):`)

// answer has a device answer the next request pushed to it, and returns the
// request's id.
func (w *world) answer(args ...string) string {
	w.t.Helper()
	out := w.device(append([]string{"answer"}, args...)...)
	match := requestLine.FindStringSubmatch(out)
	if match == nil {
		w.t.Fatalf("test-device answer %v said %q", args, out)
	}
	return match[1]
}

// doorHolds is how many times a process of this computer has taken its door.
func (c *computer) doorHolds() int {
	raw, _ := os.ReadFile(filepath.Join(c.state, "agent-keyring.log"))
	return strings.Count(string(raw), " command door held ")
}

// doorHeld is true once something accepts connections at the computer's door.
func (c *computer) doorHeld() bool {
	conn, err := net.DialTimeout("tcp", c.door, 200*time.Millisecond)
	if err == nil {
		conn.Close()
	}
	return err == nil
}

func TestAnAgentAsksAndJoshAnswersFromHisIPhoneOrWatch(t *testing.T) {
	w := newWorld(t)
	linux := w.newComputer()
	linux.enrol("Linux server")
	ask := func(login, task string, extra ...string) *exec.Cmd {
		return linux.command(append([]string{"lease", login, "--task", task, "--reason", "You asked me to download October's invoice.", "--agent", "Codex"}, extra...)...)
	}

	t.Run("an agent finds the password", func(t *testing.T) {
		got := linux.run("find", "example.com")
		if got.err != nil || !strings.Contains(got.stdout, "login-ask") || !strings.Contains(got.stdout, "agent@example.com") {
			t.Fatalf("find: %v\n%s%s", got.err, got.stdout, got.stderr)
		}
	})

	t.Run("approved on the iPhone, a program gets the password through a pipe, and a stopped lease rejoins its request", func(t *testing.T) {
		before := w.visiblePushes("iphone")
		first := ask("login-ask", "invoice")
		asking := start(first)
		w.waitForPushes("iphone", before+1)
		first.Process.Signal(os.Interrupt) // The agent's tool stops the command early.
		wait(t, asking, "lease")
		asking = start(ask("login-ask", "invoice")) // The same task asks again: it rejoins.
		id := w.answer("--device", "iphone", "--approve")
		got := wait(t, asking, "lease")
		if got.err != nil || strings.TrimSpace(got.stdout) != id {
			t.Fatalf("lease: %v %q, want the request %s\n%s", got.err, got.stdout, id, got.stderr)
		}
		if pushed := w.visiblePushes("iphone") - before; pushed != 1 {
			t.Fatalf("the iPhone was asked %d times for one task", pushed)
		}
		// The locked iPhone's unsigned arrival note, by its push address.
		if logs := linux.run("logs", "--request", id); !strings.Contains(logs.stdout, "arrived id="+id+` device="Test iPhone"`) {
			t.Fatalf("the iPhone's arrival was not taken: %v\n%s%s", logs.err, logs.stdout, logs.stderr)
		}
		output := filepath.Join(t.TempDir(), "received")
		piped := linux.command("read", id, "--field", "password")
		piped.Path, piped.Args = "/bin/sh", []string{"/bin/sh", "-c", `"$0" read "$1" --field password | cat > "$2"`, bin.command, id, output}
		if used := wait(t, start(piped), "read | program"); used.err != nil {
			t.Fatalf("read | program: %v\n%s", used.err, used.stderr)
		}
		if received, _ := os.ReadFile(output); string(received) != "example-ask-password" {
			t.Fatalf("the program received %d bytes, not the password", len(received))
		}
		if released := linux.run("release", id); released.err != nil || !strings.Contains(released.stderr, "Lease released.") {
			t.Fatalf("release: %v\n%s", released.err, released.stderr)
		}
		if read := linux.run("read", id, "--field", "password"); read.err == nil || !strings.Contains(read.stderr, "This lease was released.") {
			t.Fatalf("after release, read: %v\n%s", read.err, read.stderr)
		}
	})

	t.Run("approved on the Apple Watch with the copy in its push", func(t *testing.T) {
		asking := start(ask("login-ask", "watch"))
		id := w.answer("--device", "watch", "--approve")
		got := wait(t, asking, "lease")
		if got.err != nil || strings.TrimSpace(got.stdout) != id {
			t.Fatalf("lease: %v\n%s", got.err, got.stderr)
		}
		if read := linux.run("read", id, "--field", "password"); read.err != nil || read.stdout != "example-ask-password" {
			t.Fatalf("read: %v\n%s", read.err, read.stderr)
		}
		// The Apple Watch's arrival note, signed with its reply key.
		if logs := linux.run("logs", "--request", id); !strings.Contains(logs.stdout, "arrived id="+id+` device="Test Apple Watch"`) {
			t.Fatalf("the Apple Watch's arrival was not taken: %v\n%s%s", logs.err, logs.stdout, logs.stderr)
		}
		linux.run("release", id)
	})

	t.Run("both devices answer: the first wins, and the other is told how it ended", func(t *testing.T) {
		before := w.visiblePushes("iphone")
		asking := start(ask("login-ask", "first-wins"))
		w.waitForPushes("iphone", before+1)
		keeper := start(ask("login-other", "keeps-the-door")) // Another agent here, still waiting.
		id := w.answer("--device", "iphone", "--approve")
		if got := wait(t, asking, "lease"); got.err != nil {
			t.Fatalf("lease: %v\n%s", got.err, got.stderr)
		}
		out := w.device("answer", "--device", "watch", "--request", id, "--deny", "No.")
		if !strings.Contains(out, "The door says: LEASE_STATE_APPROVED by Test iPhone") {
			t.Fatalf("the second answer was not told the first won: %s", out)
		}
		if out := w.device("outcome", "--device", "watch", "--request", id); !strings.Contains(out, "Outcome: LEASE_STATE_APPROVED by Test iPhone") {
			t.Fatalf("the Apple Watch was not told the outcome: %s", out)
		}
		if read := linux.run("read", id, "--field", "password"); read.err != nil || read.stdout != "example-ask-password" {
			t.Fatalf("read after a late denial: %v\n%s", read.err, read.stderr)
		}
		linux.run("release", linux.waiting(t, "login-other", "keeps-the-door"))
		wait(t, keeper, "the other lease")
		linux.run("release", id)
	})

	t.Run("Stop on the iPhone ends an approved lease, and the agent is told so", func(t *testing.T) {
		asking := start(ask("login-ask", "stop"))
		id := w.answer("--device", "iphone", "--approve")
		if got := wait(t, asking, "lease"); got.err != nil {
			t.Fatalf("lease: %v\n%s", got.err, got.stderr)
		}
		keeper := start(ask("login-other", "keeps-the-door-for-stop"))
		if out := w.device("stop", "--device", "iphone", "--request", id); !strings.Contains(out, "Stopped: LEASE_STATE_ENDED by Test iPhone") {
			t.Fatalf("stop: %s", out)
		}
		if status := linux.run("status", id); !strings.Contains(status.stdout, id+": ended: Josh stopped it on Test iPhone") {
			t.Fatalf("want Josh's Stop, got %q %v", status.stdout, status.err)
		}
		if read := linux.run("read", id, "--field", "password"); read.err == nil || !strings.Contains(read.stderr, "Josh stopped it on Test iPhone") {
			t.Fatalf("a stopped approval still delivered: %v\n%s", read.err, read.stderr)
		}
		linux.run("release", linux.waiting(t, "login-other", "keeps-the-door-for-stop"))
		wait(t, keeper, "the other lease")
	})

	t.Run("two agents wait on one computer; the door's holder is answered and exits, and the other is still answered", func(t *testing.T) {
		before := w.visiblePushes("iphone")
		first := start(ask("login-ask", "two-a"))
		for deadline := time.Now().Add(10 * time.Second); !linux.doorHeld(); time.Sleep(50 * time.Millisecond) {
			if time.Now().After(deadline) {
				t.Fatal("the first lease never held the door")
			}
		}
		w.waitForPushes("iphone", before+1)
		second := start(ask("login-other", "two-b"))
		w.waitForPushes("iphone", before+2)
		a := w.answer("--device", "iphone", "--approve")
		if got := wait(t, first, "the door's holder"); got.err != nil || strings.TrimSpace(got.stdout) != a {
			t.Fatalf("first lease: %v %q\n%s", got.err, got.stdout, got.stderr)
		}
		held := linux.doorHolds()
		b := w.answer("--device", "iphone", "--approve") // The second process takes the door within a second.
		got := wait(t, second, "the other lease")
		if got.err != nil || strings.TrimSpace(got.stdout) != b {
			t.Fatalf("second lease: %v %q\n%s", got.err, got.stdout, got.stderr)
		}
		if linux.doorHolds() <= held {
			t.Fatalf("the second lease was answered without taking the door over")
		}
		if read := linux.run("read", b, "--field", "password"); read.err != nil || read.stdout != "example-other-password" {
			t.Fatalf("read: %v\n%s", read.err, read.stderr)
		}
		linux.run("release", a)
		linux.run("release", b)
	})

	t.Run("nobody answers", func(t *testing.T) {
		asking := start(ask("login-ask", "silence"))
		id := w.answer("--device", "iphone", "--ignore")
		got := wait(t, asking, "lease")
		if got.err == nil || !strings.Contains(got.stderr, "No answer. Nobody answered within 10 minutes. This is not a refusal.") {
			t.Fatalf("want no answer, got %v\n%s", got.err, got.stderr)
		}
		if out := w.device("outcome", "--device", "iphone", "--request", id); !strings.Contains(out, "Outcome: LEASE_STATE_UNANSWERED") {
			t.Fatalf("the iPhone was not told: %s", out)
		}
	})

	t.Run("Automatic, with no question, and with the Mac shut", func(t *testing.T) {
		got := linux.run("lease", "login-automatic", "--task", "report", "--reason", "Nightly report.")
		if got.err != nil {
			t.Fatalf("Automatic lease: %v\n%s", got.err, got.stderr)
		}
		if read := linux.run("read", strings.TrimSpace(got.stdout), "--field", "password"); read.err != nil || read.stdout != "example-automatic-password" {
			t.Fatalf("read: %v\n%s", read.err, read.stderr)
		}
		w.stopMac()
		got = linux.run("lease", "login-automatic", "--task", "report-mac-shut", "--reason", "Nightly report.")
		if got.err != nil {
			t.Fatalf("Automatic lease with the Mac shut: %v\n%s", got.err, got.stderr)
		}
		id := strings.TrimSpace(got.stdout)
		if read := linux.run("read", id, "--field", "password"); read.err != nil || read.stdout != "example-automatic-password" {
			t.Fatalf("read with the Mac shut: %v\n%s", read.err, read.stderr)
		}
		logs := linux.run("logs", "--request", id)
		if logs.err != nil || !strings.Contains(logs.stdout, "automatic used without the Mac id="+id) {
			t.Fatalf("logs: %v\n%s%s", logs.err, logs.stdout, logs.stderr)
		}
		// An agent's complaint while the Mac is shut waits here, and goes at the next contact.
		complaining := linux.command("complain", "--summary", "The lease hung.", "--command", "lease login-ask", "--thread", "thread-1")
		complaining.Stdin = strings.NewReader("It waited and printed nothing.\n")
		if got := wait(t, start(complaining), "complain"); got.err != nil || !strings.Contains(got.stderr, "kept here and goes to the Mac at the next contact") {
			t.Fatalf("complain with the Mac shut: %v\n%s", got.err, got.stderr)
		}
		w.macLog, w.stopMac = w.background("mac")
		for deadline := time.Now().Add(10 * time.Second); ; time.Sleep(200 * time.Millisecond) {
			linux.run("find", "example.com") // A contact with the Mac.
			got := linux.run("complaints")
			if got.err == nil && strings.Contains(got.stdout, "Linux server") && strings.Contains(got.stdout, "The lease hung.") &&
				strings.Contains(got.stdout, "thread: thread-1") && strings.Contains(got.stdout, "It waited and printed nothing.") {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("the Mac never got the complaint: %v\n%s%s", got.err, got.stdout, got.stderr)
			}
		}
	})

	t.Run("an answer from a device Josh removed is refused", func(t *testing.T) {
		before := w.visiblePushes("watch")
		asking := start(ask("login-ask", "removed"))
		w.waitForPushes("watch", before+1)
		w.device("remove", "--device", "watch")
		var id string
		for _, line := range strings.Split(w.device("answer", "--device", "iphone", "--ignore"), "\n") {
			if match := requestLine.FindStringSubmatch(line); match != nil {
				id = match[1]
			}
		}
		out, err := w.tryDevice("answer", "--device", "watch", "--request", id, "--approve")
		if err == nil || !strings.Contains(out, "the door refused (403): This answer is not signed by a device in Josh's list of devices") {
			t.Fatalf("a removed Apple Watch's approval was taken: %v\n%s", err, out)
		}
		w.device("answer", "--device", "iphone", "--request", id, "--approve")
		if got := wait(t, asking, "lease"); got.err != nil || strings.TrimSpace(got.stdout) != id {
			t.Fatalf("lease: %v\n%s", got.err, got.stderr)
		}
		linux.run("release", id)
	})

	// Last: a denial holds this password off for this computer.
	t.Run("denied with Josh's words, and the next ask is held off with them", func(t *testing.T) {
		asking := start(ask("login-ask", "denied"))
		w.answer("--device", "iphone", "--deny", "The invoice is in my email. Use that.")
		got := wait(t, asking, "lease")
		if got.err == nil || !strings.Contains(got.stderr, "denied. Reply: The invoice is in my email. Use that.") {
			t.Fatalf("want a denial with words, got %v\n%s", got.err, got.stderr)
		}
		again := wait(t, start(ask("login-ask", "denied-again")), "lease")
		if again.err == nil || !strings.Contains(again.stderr, "Josh denied this password for this computer. Ask again after") ||
			!strings.Contains(again.stderr, "(in 1m0s). His reply, word for word: \"The invoice is in my email. Use that.\"") {
			t.Fatalf("a denial holds the password off for a minute and says why; got %v\n%s", again.err, again.stderr)
		}
	})
}

// waiting is the id of the request a task already has waiting: asking again
// for the same task rejoins it, and --no-wait prints its id.
func (c *computer) waiting(t *testing.T, login, task string) string {
	t.Helper()
	got := c.run("lease", login, "--task", task, "--reason", "You asked me to download October's invoice.", "--no-wait")
	if got.err != nil {
		t.Fatalf("lease --no-wait: %v\n%s", got.err, got.stderr)
	}
	return strings.TrimSpace(got.stdout)
}

// Joining the Mac goes wrong the ways a person would hit: an invitation
// that names the Mac by a name or an address off the tailnet, Josh denying
// it, the agent stopping, nobody answering, and no Tailscale here at all.
func TestJoiningTheMacGoesWrong(t *testing.T) {
	w := newWorld(t, "--join-within", "3s")

	t.Run("an invitation naming the Mac by a name is refused", func(t *testing.T) {
		c := w.newComputer()
		got := c.run("enrol", "--name", "Linux server", "--invite", strings.TrimSpace(w.device("invite", "--host", "mac.example.ts.net")))
		if got.err == nil || !strings.Contains(got.stderr, `"mac.example.ts.net" is a name, not a Tailscale IP address.`) {
			t.Fatalf("enrol: %v\n%s", got.err, got.stderr)
		}
	})

	t.Run("an invitation naming an address off the tailnet is refused", func(t *testing.T) {
		c := w.newComputer()
		got := c.run("enrol", "--name", "Linux server", "--invite", strings.TrimSpace(w.device("invite", "--host", "192.168.1.20")))
		if got.err == nil || !strings.Contains(got.stderr, "192.168.1.20 is not a Tailscale address.") {
			t.Fatalf("enrol: %v\n%s", got.err, got.stderr)
		}
	})

	t.Run("a computer without Tailscale says so", func(t *testing.T) {
		c := w.newComputer()
		c.env = append(c.env, "AGENT_KEYRING_TEST_DOOR=none")
		got := c.run("enrol", "--name", "Linux server", "--invite", strings.TrimSpace(w.device("invite")))
		if got.err == nil || !strings.Contains(got.stderr, "This computer has no Tailscale address: Tailscale is not installed, not running, or signed out.") {
			t.Fatalf("enrol: %v\n%s", got.err, got.stderr)
		}
	})

	t.Run("Josh denies it with words", func(t *testing.T) {
		c := w.newComputer()
		joining := start(c.command("enrol", "--name", "Mac mini", "--invite", strings.TrimSpace(w.device("invite"))))
		for deadline := time.Now().Add(10 * time.Second); ; time.Sleep(100 * time.Millisecond) {
			if _, err := w.tryDevice("refuse-joins", "--reply", "Not the mini. Use the Linux server."); err == nil {
				break
			}
			if time.Now().After(deadline) {
				t.Fatal("no join to refuse")
			}
		}
		got := wait(t, joining, "enrol")
		if got.err == nil || !strings.Contains(got.stderr, "Josh denied adding this computer. Reply: Not the mini. Use the Linux server.") {
			t.Fatalf("enrol: %v\n%s", got.err, got.stderr)
		}
	})

	t.Run("the agent stops waiting, and the join is withdrawn", func(t *testing.T) {
		c := w.newComputer()
		enrol := c.command("enrol", "--name", "Mac mini", "--invite", strings.TrimSpace(w.device("invite")))
		var stderr lockedBuffer
		stderr.mu = make(chan struct{}, 1)
		enrol.Stderr = &stderr
		if err := enrol.Start(); err != nil {
			t.Fatal(err)
		}
		for deadline := time.Now().Add(10 * time.Second); !strings.Contains(stderr.String(), "Waiting for Josh to approve"); time.Sleep(50 * time.Millisecond) {
			if time.Now().After(deadline) {
				t.Fatalf("enrol never waited: %s", stderr.String())
			}
		}
		enrol.Process.Signal(syscall.SIGINT)
		err := enrol.Wait()
		if err == nil || !strings.Contains(stderr.String(), "Stopped asking to join. The request on the Mac was withdrawn.") ||
			!strings.Contains(w.macLog.String(), `"Mac mini" withdrew its join.`) {
			t.Fatalf("enrol: %v\n%s\nMac: %s", err, stderr.String(), w.macLog)
		}
	})

	t.Run("nobody answers", func(t *testing.T) {
		c := w.newComputer()
		got := c.run("enrol", "--name", "Mac mini", "--invite", strings.TrimSpace(w.device("invite")))
		if got.err == nil || !strings.Contains(got.stderr, "Nobody approved this computer within 10 minutes.") {
			t.Fatalf("enrol: %v\n%s", got.err, got.stderr)
		}
	})
}

// Josh's Mac as the first run of 20 November left it: an earlier install
// switched the command and Codex's link to the new app and wrote down what
// they were. install no longer changes any link; agents still following
// 0.2.5's instructions are told to reread them, or reach their earlier
// buffer; install --undo still puts every link back exactly.
func TestLinksAnEarlierInstallChangedStayHisToPutBack(t *testing.T) {
	p := bin
	scratch := t.TempDir()
	home := filepath.Join(scratch, "home")
	app := filepath.Join(scratch, "Applications/Agent Keyring.app/Contents")
	old := filepath.Join(scratch, "Applications/AgentKeyring.app/Contents")
	files := map[string]string{
		app + "/Resources/AgentTools/AgentSkill/agent-keyring/SKILL.md": "new skill\n",
		app + "/Resources/AgentTools/BrowserExtension/manifest.json":    "{}\n",
		old + "/Resources/AgentTools/CodexSkill/agent-keyring/SKILL.md": "0.2.5 skill\n",
		// 0.2.5's command, as far as read and clear go: it notes its arguments.
		old + "/Helpers/agent-keyring": "#!/bin/sh\necho \"$@\" >> \"$(dirname \"$0\")/calls\"\n[ \"$1\" = read ] && printf earlier-value\nexit 0\n",
	}
	for path, text := range files {
		os.MkdirAll(filepath.Dir(path), 0o755)
		if err := os.WriteFile(path, []byte(text), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	command, err := os.ReadFile(p.command)
	if err != nil {
		t.Fatal(err)
	}
	os.MkdirAll(app+"/Helpers", 0o755)
	if err := os.WriteFile(app+"/Helpers/agent-keyring", command, 0o755); err != nil {
		t.Fatal(err)
	}
	links := map[string]string{
		home + "/.local/bin/agent-keyring":     old + "/Helpers/agent-keyring",
		home + "/.codex/skills/agent-keyring":  old + "/Resources/AgentTools/CodexSkill/agent-keyring",
		home + "/.claude/skills/agent-keyring": old + "/Resources/AgentTools/CodexSkill/agent-keyring",
	}
	for link, target := range links {
		os.MkdirAll(filepath.Dir(link), 0o755)
		if err := os.Symlink(target, link); err != nil {
			t.Fatal(err)
		}
	}
	os.Chmod(home+"/.claude/skills", 0o555) // Made by Nix: nobody else writes there.
	defer os.Chmod(home+"/.claude/skills", 0o755)

	agent := func(path string, args ...string) result {
		command := exec.Command(path, args...)
		command.Env = append(os.Environ(), "HOME="+home, "XDG_STATE_HOME=", "XDG_CONFIG_HOME=", "AGENT_KEYRING_STATE_DIR=", "CODEX_HOME=")
		return wait(t, start(command), strings.Join(args, " "))
	}
	exitCode := func(r result) int {
		if exit, ok := r.err.(*exec.ExitError); ok {
			return exit.ExitCode()
		}
		if r.err != nil {
			t.Fatal(r.err)
		}
		return 0
	}
	targets := func() map[string]string {
		found := map[string]string{}
		for link := range links {
			found[link], _ = os.Readlink(link)
		}
		return found
	}
	newCommand, _ := filepath.EvalSymlinks(app + "/Helpers/agent-keyring")
	newSkill, _ := filepath.EvalSymlinks(app + "/Resources/AgentTools/AgentSkill/agent-keyring")
	switched := map[string]string{
		home + "/.local/bin/agent-keyring":     newCommand,
		home + "/.codex/skills/agent-keyring":  newSkill,
		home + "/.claude/skills/agent-keyring": links[home+"/.claude/skills/agent-keyring"],
	}

	record := map[string]map[string]string{}
	for _, link := range []string{home + "/.local/bin/agent-keyring", home + "/.codex/skills/agent-keyring"} {
		os.Remove(link)
		if err := os.Symlink(switched[link], link); err != nil {
			t.Fatal(err)
		}
		record[link] = map[string]string{"previous": links[link], "installed": switched[link]}
	}
	recorded, _ := json.Marshal(record)
	os.MkdirAll(home+"/.local/state/agent-keyring", 0o755)
	if err := os.WriteFile(home+"/.local/state/agent-keyring/replaced-links.json", recorded, 0o600); err != nil {
		t.Fatal(err)
	}

	got := agent(app+"/Helpers/agent-keyring", "install")
	if exitCode(got) != 0 || !strings.Contains(got.stderr, "no longer links itself") || !strings.Contains(got.stderr, "skill") {
		t.Fatalf("install: %v\n%s", got.err, got.stderr)
	}
	if found := targets(); fmt.Sprint(found) != fmt.Sprint(switched) {
		t.Fatalf("install changed the links: %v", found)
	}

	command0 := home + "/.local/bin/agent-keyring" // What agents run.
	for _, args := range [][]string{{"acquire", "password", "example.com"}, {"status"}, {"copy", "password", "example.com"},
		{"find", "example.com", "--account", "me"}, {"acquire", "code", "example.com", "--credential", "6F9619FF-8B86-D011-B42D-00C04FC964FF"}} {
		got := agent(command0, args...)
		if exitCode(got) != 2 || strings.TrimSpace(got.stderr) != "agent-keyring: Agent Keyring has changed since your instructions were written. Run `agent-keyring skill` and follow it." {
			t.Fatalf("%v: %v\n%s", args, got.err, got.stderr)
		}
	}
	reference := "6F9619FF-8B86-D011-B42D-00C04FC964FF"
	got = agent(command0, "read", reference)
	if exitCode(got) != 0 || got.stdout != "earlier-value" || !strings.Contains(got.stderr, "This read uses the earlier version") {
		t.Fatalf("read: %v %q\n%s", got.err, got.stdout, got.stderr)
	}
	if got = agent(command0, "clear", reference); exitCode(got) != 0 {
		t.Fatalf("clear: %v\n%s", got.err, got.stderr)
	}
	if calls, _ := os.ReadFile(old + "/Helpers/calls"); string(calls) != "read "+reference+"\nclear "+reference+"\n" {
		t.Fatalf("0.2.5's command was run with %q", calls)
	}

	got = agent(app+"/Helpers/agent-keyring", "install", "--undo")
	if exitCode(got) != 0 {
		t.Fatalf("undo: %v\n%s", got.err, got.stderr)
	}
	if found := targets(); fmt.Sprint(found) != fmt.Sprint(links) {
		t.Fatalf("after undo the links are %v, not %v", found, links)
	}
	if got = agent(app+"/Helpers/agent-keyring", "install", "--undo"); exitCode(got) != 1 || !strings.Contains(got.stderr, "Nothing to undo") {
		t.Fatalf("undo again: %v\n%s", got.err, got.stderr)
	}
	// With no earlier command recorded, an earlier reference only gets the message.
	if got = agent(app+"/Helpers/agent-keyring", "read", reference); exitCode(got) != 2 || got.stdout != "" ||
		strings.TrimSpace(got.stderr) != "agent-keyring: Agent Keyring has changed since your instructions were written. Run `agent-keyring skill` and follow it." {
		t.Fatalf("read with nothing recorded: %v\n%s", got.err, got.stderr)
	}
}

// An agent lists the computers on the tailnet to ask which ones to set up.
// A stand-in tailscale command prints what Tailscale's own prints.
func TestMachinesListsTheTailnet(t *testing.T) {
	p := bin
	bin := t.TempDir()
	status := `{"Self": {"HostName": "Example’s MacBook Pro", "DNSName": "laptop.example.ts.net.", "OS": "macOS", "Online": true},
	  "Peer": {
	    "nodekey:1": {"HostName": "server", "DNSName": "server.example.ts.net.", "OS": "linux", "Online": false},
	    "nodekey:2": {"HostName": "localhost", "DNSName": "phone.example.ts.net.", "OS": "iOS", "Online": true},
	    "nodekey:3": {"HostName": "mini", "DNSName": "mac-mini.example.ts.net.", "OS": "macOS", "Online": true}}}`
	if err := os.WriteFile(filepath.Join(bin, "tailscale"), []byte("#!/bin/sh\ncat <<'END'\n"+status+"\nEND\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(p.command, "machines")
	command.Env = append(os.Environ(), "PATH="+bin+":/usr/bin:/bin")
	out, err := command.CombinedOutput()
	want := `COMPUTER                SYSTEM  ONLINE  ADDRESS
laptop (this computer)  macOS   yes     laptop.example.ts.net
mac-mini                macOS   yes     mac-mini.example.ts.net
server                  linux   no      server.example.ts.net
`
	if err != nil || string(out) != want {
		t.Fatalf("machines: %v\n%s", err, out)
	}
}
