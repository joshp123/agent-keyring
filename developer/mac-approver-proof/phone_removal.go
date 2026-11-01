// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"github.com/joshp123/agent-keyring/internal/remote"
	"google.golang.org/protobuf/proto"
)

// Every invocation is a fresh process running production receiver code against
// its real saved state. Only the prepared synthetic ciphertext is replayed.
func receiverRemovalCheck(root string, refuse bool) {
	ctx := context.Background()
	store := clientstate.Store{Directory: filepath.Join(root, "receiver")}
	receiver, err := remote.Load(ctx, store)
	must(err)
	var lease pb.Lease
	var delivery pb.Delivery
	bytes, err := os.ReadFile(filepath.Join(root, "old-phone-lease.pb"))
	must(err)
	must(proto.Unmarshal(bytes, &lease))
	bytes, err = os.ReadFile(filepath.Join(root, "old-phone-delivery.pb"))
	must(err)
	must(proto.Unmarshal(bytes, &delivery))
	values, _, err := receiver.OpenValues(ctx, &lease, &delivery)
	if refuse {
		require(err != nil && values == nil, "removed phone's delivery was opened")
		fmt.Println("REFUSED removed phone delivery: " + err.Error())
	} else {
		must(err)
		require(values.Password == "example-password" && values.OneTimeCode != "", "original phone delivery did not open")
		values.Password, values.OneTimeCode = "", ""
		fmt.Println("OPENED synthetic phone password and TOTP without printing values")
	}
}

func (p *proof) runReceiverRemovalCheck(refuse bool) {
	arguments := []string{"--receiver-removal-root", p.root}
	if refuse {
		arguments = append(arguments, "--expect-refusal")
	}
	result, err := exec.Command(os.Args[0], arguments...).CombinedOutput()
	require(err == nil, string(result))
	fmt.Print(string(result))
}

func (p *proof) saveRemovalReceiver(lease *pb.Lease, delivery *pb.Delivery) {
	record := new(pb.RequestRecord)
	must(proto.Unmarshal(delivery.GetSealed().RequestRecord, record))
	private, err := x509.MarshalPKCS8PrivateKey(p.receiver.cert.PrivateKey)
	must(err)
	store := clientstate.Store{Directory: filepath.Join(p.root, "receiver")}
	_, err = store.Keys(context.Background(), func() (*clientstate.PrivateKeys, error) {
		return &clientstate.PrivateKeys{
			CertificatePem:     pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: p.receiver.cert.Certificate[0]}),
			TlsKeyPem:          pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private}),
			ReceiverPrivateKey: p.receiverKey.Bytes(),
		}, nil
	})
	must(err)
	clear(private)
	must(store.Update(context.Background(), func(state *clientstate.State) error {
		state.RelayAddress, state.RelaySpki = p.receiver.address, p.receiver.pin
		state.RecipientId, state.ReceiverKeyId, state.Approvers = p.recipient, relaycrypto.CopyDestinationID(p.receiverKey.PublicKey().Bytes()), p.keys
		state.Requests = []*clientstate.ExpectedRequest{{LeaseId: lease.LeaseId, Scope: &pb.RequestLeaseRequest{
			LoginId: record.LoginId, TaskRef: record.TaskRef, Purpose: record.Purpose, Reason: record.Reason, RecipientId: record.RecipientId,
		}}}
		return nil
	}))
	must(os.WriteFile(filepath.Join(p.root, "old-phone-lease.pb"), encode(lease), 0600))
	must(os.WriteFile(filepath.Join(p.root, "old-phone-delivery.pb"), encode(delivery), 0600))
}

