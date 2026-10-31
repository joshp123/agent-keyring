// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package main

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/authority"
)

func (p *proof) localCLICommand(arguments ...string) *exec.Cmd {
	command := p.cliCommand(arguments...)
	var environment []string
	for _, entry := range command.Env {
		if !strings.HasPrefix(entry, "AGENT_KEYRING_RELAY=") && !strings.HasPrefix(entry, "AGENT_KEYRING_STATE_DIR=") {
			environment = append(environment, entry)
		}
	}
	command.Env = append(environment, "AGENT_KEYRING_SOCKET="+filepath.Join(p.root, "agent.sock"), "AGENT_KEYRING_STATE_DIR="+filepath.Join(p.root, "local-cli"))
	return command
}

func localLease(client authority.Client, id string) *pb.Lease {
	lease, err := client.Lease(context.Background(), id)
	must(err)
	return lease
}
func waitLocalLease(client authority.Client, id string, state pb.LeaseState) *pb.Lease {
	for deadline := time.Now().Add(20 * time.Second); time.Now().Before(deadline); {
		lease := localLease(client, id)
		if lease.State == state {
			return lease
		}
		time.Sleep(100 * time.Millisecond)
	}
	panic("local lease did not reach " + state.String())
}

func (p *proof) runLocalPhoneFlow() {
	require(p.cli != "" && p.browserScript != "", "local phone proof needs CLI and browser script")
	p.startRelay()
	defer p.stopRelay()
	network := &approvalNetwork{target: "127.0.0.1:17445", address: "127.0.0.1:0"}
	network.up()
	defer network.down()
	_, p.approverPort, _ = net.SplitHostPort(network.address)
	p.owner = startOwner(p.fixture, p.root)
	defer func() { p.owner.stop() }()
	p.pair()
	phone, directory := p.pairSwiftPhone()
	defer func() { phone.stop() }()
	client := authority.Client{Socket: filepath.Join(p.root, "agent.sock")}
	// No recipient is enrolled with the relay: these are actual local requests.
	find, err := p.localCLICommand("find", "example.com").Output()
	must(err)
	require(bytes.Contains(find, []byte("example.com")), "real local socket did not find the dummy login")
	p.owner.status()
	beforeMac, beforeBackground := p.owner.authorizations, p.owner.backgroundSignatures

	delayed := p.startBrowser("local-phone-delayed", true)
	defer delayed.stop()
	pending := localLease(client, delayed.lease)
	require(!strings.Contains(phone.action("requests"), delayed.id), "local request reached phone before delay")
	phone.wait("requests", delayed.id+"=waitingForYou")
	escalatedAt := time.Now().Unix()
	require(escalatedAt >= pending.RequestedAtUnixSeconds+30 && escalatedAt <= pending.RequestedAtUnixSeconds+34, "local phone delay was bypassed or late")

	// Keep WatchWork alive so the phone answer reaches the Mac, but prevent
	// new Mac calls from reporting the local outcome until we inspect it.
	network.Lock()
	network.pauseNewCalls = true
	network.Unlock()
	require(strings.Contains(phone.action("approve\t"+delayed.id), "waitingForMac"), "phone skipped Waiting for your Mac")
	active := waitLocalLease(client, delayed.lease, pb.LeaseState_LEASE_STATE_ACTIVE)
	require(active.ApprovedBy == pb.ApprovedBy_APPROVED_BY_IPHONE, "local approval lost phone attribution")
	phone.wait("requests", delayed.id+"=waitingForMac")
	p.owner.status()
	require(p.owner.queued > 0, "local outcome was not retained for reporting")
	network.Lock()
	network.pauseNewCalls = false
	network.Unlock()
	phone.wait("requests", delayed.id+"=approved")
	delayed.allowFill()
	for deadline := time.Now().Add(20 * time.Second); ; {
		if _, err := os.Stat(delayed.signedIn); err == nil {
			break
		}
		require(time.Now().Before(deadline), "local CLI did not finish password and TOTP sign-in")
		time.Sleep(100 * time.Millisecond)
	}
	// End must remain unconfirmed on the phone until this Mac reports REVOKED.
	network.Lock()
	network.pauseNewCalls = true
	network.Unlock()
	require(strings.Contains(phone.action("end\t"+delayed.id), "approved"), "phone claimed End before the Mac confirmed it")
	ended := waitLocalLease(client, delayed.lease, pb.LeaseState_LEASE_STATE_REVOKED)
	require(ended.EndedAtUnixSeconds > 0, "Mac did not retain local End")
	phone.wait("requests", delayed.id+"=approved")
	_, err = client.Deliver(context.Background(), &pb.DeliverRequest{LeaseId: delayed.lease, Kind: pb.OperationKind_OPERATION_KIND_FILL, Fields: []pb.CredentialField{pb.CredentialField_CREDENTIAL_FIELD_PASSWORD}})
	require(err != nil, "Mac delivered after phone End")
	network.Lock()
	network.pauseNewCalls = false
	network.Unlock()
	phone.wait("requests", delayed.id+"=ended")
	delayed.finish()
	p.owner.status()
	require(p.owner.authorizations == beforeMac && p.owner.backgroundSignatures == beforeBackground && authorizationCount(directory) == 1, "local approval or End repeated authorization")
	fmt.Println("PASS local agent.sock: delayed Swift Mac escalation, Swift phone approval, Waiting for Mac until actual local report, real CLI/Chrome password+TOTP with one password POST, phone End confirmed by Mac")

	p.owner.action("lock", "true")
	locked := p.startBrowser("local-phone-locked", true)
	defer locked.stop()
	phone.wait("requests", locked.id+"=waitingForYou")
	require(time.Since(locked.started) < 5*time.Second, "locked local request waited for delay")
	phone.action("approve\t" + locked.id)
	active = waitLocalLease(client, locked.lease, pb.LeaseState_LEASE_STATE_ACTIVE)
	require(active.ApprovedBy == pb.ApprovedBy_APPROVED_BY_IPHONE, "locked local approval lost phone attribution")
	phone.wait("requests", locked.id+"=approved")
	locked.allowFill()
	for deadline := time.Now().Add(20 * time.Second); ; {
		if _, err := os.Stat(locked.signedIn); err == nil {
			break
		}
		require(time.Now().Before(deadline), "locked local CLI did not sign in")
		time.Sleep(100 * time.Millisecond)
	}
	locked.finish()
	phone.wait("requests", locked.id+"=released")
	fmt.Println("PASS locked local agent.sock: immediate escalation, Swift phone approval, local CLI/Chrome sign-in and release reported back")

	command := p.localCLICommand("lease", loginID, "--task", "local-phone-deny", "--reason", "Dummy local denial", "--for", "agent-process")
	var output, diagnostic bytes.Buffer
	command.Stdout = &output
	command.Stderr = &diagnostic
	must(command.Start())
	work := p.owner.wait(func(e []string) bool { return e[0] == "LOCAL" && e[2] == "local-phone-deny" && e[3] == "1" })
	phone.wait("requests", work[4]+"=waitingForYou")
	reply := "Stop here. Use only the test account; do not retry."
	network.Lock()
	network.pauseNewCalls = true
	network.Unlock()
	phone.action("deny\t" + work[4] + "\t" + reply)
	err = command.Wait()
	require(err != nil && output.Len() == 0 && strings.Contains(diagnostic.String(), reply), "local CLI did not print the exact phone denial reply: "+diagnostic.String())
	denied := localLease(client, work[1])
	require(denied.State == pb.LeaseState_LEASE_STATE_DENIED && denied.Reply == reply && denied.ApprovedBy == pb.ApprovedBy_APPROVED_BY_IPHONE, "local authority lost phone denial or reply")
	phone.wait("requests", work[4]+"=waitingForMac")
	p.owner.stop()
	p.stopRelay()
	p.startRelay()
	p.owner = startOwner(p.fixture, p.root)
	reopened := localLease(client, work[1])
	require(reopened.State == denied.State && reopened.Reply == reply && reopened.EndedAtUnixSeconds == denied.EndedAtUnixSeconds, "Mac restart lost the exact denial")
	network.Lock()
	network.pauseNewCalls = false
	network.Unlock()
	phone.wait("requests", work[4]+"=denied")
	fmt.Print(diagnostic.String())
	phoneRelay := phone.relay
	phone.stop()
	p.owner.stop()
	p.stopRelay()
	p.startRelay()
	p.owner = startOwner(p.fixture, p.root)
	phone = startPhone(p.phoneBinary, directory)
	phone.wait("requests", work[4]+"=denied")
	// End on an already denied local lease is a read of its durable relay outcome.
	relayDenial := phoneRelay.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_RevokeLease{RevokeLease: &pb.LeaseReference{LeaseId: work[1]}}}).GetLease()
	require(relayDenial.State == denied.State && relayDenial.Reply == reply && relayDenial.EndedAtUnixSeconds == denied.EndedAtUnixSeconds && relayDenial.SignedDenial == nil, "relay restart lost or rewrote the local denial")
	p.owner.status()
	require(p.owner.authorizations == beforeMac && p.owner.backgroundSignatures == beforeBackground && authorizationCount(directory) == 3, "local flows repeated or skipped phone authorization")
	fmt.Println("PASS phone-signed denial reply reaches actual local CLI verbatim; queued Mac outcome survives Mac/relay restart, phone leaves Waiting for Mac, and confirmed denial survives a second Mac/relay/phone restart")
	fmt.Println("ALL LOCAL AGENT.SOCK / SWIFT MAC / SWIFT PHONE / RELAY / CLI / HEADLESS CHROME PROOFS PASSED")
}
