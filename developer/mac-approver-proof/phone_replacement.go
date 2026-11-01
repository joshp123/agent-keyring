// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package main

import (
	"context"
	"crypto/elliptic"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"github.com/joshp123/agent-keyring/internal/remote"
	"google.golang.org/protobuf/proto"
)

func phoneSigningID(directory string) string {
	raw, err := os.ReadFile(filepath.Join(directory, "signing.raw"))
	must(err)
	x, y := elliptic.P256().ScalarBaseMult(raw)
	clear(raw)
	return relaycrypto.CopyDestinationID(elliptic.Marshal(elliptic.P256(), x, y))
}

func currentApprovers(peer client) (*pb.SignedApproverKeySet, *pb.ApproverKeySet) {
	signed := peer.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetApproverKeys{GetApproverKeys: &pb.GetApproverKeysRequest{}}}).GetApproverKeys()
	var keys pb.ApproverKeySet
	must(proto.Unmarshal(signed.KeySet, &keys))
	return signed, &keys
}

func relayCopyCount(root, destination string) string {
	count, err := exec.Command("/usr/bin/sqlite3", filepath.Join(root, "relay/relay.sqlite"),
		"SELECT count(*) FROM phone_copies WHERE destination='"+destination+"'").Output()
	must(err)
	return strings.TrimSpace(string(count))
}

