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
	"fmt"
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

	t.Run("an agent finds the login", func(t *testing.T) {
		got := wait(t, start(linux.command("find", "example.com")), "find")
		if got.err != nil || !strings.Contains(got.stdout, "login-ask") || !strings.Contains(got.stdout, "agent@example.com") {
			t.Fatalf("find: %v\n%s%s", got.err, got.stdout, got.stderr)
		}
	})

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

	t.Run("Stop on a device ends the approval, and the agent is told so", func(t *testing.T) {
		asking := start(linux.command("lease", "login-ask", "--task", "stop", "--reason", "You asked me to check the invoice."))
		r.device("answer", "--approve")
		got := wait(t, asking, "lease")
		if got.err != nil {
			t.Fatalf("lease: %v\n%s", got.err, got.stderr)
		}
		lease := strings.TrimSpace(got.stdout)
		r.device("stop", "--request", lease)
		status := wait(t, start(linux.command("status", lease)), "status")
		if !strings.Contains(status.stdout, lease+": stopped by Josh") {
			t.Fatalf("want stopped by Josh, got %q %v", status.stdout, status.err)
		}
		if read := wait(t, start(linux.command("read", lease, "--field", "password")), "read"); read.err == nil {
			t.Fatalf("a stopped approval still delivered")
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

	t.Run("a device answers its practice request at first run", func(t *testing.T) {
		out := r.device("self-test")
		if !strings.Contains(out, `Agent Keyring (Practice) wants example.com, you@example.com: "This is a practice request. No real password is used."`) ||
			!strings.Contains(out, "Practice request: LEASE_STATE_APPROVED") {
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

	t.Run("a relay that replays the past cannot make a login Automatic again", func(t *testing.T) {
		past := t.TempDir()
		copyDir(t, relayState, past) // The relay's state while the login was Automatic.
		r.device("withdraw-automatic")
		asks := func(label string) string {
			got := wait(t, start(mini.command("lease", "login-automatic", "--task", label, "--reason", "Nightly report.", "--no-wait")), "lease")
			if got.err != nil {
				t.Fatalf("lease: %v\n%s", got.err, got.stderr)
			}
			id := strings.TrimSpace(got.stdout)
			status := wait(t, start(mini.command("status", id)), "status")
			wait(t, start(mini.command("release", id)), "release")
			return status.stdout
		}
		if now := asks("after-withdrawal"); !strings.Contains(now, ": pending") {
			t.Fatalf("after the login went back to Ask, the machine still got it without asking: %q", now)
		}
		stopRelay()
		os.RemoveAll(relayState)
		copyDir(t, past, relayState)
		stopRelay = startRelay(t, p, address, relayState)
		if replayed := asks("replayed"); !strings.Contains(replayed, ": pending") {
			t.Fatalf("a relay serving the old catalogue gave the machine the login without asking: %q", replayed)
		}
	})
}

// Josh denies adding a computer, with words, first the computer that stays on
// while the relay has no members yet, then a later one. The agent waiting on
// enrol hears at once; a stranger on the tailnet cannot deny for him.
func TestJoshDeniesAComputer(t *testing.T) {
	p := build(t)
	address := freePort(t)
	stopRelay := startRelay(t, p, address, t.TempDir())
	defer stopRelay()
	r := &run{t: t, programs: p, relay: address, deviceState: t.TempDir()}
	r.device("init", "--relay", address, "--keys-only") // As the Mac when setup-relay starts.
	stranger := t.TempDir()
	if out, err := exec.Command(p.device, "init", "--state", stranger, "--relay", address, "--keys-only").CombinedOutput(); err != nil {
		t.Fatalf("stranger: %v\n%s", err, out)
	}
	// refuse runs refuse-joins until a join is waiting, and returns what it said.
	refuse := func(state string, args ...string) (string, error) {
		for deadline := time.Now().Add(20 * time.Second); ; time.Sleep(200 * time.Millisecond) {
			out, err := exec.Command(p.device, append([]string{"refuse-joins", "--state", state}, args...)...).CombinedOutput()
			if !strings.Contains(string(out), "nothing is waiting to join") || time.Now().After(deadline) {
				return string(out), err
			}
		}
	}

	mini := r.newMachine()
	joining := start(mini.command("enrol", "--name", "Mac mini", "--invite", strings.TrimSpace(r.device("invite"))))
	if out, err := refuse(stranger, "--reply", "Run this instead."); err == nil || !strings.Contains(out, "Only the device that invited this computer can refuse it.") {
		t.Fatalf("a stranger refused the join: %v\n%s", err, out)
	}
	select {
	case got := <-joining:
		t.Fatalf("enrol stopped after the stranger's refusal: %v\n%s", got.err, got.stderr)
	default:
	}
	if out, err := refuse(r.deviceState, "--reply", "Not the mini. Use the Linux server."); err != nil {
		t.Fatalf("refuse-joins: %v\n%s", err, out)
	}
	got := wait(t, joining, "enrol")
	if got.err == nil || !strings.Contains(got.stderr, "Josh denied adding this computer. Reply: Not the mini. Use the Linux server.") {
		t.Fatalf("enrol: %v\n%s", got.err, got.stderr)
	}

	r.device("init", "--relay", address) // The relay now has members: a later computer.
	linux := r.newMachine()
	joining = start(linux.command("enrol", "--name", "Linux server", "--invite", strings.TrimSpace(r.device("invite"))))
	if out, err := refuse(r.deviceState); err != nil {
		t.Fatalf("refuse-joins: %v\n%s", err, out)
	}
	got = wait(t, joining, "enrol")
	if got.err == nil || !strings.Contains(got.stderr, "Josh denied adding this computer.") || strings.Contains(got.stderr, "Reply:") {
		t.Fatalf("enrol: %v\n%s", got.err, got.stderr)
	}
}

// The agent in Josh's first run runs install, which switches this Mac's
// agents from 0.2.5 to the new app in one go, and leaves Claude Code's
// read-only, Nix-made folder as it is. Agents still following 0.2.5's
// instructions are told to reread them, or reach their earlier buffer.
// install --undo puts every link back exactly.
func TestInstallSwitchesThisMacsAgentsAndBack(t *testing.T) {
	p := build(t)
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

	got := agent(app+"/Helpers/agent-keyring", "install")
	if exitCode(got) != 0 || !strings.Contains(got.stderr, "Not changed: "+home+"/.claude/skills/agent-keyring. Its folder is read-only") ||
		!strings.Contains(got.stderr, "install --undo") {
		t.Fatalf("install: %v\n%s", got.err, got.stderr)
	}
	if found := targets(); fmt.Sprint(found) != fmt.Sprint(switched) {
		t.Fatalf("after install the links are %v", found)
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

	if got = agent(command0, "install"); exitCode(got) != 0 || !strings.Contains(got.stderr, "Already linked: "+home+"/.codex/skills/agent-keyring") {
		t.Fatalf("install again: %v\n%s", got.err, got.stderr)
	}
	if found := targets(); fmt.Sprint(found) != fmt.Sprint(switched) {
		t.Fatalf("after installing again the links are %v", found)
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
	p := build(t)
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

func copyDir(t *testing.T, from, to string) {
	t.Helper()
	if out, err := exec.Command("cp", "-R", from+"/.", to).CombinedOutput(); err != nil {
		t.Fatalf("copy %s: %v %s", from, err, out)
	}
}
