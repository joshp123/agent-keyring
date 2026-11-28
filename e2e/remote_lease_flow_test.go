// Written by AI on 2026.11.27 by model gpt-6.2-sol.
package e2e

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/opentrawl/agent-keyring/internal/clientstate"
)

func TestRemoteComputerFollowsMacChanges(t *testing.T) {
	mac := newRealMac(t)
	peer := mac.startMacTestPeer(t)
	cli := mac.testComputer("remote", false)
	github, docs := importRealMac(t, peer)
	cli.enrolTestComputer(t, peer, "Build server")
	assertFind(t, cli.runComputerCommand(t, "find", "github.example"), github, "github.example", "Ask")
	assertFind(t, cli.runComputerCommand(t, "find", "docs.example"), docs, "docs.example", "Automatic")
	automatic := automaticLease(t, cli, docs, "before-block")
	assertPassword(t, cli.runComputerCommand(t, "read", automatic, "--field", "password"), "pw-docs.example")

	later := peer.sendPeerCommand(t, "IMPORT_LATER")
	waitForFind(t, cli, later, "new.example", "Automatic")
	latest := automaticLease(t, cli, later, "later-import")
	assertPassword(t, cli.runComputerCommand(t, "read", latest, "--field", "password"), "pw-new.example")

	peer.expectOK(t, "SET_RULE "+later+" ask")
	waitForFind(t, cli, later, "new.example", "Ask")
	peer.expectOK(t, "SET_RULE "+docs+" blocked")
	waitForFind(t, cli, docs, "docs.example", "Blocked")
	assertRefused(t, cli.requestTestLease(t, docs, "after-block")(), "This password is blocked")
	assertRefused(t, cli.runComputerCommand(t, "read", automatic, "--field", "password"), "This password is no longer Automatic for this computer")

	peer.expectOK(t, "REMOVE_COMPUTER Build server")
	waitForRefusal(t, cli, "removed this computer", "find", "github.example")
	assertRefused(t, cli.runComputerCommand(t, "read", latest, "--field", "password"), "This lease was released")
	peer.quitPeerProcess(t)
}

func TestRemoteMacAnswersAndStops(t *testing.T) {
	mac := newRealMac(t, "--test-ttl-scale", boxLifetimes)
	peer := mac.startMacTestPeer(t)
	cli := mac.testComputer("remote", false)
	github, docs := importRealMac(t, peer)
	cli.enrolTestComputer(t, peer, "Build server")

	id := approveRemote(t, peer, cli, "mac", github, "mac-approval")
	assertPassword(t, cli.runComputerCommand(t, "read", id, "--field", "password"), "pw-github.example")
	assertCode(t, cli, id)
	peer.expectOK(t, "STOP_REMOTE mac "+id)
	assertStopped(t, cli, id, "The user stopped it on")

	waiting := cli.requestTestLease(t, github, "mac-denial")
	denied := peer.sendPeerCommand(t, "WAIT_REMOTE mac")
	peer.expectOK(t, "DENY_REMOTE mac "+denied)
	assertRefused(t, waiting(), "denied")
	peer.quitPeerProcess(t)

	// Automatic stays available with the approving Mac shut down.
	automatic := automaticLease(t, cli, docs, "mac-closed")
	assertPassword(t, cli.runComputerCommand(t, "read", automatic, "--field", "password"), "pw-docs.example")
}

func TestRemotePhoneAnswersAndStopsAfterAnswerExpires(t *testing.T) {
	mac := newRealMac(t, "--test-ttl-scale", boxLifetimes)
	peer := mac.startMacTestPeer(t)
	github, _ := importRealMac(t, peer)
	peer.expectOK(t, "ENROL_PHONE")
	cli := mac.testComputer("remote", false)
	cli.enrolTestComputer(t, peer, "Build server")

	id := approveOnPhoneWithMacWaiting(t, peer, cli, github)
	peer.expectOK(t, "WAIT_OUTCOME phone "+id+" approved")
	peer.expectOK(t, "WAIT_OUTCOME mac "+id+" approved")
	peer.expectOK(t, "DENY_REMOTE mac "+id+" Too late to change the answer.")
	assertPassword(t, cli.runComputerCommand(t, "read", id, "--field", "password"), "pw-github.example")
	assertCode(t, cli, id)
	peer.expectOK(t, "STOP_REMOTE phone "+id)
	assertStopped(t, cli, id, "The user stopped it on iPhone")
	time.Sleep(13 * time.Second) // All answer and join boxes have expired. The grant has not.
	assertStopped(t, cli, id, "The user stopped it on iPhone")
	assertStatus(t, cli, id, "ended: The user stopped it on iPhone")

	denyOnPhone(t, peer, cli, github)
	peer.quitPeerProcess(t)
}