func (p *proof) runPhoneReplacement() {
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
	binary := p.phoneBinary
	if p.legacyPhoneBinary != "" {
		binary = p.legacyPhoneBinary
	}
	phone, directory := p.pairSwiftPhone(binary)
	defer func() { phone.stop() }()
	phonePeer := phone.relay
	phonePeer.pin = p.receiver.pin
	oldID := phoneSigningID(directory)
	p.waitApplied()
	var oldUpdate pb.CopyUpdate
	if p.legacyPhoneBinary == "" {
		oldCopy := phonePeer.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetCopyUpdate{GetCopyUpdate: &pb.GetCopyUpdateRequest{}}}).GetCopyUpdate()
		must(proto.Unmarshal(oldCopy.Update, &oldUpdate))
		require(relayCopyCount(p.root, oldUpdate.DestinationKeyId) == "1", "old phone did not hold a copy")
	} else {
		_, initial := currentApprovers(phonePeer)
		found := false
		for _, key := range initial.Keys {
			if key.KeyId == oldID {
				found = true
				require(len(key.EncryptionPublicKey) == 0, "legacy phone already had a sealing key")
			}
		}
		require(found, "legacy phone did not finish pairing")
		fmt.Println("PASS actual old approval-only Swift binary completed a pairing with no sealing key; current phone opens its unchanged saved state")
		phone.stop()
		phone = startPhone(p.phoneBinary, directory)
		phone.wait("status", "paired")
	}
	// Another phone with the same label must be kept: the TLS key identifies replacement.
	other := p.pairCopyPhone("Josh's iPhone")
	otherCopy := other.copy()
	_, previous := currentApprovers(phonePeer)
	configuration := phonePeer.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetConfiguration{GetConfiguration: &pb.GetConfigurationRequest{}}}).GetConfiguration()
	p.owner.status()
	before := p.owner.authorizations
	comparison := phone.action("replace-pairing")
	newID := phoneSigningID(directory)
	require(newID != oldID, "phone replacement reused its signing key")
	work := p.owner.wait(func(e []string) bool { return e[0] == "APPROVER" && e[1] == newID })
	require(comparison == "PAIR\t"+work[2] && work[3] == oldID && work[4] == "Josh's iPhone", "Mac/phone replacement comparison or displayed old identity differs")
	p.owner.expectFailure("confirm-approver", newID, "wrong comparison")
	p.owner.status()
	require(p.owner.authorizations == before, "wrong fingerprint authorized replacement")
	network.Lock()
	network.loseReply = true
	network.Unlock()
	p.owner.action("confirm-approver", newID, work[2])
	phone.wait("status", "paired")
	p.owner.status()
	require(p.owner.authorizations == before+1 && strings.Contains(p.owner.authorizationReason, "Replace the Agent Keyring approval keys for Josh's iPhone"), "replacement was not explicit or prompted twice")
	signed, next := currentApprovers(phonePeer)
	require(next.Revision == previous.Revision+1 && next.RuleOwnerKeyId == previous.RuleOwnerKeyId, "replacement changed owner or reset revision")
	var added *pb.ApproverKey
	kept := []*pb.ApproverKey{}
	for _, key := range next.Keys {
		require(key.KeyId != oldID, "old signing key survived replacement")
		if key.KeyId == newID {
			added = key
		} else {
			kept = append(kept, key)
		}
	}
	prior := []*pb.ApproverKey{}
	for _, key := range previous.Keys {
		if key.KeyId != oldID {
			prior = append(prior, key)
		}
	}
	require(added != nil && proto.Equal(&pb.ApproverKeySet{Keys: kept}, &pb.ApproverKeySet{Keys: prior}), "replacement changed another approver or delivery key")
	require(added.Role == pb.ApproverRole_APPROVER_ROLE_PHONE && len(added.EncryptionPublicKey) == 65 && relaycrypto.CopyDestinationID(added.EncryptionPublicKey) != oldUpdate.DestinationKeyId, "new phone is not copy capable or reused its old sealing key")
	must(relaycrypto.Verify(previous.Keys[0].PublicKey, signed.KeySet, signed.Signature))
	require(proto.Equal(configuration, phonePeer.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetConfiguration{GetConfiguration: &pb.GetConfigurationRequest{}}}).GetConfiguration()), "replacement republished or changed rules/machines")
	require(relayCopyCount(p.root, oldUpdate.DestinationKeyId) == "0" && proto.Equal(other.copy(), otherCopy), "replacement retained the old copy or changed the other phone's copy")
	fmt.Println("PASS actual Swift phone replacement uses the same TLS identity and retires exactly its old signing key under one explicit authorization; old copy absent, same-named phone, Mac keys and configuration unchanged")
	// A password refresh before the replacement ACK must not target the retired key.
	p.owner.action("refresh", "replacement-refreshed-password")
	p.owner.action("saved")
	p.owner.status()
	for destination := range p.owner.copies {
		require(!strings.HasPrefix(destination, oldUpdate.DestinationKeyId+":"), "refresh queued a copy for the retired phone")
	}
	hash := p.owner.saved["approver-pairing:"+newID]
	require(hash != "" && p.owner.applying, "lost replacement ACK did not retain key set and Applying")
	signatures := p.owner.backgroundSignatures
	phone.stop()
	p.owner.stop()
	p.stopRelay()
	network.Lock()
	network.loseReply, network.pauseNewCalls = false, true
	network.Unlock()
	p.startRelay()
	p.owner = startOwner(p.fixture, p.root)
	p.owner.action("saved")
	p.owner.status()
	require(p.owner.saved["approver-pairing:"+newID] == hash && p.owner.authorizations == before+1, "restart replaced the signed key set or asked again")
	network.Lock()
	network.pauseNewCalls = false
	network.Unlock()
	p.waitApplied()
	p.owner.status()
	require(p.owner.authorizations == before+1 && p.owner.backgroundSignatures == signatures, "recovery asked or signed again")
	phone = startPhone(p.phoneBinary, directory)
	phone.wait("status", "paired")
	require(relayCopyCount(p.root, oldUpdate.DestinationKeyId) == "0", "relay restart restored the retired copy")
	newCopy := phonePeer.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetCopyUpdate{GetCopyUpdate: &pb.GetCopyUpdateRequest{}}}).GetCopyUpdate()
	var update pb.CopyUpdate
	must(proto.Unmarshal(newCopy.Update, &update))
	require(update.DestinationKeyId == relaycrypto.CopyDestinationID(added.EncryptionPublicKey) && update.DestinationKeyId != oldUpdate.DestinationKeyId, "replacement reused the old sealing destination")
	fmt.Println("PASS lost replacement ACK, real import before ACK and both restarts recover the exact signed set without another authorization; copy refresh targets only current destinations")
	p.owner.stop()
	lease := p.receiver.lease("replaced-phone-offline-mac", p.recipient)
	watch := phonePeer.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: newID}}})
	var record pb.RequestRecord
	var id string
	for id == "" {
		if pending := receive(watch).GetWork().GetRequest(); pending != nil {
			must(proto.Unmarshal(pending.Record, &record))
			if record.LeaseId == lease.LeaseId {
				id = fmt.Sprintf("%x", relaycrypto.Digest("agentkeyring.request.v1", pending.Record))
			}
		}
	}
	watch.Close()
	phone.wait("requests", id+"=waitingForYou")
	authorizations := authorizationCount(directory)
	require(strings.Contains(phone.action("approve\t"+id), "approved"), "replacement phone could not deliver with Mac offline")
	active := p.receiver.waitLease(lease.LeaseId, pb.LeaseState_LEASE_STATE_ACTIVE)
	delivery := p.receiver.deliver(lease.LeaseId)
	require(delivery.GetSealed().Decision.ApproverKeyId == newID && delivery.GetSealed().Decision.PhoneDecision == nil, "Mac delivered instead of the replaced phone")
	store := clientstate.Store{Directory: filepath.Join(p.root, "real-receiver")}
	must(store.Update(context.Background(), func(state *clientstate.State) error {
		state.RelayAddress, state.RelaySpki = p.receiver.address, p.receiver.pin
		state.RecipientId, state.ReceiverKeyId = p.recipient, relaycrypto.CopyDestinationID(p.receiverKey.PublicKey().Bytes())
		state.Approvers = p.keys // The real receiver must advance the full signed chain from enrolment.
		state.Requests = []*clientstate.ExpectedRequest{{LeaseId: lease.LeaseId, Scope: &pb.RequestLeaseRequest{LoginId: record.LoginId,
			TaskRef: record.TaskRef, Purpose: record.Purpose, Reason: record.Reason, RecipientId: record.RecipientId}}}
		return nil
	}))
	receiver := &remote.Client{Store: store, Keys: &clientstate.PrivateKeys{ReceiverPrivateKey: p.receiverKey.Bytes()}, Certificate: p.receiver.cert}
	values, _, err := receiver.OpenValues(context.Background(), active, delivery)
	must(err)
	require(values.Password == "replacement-refreshed-password" && values.OneTimeCode != "" && authorizationCount(directory) == authorizations+1, "replacement copy or one-authorization delivery failed")
	values.Password, values.OneTimeCode = "", ""
	phone.stop()
	phone = startPhone(p.phoneBinary, directory)
	phone.wait("requests", id+"=approved")
	require(authorizationCount(directory) == authorizations+1 && proto.Equal(p.receiver.deliver(lease.LeaseId), delivery), "phone restart asked again or changed delivery")
	fmt.Println("PASS real Swift phone after replacement and restart opens the refreshed Ask copy and delivers with Mac offline; real Go receiver advances the chain and opens password/TOTP after one authorization")
}