func (p *proof) waitWithdrawal(kind pb.UpdateKind, revision uint64) (string, *withdrawalStatus) {
	for deadline := time.Now().Add(40 * time.Second); time.Now().Before(deadline); {
		p.owner.status()
		for id, saved := range p.owner.withdrawals {
			if saved.kind == fmt.Sprint(int(kind)) && saved.revision == fmt.Sprint(revision) {
				return id, saved
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	panic("Mac did not retain the exact withdrawal")
}

func (p *proof) rawReply(peer client, command *pb.RelayWireRequest) *pb.RelayWireResponse {
	stream := peer.open(command)
	defer stream.Close()
	response := new(pb.RelayWireResponse)
	must(authority.ReadFrame(stream, response))
	return response
}

func (p *proof) setCourierReceipt(target *pb.UpdateReceiptQuery, spki []byte, signed *pb.SignedUpdateReceipt) {
	value := "NULL"
	if signed != nil {
		value = "X'" + hex.EncodeToString(encode(signed)) + "'"
	}
	query := fmt.Sprintf("UPDATE update_devices SET receipt=%s WHERE kind=%d AND revision='%020d' AND spki=X'%x';",
		value, target.Kind, target.Revision, spki)
	result, err := exec.Command("/usr/bin/sqlite3", filepath.Join(p.root, "relay", "relay.sqlite"), query).CombinedOutput()
	require(err == nil, string(result))
}

func (p *proof) runPhoneRemoval() {
	require(p.cli != "", "phone removal proof needs the actual CLI")
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
	lost, lostDirectory := p.pairSwiftPhoneAt(p.phoneBinary, filepath.Join(p.root, "lost-phone"))
	defer func() { lost.stop() }()
	lostID := phoneSigningID(lostDirectory)
	lostPeer := lost.relay
	lostPeer.pin = p.receiver.pin
	remaining, remainingDirectory := p.pairSwiftPhoneAt(p.phoneBinary, filepath.Join(p.root, "remaining-phone"))
	defer func() { remaining.stop() }()
	remainingPeer := remaining.relay
	remainingPeer.pin = p.receiver.pin
	p.waitApplied()
	oldCopy := lostPeer.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetCopyUpdate{GetCopyUpdate: &pb.GetCopyUpdateRequest{}}}).GetCopyUpdate()
	require(oldCopy != nil, "offline phone never received a copy")
	var copyUpdate pb.CopyUpdate
	must(proto.Unmarshal(oldCopy.Update, &copyUpdate))
	p.owner.action("lock", "true")
	lease := p.receiver.lease("phone-before-removal", p.recipient)
	requestID := p.owner.pending(lease.LeaseId)
	lost.wait("requests", requestID+"=waitingForYou")
	lost.action("approve\t" + requestID)
	active := p.receiver.waitLease(lease.LeaseId, pb.LeaseState_LEASE_STATE_ACTIVE)
	delivery := p.receiver.deliver(lease.LeaseId)
	require(delivery.GetSealed().Decision.ApproverKeyId == lostID, "wrong phone supplied the initial delivery")
	p.saveRemovalReceiver(active, delivery)
	p.runReceiverRemovalCheck(false)
	local := authority.Client{Socket: filepath.Join(p.root, "agent.sock")}
	localLost := []string{p.localPhoneApprovedLease(lost, "lost-phone-local-1"), p.localPhoneApprovedLease(lost, "lost-phone-local-2")}
	localRemaining := p.localPhoneApprovedLease(remaining, "remaining-phone-local")
	for _, id := range append(localLost, localRemaining) {
		p.checkLocalFields(id, true)
	}
	p.owner.stop()
	p.owner = startOwner(p.fixture, p.root)
	for _, id := range append(localLost, localRemaining) {
		require(localLease(local, id).State == pb.LeaseState_LEASE_STATE_ACTIVE, "restart lost a trusted phone's local approval")
		p.checkLocalFields(id, true)
	}
	lost.stop()
	_, beforeKeys := currentApprovers(p.receiver)
	beforeConfiguration := p.receiver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetConfiguration{GetConfiguration: &pb.GetConfigurationRequest{}}}).GetConfiguration()
	remainingAuthorizations := authorizationCount(remainingDirectory)
	p.owner.status()
	before := p.owner.authorizations
	network.Lock()
	network.loseReply = true
	network.Unlock()
	p.owner.action("remove-phone", lostID)
	for _, id := range localLost {
		lease := localLease(local, id)
		require(lease.State == pb.LeaseState_LEASE_STATE_REVOKED && lease.EndedAtUnixSeconds > 0, "removed phone's local lease remains active")
		p.checkLocalFields(id, false)
	}
	require(localLease(local, localRemaining).State == pb.LeaseState_LEASE_STATE_ACTIVE, "removing one phone revoked the other phone's local lease")
	p.checkLocalFields(localRemaining, true)
	signed, keys := currentApprovers(p.receiver)
	kept := []*pb.ApproverKey{}
	for _, key := range beforeKeys.Keys {
		if key.KeyId != lostID {
			kept = append(kept, key)
		}
	}
	require(proto.Equal(&pb.ApproverKeySet{Keys: kept}, &pb.ApproverKeySet{Keys: keys.Keys}), "removal changed another approver or delivery key")
	require(proto.Equal(beforeConfiguration, p.receiver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetConfiguration{GetConfiguration: &pb.GetConfigurationRequest{}}}).GetConfiguration()), "phone removal changed rules or receiving machines")
	require(relayCopyCount(p.root, copyUpdate.DestinationKeyId) == "0", "lost phone's relay copy remains")
	p.owner.action("saved")
	p.owner.status()
	saved := p.owner.saved["remove-phone:"+lostID]
	require(saved != "" && p.owner.applying && p.owner.authorizations == before+1, "removal did not retain one-authorisation outbox and Applying")
	p.owner.stop()
	remaining.stop()
	p.stopRelay()
	network.Lock()
	network.loseReply, network.pauseNewCalls = false, true
	network.Unlock()
	p.startRelay()
	p.owner = startOwner(p.fixture, p.root)
	p.owner.action("saved")
	p.owner.status()
	require(p.owner.saved["remove-phone:"+lostID] == saved && p.owner.applying && p.owner.authorizations == before+1, "restart changed the signed removal or asked again")
	for _, id := range localLost {
		require(localLease(local, id).State == pb.LeaseState_LEASE_STATE_REVOKED, "restart reactivated the removed phone's local approval")
		p.checkLocalFields(id, false)
	}
	require(localLease(local, localRemaining).State == pb.LeaseState_LEASE_STATE_ACTIVE, "restart revoked the remaining phone's local lease")
	p.checkLocalFields(localRemaining, true)
	fmt.Println("PASS actual local CLI: both lost-phone leases refuse fresh password and TOTP deliveries before and after Mac/relay restart while publication is unacknowledged; remaining phone lease still works")
	network.Lock()
	network.pauseNewCalls = false
	network.Unlock()
	remaining = startPhone(p.phoneBinary, remainingDirectory)
	remaining.wait("status", "paired")
	id, withdrawal := p.waitWithdrawal(pb.UpdateKind_UPDATE_KIND_APPROVER_KEYS, keys.Revision)
	receiverSPKI, err := relaycrypto.CertificateSPKI(p.receiver.cert)
	must(err)
	receiverID := relaycrypto.CopyDestinationID(receiverSPKI)
	require(!withdrawal.complete && withdrawal.devices[receiverID][3] == "false", "relay ACK completed removal without the offline receiver")
	fmt.Println("PASS offline copied phone removed under one authorization; exact signed removal and pending receiver survive lost ACK and Mac/relay restarts")

	// A malicious courier can alter its own storage, but cannot authenticate a
	// receiver. Feed that forged evidence through the actual relay response.
	target, err := relaycrypto.UpdateTarget(&pb.TrustUpdate{Update: &pb.TrustUpdate_ApproverKeys{ApproverKeys: signed}})
	must(err)
	forgedKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	must(err)
	statement := encode(&pb.UpdateReceipt{Domain: "agentkeyring.update-receipt.v1", DeviceSpkiSha256: relaycrypto.Hash(receiverSPKI),
		Kind: target.Kind, Revision: target.Revision, UpdateSha256: target.UpdateSha256})
	signature, err := ecdsa.SignASN1(rand.Reader, forgedKey, relaycrypto.Hash(statement))
	must(err)
	p.setCourierReceipt(target, receiverSPKI, &pb.SignedUpdateReceipt{Receipt: statement, Signature: signature})
	p.owner.action("reconnect")
	p.owner.wait(func(event []string) bool {
		return event[0] == "DETAIL" && strings.Contains(event[1], "does not authenticate")
	})
	p.owner.status()
	require(p.owner.applying && !p.owner.withdrawals[id].complete, "Mac counted a forged courier receipt")
	p.setCourierReceipt(target, receiverSPKI, nil)
	p.runReceiverRemovalCheck(true)
	p.runReceiverRemovalCheck(true)
	p.waitApplied()
	require(p.owner.withdrawals[id].complete && p.owner.authorizations == before+1, "authenticated receiver receipt did not complete removal quietly")
	require(p.rawReply(lostPeer, &pb.RelayWireRequest{Request: &pb.RelayWireRequest_Decide{Decide: delivery.GetSealed().Decision}}).GetError() != nil, "retired TLS/signing identity can still decide")
	require(p.rawReply(lostPeer, &pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetCopyUpdate{GetCopyUpdate: &pb.GetCopyUpdateRequest{}}}).GetError() != nil, "retired phone can fetch a new copy")
	p.owner.action("refresh", "after-removal-dummy-password")
	p.waitApplied()
	require(relayCopyCount(p.root, copyUpdate.DestinationKeyId) == "0" && p.owner.authorizations == before+1, "password refresh recreated the lost phone's copy or asked again")
	fmt.Println("PASS Mac independently refuses courier-forged evidence; fresh production receiver processes learn and receipt removal, reject old phone delivery, and complete without another touch or copy to the lost phone")

	// A requires this receiver; B removes it. B's relay ACK alone cannot retire
	// A's missing evidence while the remaining phone is offline.
	remaining.stop()
	p.owner.action("rule", "block")
	configA := p.receiver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetConfiguration{GetConfiguration: &pb.GetConfigurationRequest{}}}).GetConfiguration()
	var a pb.Configuration
	must(proto.Unmarshal(configA.Configuration, &a))
	idA, _ := p.waitWithdrawal(pb.UpdateKind_UPDATE_KIND_CONFIGURATION, a.Revision)
	p.owner.action("revoke", p.recipient)
	configB := remainingPeer.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetConfiguration{GetConfiguration: &pb.GetConfigurationRequest{}}}).GetConfiguration()
	var b pb.Configuration
	must(proto.Unmarshal(configB.Configuration, &b))
	idB, _ := p.waitWithdrawal(pb.UpdateKind_UPDATE_KIND_CONFIGURATION, b.Revision)
	p.owner.status()
	require(!p.owner.withdrawals[idA].complete && !p.owner.withdrawals[idB].complete && p.owner.withdrawals[idA].devices[receiverID][4] == "false", "later relay ACK retired an earlier missing device")
	p.owner.stop()
	p.stopRelay()
	p.startRelay()
	p.owner = startOwner(p.fixture, p.root)
	p.owner.status()
	require(!p.owner.withdrawals[idA].complete && !p.owner.withdrawals[idB].complete, "restart lost pending withdrawal dependencies")
	remaining = startPhone(p.phoneBinary, remainingDirectory)
	remaining.wait("status", "paired")
	p.waitApplied()
	p.owner.status()
	require(p.owner.withdrawals[idA].complete && p.owner.withdrawals[idB].complete && p.owner.withdrawals[idA].devices[receiverID][4] == "true" && p.owner.withdrawals[idA].devices[receiverID][3] == "false", "authenticated later removal did not retire the earlier absent receiver requirement")
	fmt.Println("PASS Ask-to-Blocked and receiving-machine removal use the same exact-update receipts; A remains pending until B's remaining Swift phone confirms, including both restarts")
	require(authorizationCount(remainingDirectory) == remainingAuthorizations, "public permission updates asked the remaining phone for authorization")
	fmt.Println("ALL MAC PHONE REMOVAL AND RECEIPT PROOFS PASSED; no claim that an offline handset's stored copy was erased")
}
