// Written by AI on 2026.10.31 by model gpt-6.1-sol.
// Production Swift Mac and phone cores, real relay/CLI/Chrome; software keys.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

type phoneProcess struct {
	command *exec.Cmd
	input   io.WriteCloser
	lines   chan string
	relay   client
}

func startPhone(binary, directory string) *phoneProcess {
	p := &phoneProcess{command: exec.Command(binary, "--dummy-state", directory), lines: make(chan string, 64)}
	var err error
	p.input, err = p.command.StdinPipe()
	must(err)
	output, err := p.command.StdoutPipe()
	must(err)
	p.command.Stderr = os.Stderr
	must(p.command.Start())
	go func() {
		defer close(p.lines)
		scanner := bufio.NewScanner(output)
		for scanner.Scan() {
			p.lines <- scanner.Text()
		}
	}()
	require(p.line() == "READY", "Swift phone did not start")
	return p
}

func (p *phoneProcess) line() string {
	select {
	case line, ok := <-p.lines:
		require(ok, "Swift phone exited")
		return line
	case <-time.After(40 * time.Second):
		panic("Swift phone response timed out")
	}
}
func (p *phoneProcess) action(command string) string {
	_, err := fmt.Fprintln(p.input, command)
	must(err)
	line := p.line()
	require(!strings.HasPrefix(line, "ERROR"), line)
	return line
}
func (p *phoneProcess) wait(command, contains string) string {
	for deadline := time.Now().Add(45 * time.Second); time.Now().Before(deadline); {
		line := p.action(command)
		if strings.Contains(line, contains) {
			return line
		}
		time.Sleep(100 * time.Millisecond)
	}
	panic("Swift phone never reported " + contains)
}
func (p *phoneProcess) stop() {
	if p.command == nil {
		return
	}
	p.input.Close()
	p.command.Process.Kill()
	p.command.Wait()
	p.command = nil
}

func (p *proof) pairSwiftPhone() (*phoneProcess, string) {
	directory := filepath.Join(p.root, "phone")
	must(os.MkdirAll(directory, 0700))
	certificate := identity()
	private := certificate.PrivateKey.(*ecdsa.PrivateKey)
	public := elliptic.Marshal(elliptic.P256(), private.X, private.Y)
	must(os.WriteFile(filepath.Join(directory, "tls-cert.der"), certificate.Certificate[0], 0600))
	must(os.WriteFile(filepath.Join(directory, "tls-private.x963"), append(public, private.D.FillBytes(make([]byte, 32))...), 0600))
	signer, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	must(err)
	public = elliptic.Marshal(elliptic.P256(), signer.X, signer.Y)
	must(os.WriteFile(filepath.Join(directory, "signing.raw"), signer.D.FillBytes(make([]byte, 32)), 0600))
	phone := startPhone(p.phoneBinary, directory)
	phone.relay = client{address: "127.0.0.1:17445", cert: certificate}
	comparison := phone.action("pair\t17445")
	id := hex.EncodeToString(relaycrypto.Hash(public))
	work := p.owner.wait(func(e []string) bool { return e[0] == "APPROVER" && e[1] == id })
	require(comparison == "PAIR\t"+work[2], "production Swift Mac and phone fingerprints differ")
	p.owner.action("confirm-approver", id, work[2])
	phone.wait("status", "paired")
	_, err = os.Stat(filepath.Join(directory, "vault"))
	require(os.IsNotExist(err), "Swift phone created a vault")
	fmt.Println("PASS production Swift Mac and Swift phone pair on the same fingerprint and signed configuration; no phone vault")
	return phone, directory
}

func (p *proof) cliIdentity() client {
	store := clientstate.Store{Directory: filepath.Join(p.root, "cli")}
	keys, err := store.Keys(context.Background(), nil)
	must(err)
	certificate, err := tls.X509KeyPair(keys.CertificatePem, keys.TlsKeyPem)
	must(err)
	state, err := store.Load(context.Background())
	must(err)
	return client{address: "127.0.0.1:17445", cert: certificate, pin: state.RelaySpki}
}

type browserSignIn struct {
	command               *exec.Cmd
	output                bytes.Buffer
	hold, id, lease       string
	holdRelease, signedIn string
	started               time.Time
}