func TestMacAndPhoneConvergeOnConcurrentRules(t *testing.T) {
	for _, tc := range []struct {
		order  string
		winner string
	}{
		{"tie", "Blocked"},
		{"mac-newer", "Automatic"},
		{"phone-newer", "Blocked"},
	} {
		t.Run(tc.order, func(t *testing.T) {
			mac := newRealMac(t)
			peer := mac.startMacTestPeer(t)
			github, _ := importRealMac(t, peer)
			cli := mac.testComputer("remote", false)
			cli.enrolTestComputer(t, peer, "Build server")
			peer.expectOK(t, "ENROL_PHONE")
			assertFind(t, cli.runComputerCommand(t, "find", "github.example"), github, "github.example", "Ask")
			peer.expectOK(t, "CONTEST_RULE "+github+" "+tc.order)
			waitForFind(t, cli, github, "github.example", tc.winner)
			if tc.winner == "Blocked" {
				assertRefused(t, cli.requestTestLease(t, github, "after-convergence")(), "This password is blocked")
			} else {
				id := automaticLease(t, cli, github, "after-convergence")
				assertPassword(t, cli.runComputerCommand(t, "read", id, "--field", "password"), "pw-github.example")
			}
			peer.quitPeerProcess(t)
		})
	}
}

func TestComputerRefusesAnAnswerFromARemovedPhone(t *testing.T) {
	mac := newRealMac(t)
	peer := mac.startMacTestPeer(t)
	github, _ := importRealMac(t, peer)
	peer.expectOK(t, "ENROL_PHONE")
	cli := mac.testComputer("remote", false)
	cli.env = append(cli.env, "AGENT_KEYRING_TEST_ANSWER_WITHIN=12s")
	cli.enrolTestComputer(t, peer, "Build server")
	id := leaseID(t, cli.requestTestLease(t, github, "removed-phone", "--no-wait")())
	if got := peer.sendPeerCommand(t, "WAIT_REMOTE phone"); got != id {
		t.Fatalf("iPhone was asked %s, want %s", got, id)
	}
	// The answer sits in its box until the agent checks the lease again.
	peer.expectOK(t, "APPROVE_REMOTE phone "+id)
	revision := peer.sendPeerCommand(t, "REMOVE_PHONE")
	eventually(t, "computer to take the Mac's updated members", func() bool {
		assertFind(t, cli.runComputerCommand(t, "find", "github.example"), github, "github.example", "Ask")
		return strings.Contains(cli.runComputerCommand(t, "logs").stdout, "members taken revision="+revision+"\n")
	})
	assertRefused(t, cli.runComputerCommand(t, "status", id, "--wait"), "No answer.")
	logs := cli.runComputerCommand(t, "logs", "--request", id)
	assertSuccess(t, logs)
	if !strings.Contains(logs.stdout, "answer refused id="+id+" route=box") {
		t.Fatalf("the computer did not see and refuse the removed phone's answer: %s", logs.stdout)
	}
	peer.quitPeerProcess(t)
}

func TestMacRefusesComputerJoinWithWords(t *testing.T) {
	mac := newRealMac(t)
	peer := mac.startMacTestPeer(t)
	importRealMac(t, peer)
	cli := mac.testComputer("remote", false)
	code := peer.sendPeerCommand(t, "INVITE_CODE")
	waiting := cli.beginComputerCommand(t, "enrol", "--name", "Old server", "--code", code)
	const words = "Use the other server."
	peer.expectOK(t, "REFUSE_JOIN "+words)
	assertRefused(t, waiting(), "The user denied adding this computer. Reply: "+words)
	peer.quitPeerProcess(t)
}

