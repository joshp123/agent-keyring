// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package main

import (
	"fmt"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"google.golang.org/protobuf/proto"
)

func (p *proof) waitApplied() {
	for deadline := time.Now().Add(40 * time.Second); time.Now().Before(deadline); {
		p.owner.status()
		if !p.owner.applying && p.owner.queued == 0 {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	panic("configuration/copy outbox did not finish")
}

func (p *proof) runCopyUpdates() {
	p.startRelay()
	defer p.stopRelay()
	network := &approvalNetwork{target: "127.0.0.1:17445", address: "127.0.0.1:17455"}
	network.up()
	defer network.down()
	p.approverPort = "17455"
	p.owner = startOwner(p.fixture, p.root)
	defer func() { p.owner.stop() }()
	p.pair()
	p.enrol()
	p.owner.action("rule", "auto")
	p.waitApplied()
	lease := p.receiver.lease("copied-login", p.recipient)
	require(lease.State == pb.LeaseState_LEASE_STATE_ACTIVE, "mini did not approve Automatic from its copy")
	p.open(p.receiver.deliver(lease.LeaseId).GetSealed(), lease.LeaseId)
	deadline := lease.NotAfterUnixSeconds
	fmt.Println("PASS initial Automatic configuration and Swift-sealed password/TOTP copy")
	p.owner.status()
	authorizations := p.owner.authorizations
	background := p.owner.backgroundSignatures
	configurationBefore := p.receiver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetConfiguration{GetConfiguration: &pb.GetConfigurationRequest{}}}).GetConfiguration()
	network.Lock()
	network.loseReply = true
	network.Unlock()
	p.owner.action("refresh", "refreshed-dummy-password")
	for deadline := time.Now().Add(15 * time.Second); ; {
		network.Lock()
		dropped := network.dropped
		network.Unlock()
		if dropped > 0 {
			break
		}
		require(time.Now().Before(deadline), "copy acknowledgement was not lost")
		time.Sleep(50 * time.Millisecond)
	}
	p.owner.action("saved")
	require(len(p.owner.copies) == 1, "password import did not persist one sealed copy update")
	var revision, sealed string
	for revision, sealed = range p.owner.copies {
	}
	p.owner.status()
	require(p.owner.applying, "Applying disappeared before copy acknowledgement")
	require(p.owner.authorizations == authorizations, "password-only import asked for authorization")
	require(p.owner.backgroundSignatures == background+1, "password import signed more than one copy")
	p.openExpected(p.receiver.deliver(lease.LeaseId).GetSealed(), lease.LeaseId, "refreshed-dummy-password")
	configurationAfter := p.receiver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetConfiguration{GetConfiguration: &pb.GetConfigurationRequest{}}}).GetConfiguration()
	require(proto.Equal(configurationBefore, configurationAfter), "password-only import republished the configuration")
	require(p.receiver.status(lease.LeaseId).NotAfterUnixSeconds == deadline, "password update extended the lease")
	fmt.Println("PASS real synthetic import updates an existing Automatic lease without a prompt or deadline extension; Applying waits for acknowledgement")
	p.owner.stop()
	p.stopRelay()
	network.Lock()
	network.loseReply = false
	network.pauseNewCalls = true
	network.Unlock()
	p.startRelay()
	p.owner = startOwner(p.fixture, p.root)
	p.owner.action("saved")
	require(p.owner.copies[revision] == sealed, "restart regenerated the signed copy or reused a different revision")
	p.owner.status()
	require(p.owner.applying && p.owner.authorizations == authorizations && p.owner.backgroundSignatures == background+1,
		"restart lost Applying or repeated authorization/signing")
	network.Lock()
	network.pauseNewCalls = false
	network.Unlock()
	p.waitApplied()
	require(p.owner.authorizations == authorizations && p.owner.backgroundSignatures == background+1, "resend repeated authorization/signing")
	p.openExpected(p.receiver.deliver(lease.LeaseId).GetSealed(), lease.LeaseId, "refreshed-dummy-password")
	require(p.receiver.status(lease.LeaseId).NotAfterUnixSeconds == deadline, "restart reset lease deadline")
	fmt.Println("PASS lost copy acknowledgement plus Mac and relay restarts: exact outbox resend, one signature, no repeated prompt")
	p.owner.action("rule", "ask")
	p.waitApplied()
	require(p.receiver.status(lease.LeaseId).State == pb.LeaseState_LEASE_STATE_REVOKED, "Automatic-to-Ask left old access active")
	p.owner.stop()
	ask := p.receiver.lease("ask-without-mac", p.recipient)
	require(ask.State == pb.LeaseState_LEASE_STATE_PENDING, "mini served a login after its Automatic copy was removed")
	fmt.Println("PASS Automatic-to-Ask removes copy and revokes access before acknowledgement")
	p.owner = startOwner(p.fixture, p.root)
	p.owner.action("rule", "auto")
	p.waitApplied()
	p.owner.stop()
	second := p.receiver.lease("automatic-without-mac", p.recipient)
	require(second.State == pb.LeaseState_LEASE_STATE_ACTIVE, "Ask-to-Automatic did not replace the copy")
	p.openExpected(p.receiver.deliver(second.LeaseId).GetSealed(), second.LeaseId, "refreshed-dummy-password")
	fmt.Println("PASS Ask-to-Automatic republishes the refreshed copy; mini delivers with Mac disconnected")
	p.owner = startOwner(p.fixture, p.root)
	p.owner.action("rule", "block")
	p.waitApplied()
	require(p.receiver.status(second.LeaseId).State == pb.LeaseState_LEASE_STATE_REVOKED, "Blocking left Automatic access active")
	p.owner.stop()
	blocked := p.receiver.lease("blocked-without-mac", p.recipient)
	require(blocked.State == pb.LeaseState_LEASE_STATE_DENIED, "mini did not refuse the Blocked login")
	fmt.Println("PASS Automatic-to-Blocked removes the copy and refuses new access with Mac disconnected")
}