func (p *proof) startBrowserSignIn(task string) *browserSignIn {
	return p.startBrowser(task, false)
}
func (p *proof) startBrowser(task string, local bool) *browserSignIn {
	b := &browserSignIn{hold: filepath.Join(p.root, task+".hold"), started: time.Now()}
	must(os.WriteFile(b.hold, []byte("Inspect the approved delivery before filling."), 0600))
	b.command = p.cliCommand()
	if local {
		b.command = p.localCLICommand()
	}
	b.command.Path = "/usr/bin/python3"
	b.command.Args = []string{"/usr/bin/python3", p.browserScript, "--cli", p.cli, "--task", task, "--hold-before-fill", b.hold}
	if local {
		b.holdRelease = filepath.Join(p.root, task+".release-hold")
		b.signedIn = filepath.Join(p.root, task+".signed-in")
		must(os.WriteFile(b.holdRelease, []byte("Phone ends the local lease before CLI release."), 0600))
		b.command.Args = append(b.command.Args, "--hold-before-release", b.holdRelease, "--signed-in-marker", b.signedIn)
	}
	b.command.Stdout = &b.output
	b.command.Stderr = &b.output
	known := map[string]bool{}
	for lease := range p.owner.requests {
		known[lease] = true
	}
	must(b.command.Start())
	if local {
		work := p.owner.wait(func(e []string) bool { return e[0] == "LOCAL" && e[2] == task && e[3] == "1" })
		b.id, b.lease = work[4], work[1]
		return b
	}
	work := p.owner.wait(func(e []string) bool { return e[0] == "REQUEST" && e[3] == "1" && !known[e[2]] })
	b.id, b.lease = work[1], work[2]
	return b
}
func (b *browserSignIn) finish() {
	b.allowFill()
	if b.holdRelease != "" {
		must(os.Rename(b.holdRelease, b.holdRelease+".released"))
	}
	err := b.command.Wait()
	text := b.output.String()
	require(!strings.Contains(text, "example-password"), "dummy password exposed by browser proof")
	if err != nil {
		panic(text + err.Error())
	}
	fmt.Print(text)
}
func (b *browserSignIn) allowFill() {
	if _, err := os.Stat(b.hold); os.IsNotExist(err) {
		return
	}
	must(os.Rename(b.hold, b.hold+".released"))
}
func (b *browserSignIn) stop() {
	if b.command.ProcessState == nil {
		b.command.Process.Kill()
		b.command.Wait()
	}
}
func authorizationCount(directory string) int {
	data, err := os.ReadFile(filepath.Join(directory, "authorization-count"))
	if os.IsNotExist(err) {
		return 0
	}
	must(err)
	count, err := strconv.Atoi(string(data))
	must(err)
	return count
}

func checkPhoneDelivery(delivery *pb.SealedDelivery, lease *pb.Lease) {
	require(delivery != nil && delivery.Decision.PhoneDecision != nil, "Mac omitted the Swift phone decision")
	var statement pb.DecisionStatement
	var phone pb.PhoneDecision
	must(proto.Unmarshal(delivery.Decision.Statement, &statement))
	must(proto.Unmarshal(delivery.Decision.PhoneDecision.Decision, &phone))
	require(statement.Authority == pb.DecisionAuthority_DECISION_AUTHORITY_PHONE && lease.ApprovedBy == pb.ApprovedBy_APPROVED_BY_IPHONE, "phone authority or attribution lost")
	require(statement.ApprovedAtUnixSeconds == phone.DecidedUnixSeconds && statement.NotAfterUnixSeconds == phone.NotAfterUnixSeconds && lease.NotAfterUnixSeconds == phone.NotAfterUnixSeconds, "Mac reset the phone's exact deadline")
}