func TestAgentStopsWaitingToJoin(t *testing.T) {
	mac := newRealMac(t)
	peer := mac.startMacTestPeer(t)
	importRealMac(t, peer)
	code := peer.sendPeerCommand(t, "INVITE_CODE")
	cli := mac.testComputer("remote", false)
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	defer cancel()
	cmd := cli.buildComputerCommand(ctx, "enrol", "--name", "Old server", "--code", code)
	stderr := newBuffer()
	var stdout bytes.Buffer
	done := startWithStderr(cmd, &stdout, stderr)
	finish := sync.OnceValue(func() cliProcessResult { return <-done })
	defer func() { cancel(); finish() }()
	eventually(t, "CLI waiting for join approval", func() bool {
		return strings.Contains(stderr.String(), "Waiting for the user to approve")
	})
	if err := cmd.Process.Signal(os.Interrupt); err != nil {
		t.Fatal(err)
	}
	got := finish()
	assertRefused(t, got, "Stopped waiting to join. The request on the Mac ends by itself within 10 minutes.")
	peer.quitPeerProcess(t)
}

func automaticLease(t *testing.T, cli testComputer, login, task string) string {
	t.Helper()
	got := cli.requestTestLease(t, login, task)()
	id := leaseID(t, got)
	if strings.Contains(got.stderr, "Waiting for approval") {
		t.Fatalf("Automatic lease prompted for approval: %s", got.stderr)
	}
	return id
}

func approveRemote(t *testing.T, peer *lineProcess, cli testComputer, device, login, task string) string {
	t.Helper()
	waiting := cli.requestTestLease(t, login, task)
	id := peer.sendPeerCommand(t, "WAIT_REMOTE "+device)
	peer.expectOK(t, "APPROVE_REMOTE "+device+" "+id)
	if got := leaseID(t, waiting()); got != id {
		t.Fatalf("approved %s but CLI leased %s", id, got)
	}
	return id
}

func approveOnPhoneWithMacWaiting(t *testing.T, peer *lineProcess, cli testComputer, login string) string {
	t.Helper()
	const task = "phone-approval"
	pending := leaseID(t, cli.requestTestLease(t, login, task, "--no-wait")())
	macID := peer.sendPeerCommand(t, "WAIT_REMOTE mac")
	id := peer.sendPeerCommand(t, "WAIT_REMOTE phone")
	if macID != pending || id != pending {
		t.Fatalf("CLI requested %s, Mac was asked %s, iPhone was asked %s", pending, macID, id)
	}
	waiting := cli.requestTestLease(t, login, task)
	peer.expectOK(t, "APPROVE_REMOTE phone "+id)
	if got := leaseID(t, waiting()); got != id {
		t.Fatalf("iPhone approved %s but CLI leased %s", id, got)
	}
	return id
}

func denyOnPhone(t *testing.T, peer *lineProcess, cli testComputer, login string) {
	t.Helper()
	const words = "Use the invoice in email."
	waiting := cli.requestTestLease(t, login, "phone-denial")
	id := peer.sendPeerCommand(t, "WAIT_REMOTE phone")
	peer.expectOK(t, "DENY_REMOTE phone "+id+" "+words)
	assertRefused(t, waiting(), "denied. Reply: "+words)
	assertRefused(t, cli.requestTestLease(t, login, "after-phone-denial")(), "Their reply, word for word: \""+words+"\"")
}

var testCode = regexp.MustCompile(`^[0-9]{6}$`)

func assertCode(t *testing.T, cli testComputer, id string) {
	t.Helper()
	got := cli.runComputerCommand(t, "read", id, "--field", "one-time-code")
	assertSuccess(t, got)
	if !testCode.MatchString(got.stdout) {
		t.Fatalf("want a six-digit one-time code, got %q", got.stdout)
	}
}

func assertStopped(t *testing.T, cli testComputer, id, reason string) {
	t.Helper()
	for _, field := range []string{"password", "one-time-code"} {
		assertRefused(t, cli.runComputerCommand(t, "read", id, "--field", field), reason)
	}
}

func waitForRefusal(t *testing.T, cli testComputer, reason string, args ...string) {
	t.Helper()
	var got cliProcessResult
	eventually(t, reason, func() bool {
		got = cli.runComputerCommand(t, args...)
		return strings.Contains(got.stderr, reason)
	})
	assertRefused(t, got, reason)
}

func TestRemoteAsksStaySeparate(t *testing.T) {
	mac := newRealMac(t)
	peer := mac.startMacTestPeer(t)
	github, docs := importRealMac(t, peer)
	peer.expectOK(t, "SET_RULE "+docs+" ask")
	cli := mac.testComputer("remote", false)
	cli.enrolTestComputer(t, peer, "Build server")
	first := cli.requestTestLease(t, github, "first")
	a := peer.sendPeerCommand(t, "WAIT_REMOTE mac")
	second := cli.requestTestLease(t, docs, "second")
	peer.expectOK(t, "APPROVE_REMOTE mac "+a)
	if got := leaseID(t, first()); got != a {
		t.Fatalf("first ask got %s, want %s", got, a)
	}
	b := peer.sendPeerCommand(t, "WAIT_REMOTE mac")
	peer.expectOK(t, "APPROVE_REMOTE mac "+b)
	if got := leaseID(t, second()); got != b || b == a {
		t.Fatalf("second ask got %s, want %s distinct from %s", got, b, a)
	}
	assertPassword(t, cli.runComputerCommand(t, "read", b, "--field", "password"), "pw-docs.example")
	assertSuccess(t, cli.runComputerCommand(t, "release", b))
	assertRefused(t, cli.runComputerCommand(t, "read", b, "--field", "password"), "This lease was released.")
	peer.quitPeerProcess(t)
}

func TestRemoteAskTimesOutWithoutRewritingComputerState(t *testing.T) {
	mac := newRealMac(t)
	peer := mac.startMacTestPeer(t)
	github, _ := importRealMac(t, peer)
	cli := mac.testComputer("remote", false)
	cli.env = append(cli.env, "AGENT_KEYRING_TEST_ANSWER_WITHIN=5s")
	cli.enrolTestComputer(t, peer, "Build server")
	waiting := cli.requestTestLease(t, github, "unanswered")
	id := peer.sendPeerCommand(t, "WAIT_REMOTE mac")
	store := clientstate.ClientStateStore{Directory: cli.state}
	eventually(t, "push recorded before waiting poll", func() bool {
		saved, err := store.LoadClientState(t.Context())
		if err != nil {
			return false
		}
		for _, request := range saved.Requests {
			if request.LeaseId == id && request.GetLease().GetPushedUnixSeconds() > 0 {
				return true
			}
		}
		return false
	})
	state := filepath.Join(cli.state, "state.pb")
	first := statFixturePath(t, state)
	time.Sleep(time.Second)
	if !statFixturePath(t, state).ModTime().Equal(first.ModTime()) {
		t.Fatal("a waiting lease rewrote the state file")
	}
	assertRefused(t, waiting(), "No answer. Nobody answered within 10 minutes.")
	peer.expectOK(t, "WAIT_OUTCOME mac "+id+" unanswered")
	peer.quitPeerProcess(t)
}

func statFixturePath(t *testing.T, path string) os.FileInfo {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info
}

func TestRemoteComplaintIsKeptOnThatComputer(t *testing.T) {
	mac := newRealMac(t)
	peer := mac.startMacTestPeer(t)
	importRealMac(t, peer)
	cli := mac.testComputer("remote", false)
	cli.enrolTestComputer(t, peer, "Build server")
	peer.quitPeerProcess(t)

	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	cmd := cli.buildComputerCommand(ctx, "complain", "--summary", "The lease hung.", "--command", "lease", "--thread", "thread-1")
	cmd.Stdin = strings.NewReader("It waited and printed nothing.\n")
	got := waitForCapturedCommand(t, startCapturedCommand(cmd), "complain")
	assertSuccess(t, got)
	if !strings.Contains(got.stderr, "Kept on this computer.") {
		t.Fatalf("complain: %s", got.stderr)
	}
	got = cli.runComputerCommand(t, "complaints")
	assertSuccess(t, got)
	for _, want := range []string{"Build server", "The lease hung.", "thread: thread-1", "It waited and printed nothing."} {
		if !strings.Contains(got.stdout, want) {
			t.Errorf("complaints: want %q in %q", want, got.stdout)
		}
	}
}