func (p *proof) runPhoneFlow() {
	require(p.cli != "" && p.browserScript != "", "phone proof needs --cli and --browser-script")
	p.startRelay()
	defer p.stopRelay()
	network := &approvalNetwork{target: "127.0.0.1:17445", address: "127.0.0.1:0"}
	network.up()
	defer network.down()
	_, p.approverPort, _ = net.SplitHostPort(network.address)
	p.owner = startOwner(p.fixture, p.root)
	defer func() { p.owner.stop() }()
	p.pair()
	p.enrol()
	p.realCLIProgram()
	phone, directory := p.pairSwiftPhone()
	defer phone.stop()
	receiver := p.cliIdentity()
	p.owner.status()
	beforeMac, beforeBackground := p.owner.authorizations, p.owner.backgroundSignatures

	delayed := p.startBrowserSignIn("phone-delayed")
	defer delayed.stop()
	pending := receiver.status(delayed.lease)
	require(!strings.Contains(phone.action("requests"), delayed.id), "request escalated before its delay")
	// Reopen the Mac while pending: the original due time must survive.
	time.Sleep(8 * time.Second)
	p.owner.stop()
	p.owner = startOwner(p.fixture, p.root)
	reopened := receiver.status(delayed.lease)
	require(reopened.RequestedAtUnixSeconds == pending.RequestedAtUnixSeconds && reopened.PendingUntilUnixSeconds == pending.PendingUntilUnixSeconds, "restart reset the pending request deadline")
	phone.wait("requests", delayed.id+"=waitingForYou")
	elapsed := time.Since(delayed.started)
	escalatedAt := time.Now().Unix()
	require(escalatedAt >= pending.RequestedAtUnixSeconds+30 && escalatedAt <= pending.RequestedAtUnixSeconds+34, "phone delay reset or bypassed across Mac restart: "+elapsed.String())
	phone.action("approve\t" + delayed.id)
	active := receiver.waitLease(delayed.lease, pb.LeaseState_LEASE_STATE_ACTIVE)
	checkPhoneDelivery(receiver.deliver(delayed.lease).GetSealed(), active)
	phone.wait("requests", delayed.id+"=approved")
	p.owner.status()
	require(p.owner.authorizations == beforeMac && p.owner.backgroundSignatures == beforeBackground+1 && authorizationCount(directory) == 1, "phone approval repeated or used the Mac human key")
	delayed.finish()
	fmt.Printf("PASS production Swift Mac delayed escalation after %s, pending Mac restart, Swift phone approval, exact deadline and background delivery to real CLI/Chrome\n", elapsed.Round(time.Millisecond))

	p.owner.action("lock", "true")
	p.owner.status()
	beforeMac, beforeBackground = p.owner.authorizations, p.owner.backgroundSignatures
	locked := p.startBrowserSignIn("phone-locked")
	defer locked.stop()
	phone.wait("requests", locked.id+"=waitingForYou")
	require(time.Since(locked.started) < 5*time.Second, "locked request waited for the phone delay")
	phone.action("approve\t" + locked.id)
	active = receiver.waitLease(locked.lease, pb.LeaseState_LEASE_STATE_ACTIVE)
	checkPhoneDelivery(receiver.deliver(locked.lease).GetSealed(), active)
	p.owner.status()
	require(p.owner.authorizations == beforeMac && p.owner.backgroundSignatures == beforeBackground+1 && authorizationCount(directory) == 2, "locked delivery needed another touch")
	locked.finish()
	fmt.Println("PASS reported locked state escalates immediately; production Swift Mac background delivery completes real CLI/Chrome sign-in")

	winner := p.startBrowserSignIn("mac-wins")
	defer winner.stop()
	phone.wait("requests", winner.id+"=waitingForYou")
	p.owner.action("lock", "false")
	p.owner.status()
	beforeMac, beforeBackground = p.owner.authorizations, p.owner.backgroundSignatures
	p.owner.action("approve", winner.id)
	phone.wait("requests", winner.id+"=approved")
	_, err := fmt.Fprintln(phone.input, "approve\t"+winner.id)
	must(err)
	require(strings.HasPrefix(phone.line(), "ERROR"), "phone could approve after the Mac answered")
	p.owner.status()
	require(p.owner.authorizations == beforeMac+1 && p.owner.backgroundSignatures == beforeBackground && authorizationCount(directory) == 2, "Mac-first answer did not close phone authorization")
	winner.finish()
	fmt.Println("PASS Mac-first answer closes the actual Swift phone request; late approval rejected before authorization; browser retry still posts once")

	p.owner.action("lock", "true")
	p.owner.status()
	beforeMac, beforeBackground = p.owner.authorizations, p.owner.backgroundSignatures
	recovery := p.startBrowserSignIn("phone-lost-ack")
	defer recovery.stop()
	phone.wait("requests", recovery.id+"=waitingForYou")
	network.Lock()
	network.loseReply = true
	network.Unlock()
	phone.action("approve\t" + recovery.id)
	active = receiver.waitLease(recovery.lease, pb.LeaseState_LEASE_STATE_ACTIVE)
	first := receiver.deliver(recovery.lease).GetSealed()
	checkPhoneDelivery(first, active)
	for deadline := time.Now().Add(10 * time.Second); ; {
		network.Lock()
		dropped := network.dropped
		network.Unlock()
		if dropped > 0 {
			break
		}
		require(time.Now().Before(deadline), "no committed Mac acknowledgement was dropped")
		time.Sleep(10 * time.Millisecond)
	}
	p.owner.action("saved")
	hash := p.owner.saved[recovery.id]
	p.owner.status()
	require(hash != "" && p.owner.queued == 1, "Mac did not retain its accepted decision after lost acknowledgement")
	network.down()
	p.owner.stop()
	p.stopRelay()
	p.startRelay()
	network.Lock()
	network.loseReply = false
	network.Unlock()
	network.up()
	p.owner = startOwner(p.fixture, p.root)
	for deadline := time.Now().Add(15 * time.Second); ; {
		p.owner.status()
		if p.owner.queued == 0 {
			break
		}
		require(time.Now().Before(deadline), "Mac outbox did not acknowledge its retry")
		time.Sleep(100 * time.Millisecond)
	}
	p.owner.action("saved")
	require(p.owner.saved[recovery.id] == hash, "restart resealed the phone delivery")
	active = receiver.waitLease(recovery.lease, pb.LeaseState_LEASE_STATE_ACTIVE)
	require(proto.Equal(first, receiver.deliver(recovery.lease).GetSealed()), "relay restart changed the exact accepted delivery")
	checkPhoneDelivery(first, active)
	phone.wait("requests", recovery.id+"=approved")
	p.owner.status()
	require(p.owner.authorizations == beforeMac && p.owner.backgroundSignatures == beforeBackground+1 && authorizationCount(directory) == 3, "recovery repeated authorization or delivery signing")
	recovery.finish()
	fmt.Println("PASS committed Mac acknowledgement lost, Mac and relay restarted: exact ciphertext/deadline, one phone authorization, one background signature, one password post")
	fmt.Println("ALL JOINT SWIFT MAC / SWIFT PHONE / RELAY / CLI / HEADLESS CHROME PROOFS PASSED")
}
