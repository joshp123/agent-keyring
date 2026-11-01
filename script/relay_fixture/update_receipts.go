// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/tls"
	"crypto/x509"
	"database/sql"
	"encoding/pem"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"github.com/joshp123/agent-keyring/internal/remote"
	"google.golang.org/protobuf/proto"
)

// A relay controlled by an adversary can keep serving a genuine old snapshot.
// This TLS proxy forwards real RPCs except for the deliberately withheld data.
type withholdingRelay struct {
	sync.Mutex
	backend                                  wireClient
	oldKeys                                  *pb.SignedApproverKeySet
	oldConfiguration                         *pb.SignedConfiguration
	withhold, failConfiguration, loseReceipt bool
	loseRevision                             uint64
}

func (p *proof) withholdingRelay() (*withholdingRelay, string, []byte, func()) {
	proxy := &withholdingRelay{backend: p.client, oldKeys: proto.Clone(p.keys).(*pb.SignedApproverKeySet), oldConfiguration: proto.Clone(p.signedConfiguration).(*pb.SignedConfiguration)}
	certificate := identity(filepath.Join(p.directory, "withholding-relay"))
	pin, err := relaycrypto.CertificateSPKI(certificate)
	must(err)
	listener, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{certificate}, ClientAuth: tls.RequireAnyClientCert})
	must(err)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go proxy.serve(conn)
		}
	}()
	return proxy, listener.Addr().String(), pin, func() { listener.Close() }
}
func (p *withholdingRelay) serve(conn net.Conn) {
	defer conn.Close()
	request := new(pb.RelayWireRequest)
	if authority.ReadFrame(conn, request) != nil {
		return
	}
	p.Lock()
	withhold, fail := p.withhold, p.failConfiguration
	oldKeys, oldConfig := p.oldKeys, p.oldConfiguration
	lose := false
	if receipt := request.GetPublishUpdateReceipt(); receipt != nil && p.loseReceipt {
		statement := new(pb.UpdateReceipt)
		if proto.Unmarshal(receipt.Receipt, statement) == nil && statement.Kind == pb.UpdateKind_UPDATE_KIND_APPROVER_KEYS && statement.Revision == p.loseRevision {
			lose = true
			p.loseReceipt = false
		}
	}
	p.Unlock()
	var response *pb.RelayWireResponse
	if withhold && request.GetGetApproverKeyChain() != nil {
		response = &pb.RelayWireResponse{Response: &pb.RelayWireResponse_ApproverKeyChain{ApproverKeyChain: &pb.ApproverKeyChain{KeySets: []*pb.SignedApproverKeySet{oldKeys}}}}
		set := new(pb.ApproverKeySet)
		must(proto.Unmarshal(oldKeys.KeySet, set))
		if request.GetGetApproverKeyChain().FromRevision == set.Revision {
			response.GetApproverKeyChain().KeySets = nil
		}
	} else if request.GetGetConfigurationUpdates() != nil && (withhold || fail) {
		if fail {
			response = &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Error{Error: &pb.RpcError{Message: "deliberately withheld configuration"}}}
		} else {
			response = &pb.RelayWireResponse{Response: &pb.RelayWireResponse_ConfigurationUpdates{ConfigurationUpdates: &pb.ConfigurationUpdates{Configurations: []*pb.SignedConfiguration{oldConfig}}}}
		}
	} else if withhold && request.GetPublishUpdateReceipt() != nil {
		// An untrusted courier can lie about accepting an old receipt. It still
		// cannot produce this device's signature on the owner's withheld update.
		response = &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Publish{Publish: &pb.PublishAck{Accepted: true}}}
	} else {
		response = p.backend.call(request)
	}
	if lose {
		return
	}
	response.EndOfStream = true
	authority.WriteFrame(conn, response)
}
func (p *proof) receiptTarget(update *pb.TrustUpdate) *pb.UpdateReceiptQuery {
	target, err := relaycrypto.UpdateTarget(update)
	must(err)
	return target
}
func (p *proof) submitReceipt(peer wireClient, target *pb.UpdateReceiptQuery) *pb.SignedUpdateReceipt {
	receipt, err := relaycrypto.SignUpdateReceipt(peer.certificate.PrivateKey.(crypto.Signer), target)
	must(err)
	good(peer.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishUpdateReceipt{PublishUpdateReceipt: receipt}}))
	return receipt
}
func (p *proof) deviceReceipts(target *pb.UpdateReceiptQuery) map[string]*pb.SignedUpdateReceipt {
	found := map[string]*pb.SignedUpdateReceipt{}
	for _, signed := range good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetUpdateReceipts{GetUpdateReceipts: target}})).GetUpdateReceipts().Receipts {
		statement := new(pb.UpdateReceipt)
		must(proto.Unmarshal(signed.Receipt, statement))
		found[fmt.Sprintf("%x", statement.DeviceSpkiSha256)] = signed
	}
	return found
}
func (p *proof) hasReceipt(target *pb.UpdateReceiptQuery, peer wireClient) bool {
	spki, err := relaycrypto.CertificateSPKI(peer.certificate)
	must(err)
	signed := p.deviceReceipts(target)[fmt.Sprintf("%x", relaycrypto.Hash(spki))]
	if signed == nil {
		return false
	}
	must(relaycrypto.VerifyUpdateReceipt(spki, signed, target))
	return true
}
func (p *proof) withdrawalCompleted(target *pb.UpdateReceiptQuery) bool {
	db := p.database()
	defer db.Close()
	var completed sql.NullInt64
	must(db.QueryRow("SELECT completed FROM trust_updates WHERE kind=? AND revision=?", target.Kind, fmt.Sprintf("%020d", target.Revision)).Scan(&completed))
	return completed.Valid
}
func receiptReceiver(directory, lease, deliveryPath string) {
	client, err := remote.Load(context.Background(), clientstate.Store{Directory: directory})
	must(err)
	raw, err := os.ReadFile(deliveryPath)
	must(err)
	delivery := new(pb.Delivery)
	must(proto.Unmarshal(raw, delivery))
	values, _, err := client.OpenValues(context.Background(), &pb.Lease{LeaseId: lease}, delivery)
	if err != nil {
		fmt.Println("REFUSED:", err)
		os.Exit(1)
	}
	require(values.Password != "", "receiver opened no password")
	values.Password = ""
	fmt.Println("OPENED")
}
func runReceiptReceiver(directory, lease, path string) bool {
	executable, err := os.Executable()
	must(err)
	output, err := exec.Command(executable, "--mode", "receipt-receiver", "--state", directory, "--lease", lease, "--delivery", path).CombinedOutput()
	fmt.Print(string(output))
	if err != nil {
		require(bytes.Contains(output, []byte("REFUSED:")), "receiver crashed instead of refusing")
		return false
	}
	return true
}
func (p *proof) receiptProof() {
	p.start()
	defer p.stop()
	p.pair()
	defer p.work.Close()
	p.enrol(true)
	oldPhone, oldKey, oldSigner, _ := p.copyPhone("removed-phone", nil)
	remaining, remainingKey, _, _ := p.copyPhone("remaining-phone", nil)
	request := leaseRequest("receipt-request", "receipt-task", p.enrolled.RecipientId)
	lease := good(p.client.call(request)).GetClient().GetLease()
	record := p.nextRequest()
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_EscalateToPhone{EscalateToPhone: &pb.PhoneEscalation{LeaseId: lease.LeaseId, Record: record}}}))
	decision := p.directPhoneDecision(record, oldKey, oldSigner, &pb.AutomaticLoginContents{LoginId: "fixture-login", Sites: []string{"https://example.com"}, Password: "dummy-removal-password"})
	require(good(oldPhone.call(decision)).GetDecision().Accepted, "old phone decision refused before removal")
	delivery := good(p.client.call(deliverRequest(lease.LeaseId))).GetClient().GetDelivery()
	path := filepath.Join(p.directory, "receipt-delivery.pb")
	must(os.WriteFile(path, encoded(delivery), 0600))
	proxy, address, pin, stop := p.withholdingRelay()
	defer stop()
	stateDir := filepath.Join(p.directory, "receipt-receiver")
	store := clientstate.Store{Directory: stateDir}
	must(store.Update(context.Background(), func(state *clientstate.State) error {
		state.RelayAddress = address
		state.RelaySpki = pin
		state.RecipientId = p.enrolled.RecipientId
		state.ReceiverKeyId = p.enrolled.ReceiverKeyId
		state.Approvers = p.keys
		state.Configuration = p.signedConfiguration
		state.Requests = []*clientstate.ExpectedRequest{{LeaseId: lease.LeaseId, Scope: request.GetClient().GetRequestLease()}}
		return nil
	}))
	private, err := x509.MarshalPKCS8PrivateKey(p.client.certificate.PrivateKey)
	must(err)
	_, err = store.Keys(context.Background(), func() (*clientstate.PrivateKeys, error) {
		return &clientstate.PrivateKeys{CertificatePem: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: p.client.certificate.Certificate[0]}), TlsKeyPem: pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private}), ReceiverPrivateKey: p.receiver.D.FillBytes(make([]byte, 32))}, nil
	})
	must(err)
	require(runReceiptReceiver(stateDir, lease.LeaseId, path), "initial real receiver failed")
	receiverWatch := p.client.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_Client{Client: &pb.WireRequest{Request: &pb.WireRequest_WatchLease{WatchLease: &pb.LeaseReference{LeaseId: lease.LeaseId}}}}})
	defer receiverWatch.Close()
	require(good(receive(receiverWatch)).GetClient().GetLease().State == pb.LeaseState_LEASE_STATE_ACTIVE, "receiver watch lost initial lease")
	phoneWatch := remaining.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: remainingKey.KeyId}}})
	defer phoneWatch.Close()
	set := new(pb.ApproverKeySet)
	must(proto.Unmarshal(p.keys.KeySet, set))
	set.Revision++
	var keys []*pb.ApproverKey
	for _, key := range set.Keys {
		if key.KeyId != oldKey.KeyId {
			keys = append(keys, key)
		}
	}
	set.Keys = keys
	raw := encoded(set)
	p.keys = &pb.SignedApproverKeySet{KeySet: raw, Signature: sign(p.signer, raw), SignerKeyId: p.key.KeyId}
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: p.keys}}))
	target := p.receiptTarget(&pb.TrustUpdate{Update: &pb.TrustUpdate_ApproverKeys{ApproverKeys: p.keys}})
	updateFrame := new(pb.RelayWireResponse)
	must(authority.ReadFrame(receiverWatch, updateFrame))
	require(bytes.Equal(updateFrame.GetTrustUpdate().GetApproverKeys().GetKeySet(), p.keys.KeySet), "live receiver watch missed exact signed update")
	for {
		work := good(receive(phoneWatch)).GetWork()
		if update := work.GetTrustUpdate(); update != nil {
			require(bytes.Equal(update.GetApproverKeys().GetKeySet(), p.keys.KeySet), "live phone watch changed signed update")
			break
		}
	}
	proxy.Lock()
	proxy.withhold = true
	proxy.Unlock()
	p.submitReceipt(p.approver, target)
	p.submitReceipt(remaining, target)
	require(runReceiptReceiver(stateDir, lease.LeaseId, path), "withheld removal unexpectedly became known")
	require(!p.hasReceipt(target, p.client), "withheld update counted receiver complete")
	require(!p.withdrawalCompleted(target), "courier marked withheld removal complete")
	// The courier knows the target but not the receiver's TLS signing key.
	forged, err := relaycrypto.SignUpdateReceipt(p.approver.certificate.PrivateKey.(crypto.Signer), target)
	must(err)
	statement := new(pb.UpdateReceipt)
	must(proto.Unmarshal(forged.Receipt, statement))
	spki, err := relaycrypto.CertificateSPKI(p.client.certificate)
	must(err)
	statement.DeviceSpkiSha256 = relaycrypto.Hash(spki)
	forged.Receipt = encoded(statement)
	require(p.client.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishUpdateReceipt{PublishUpdateReceipt: forged}}).GetError() != nil, "relay accepted invented receiver receipt")
	fmt.Println("PASS withholding a genuine signed removal leaves receiver pending; old unexpired delivery remains possible until learned; courier cannot forge its receipt")
	proxy.Lock()
	proxy.withhold = false
	proxy.loseReceipt = true
	proxy.loseRevision = set.Revision
	proxy.Unlock()
	require(!runReceiptReceiver(stateDir, lease.LeaseId, path), "lost receipt ACK allowed delivery")
	saved, err := store.Load(context.Background())
	must(err)
	require(bytes.Equal(saved.Approvers.KeySet, p.keys.KeySet) && len(saved.PendingUpdateReceipts) > 0, "receipt loss rolled back saved removal/outbox")
	require(!runReceiptReceiver(stateDir, lease.LeaseId, path), "removed phone signature survived receiver restart")
	require(p.hasReceipt(target, p.client), "receiver did not authenticate exact removal")
	proxy.Lock()
	proxy.withhold = true
	proxy.Unlock()
	require(!runReceiptReceiver(stateDir, lease.LeaseId, path), "old chain restored removed phone after restart")
	saved, err = store.Load(context.Background())
	must(err)
	require(bytes.Equal(saved.Approvers.KeySet, p.keys.KeySet), "replay rolled back saved authority")
	public := good(oldPhone.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetApproverKeyChain{GetApproverKeyChain: &pb.GetApproverKeyChainRequest{FromRevision: set.Revision - 1}}}))
	require(len(public.GetApproverKeyChain().KeySets) == 1, "removed phone cannot learn own removal")
	require(oldPhone.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetCopyUpdate{GetCopyUpdate: &pb.GetCopyUpdateRequest{}}}).GetError() != nil, "removed phone retained copy access")
	fmt.Println("PASS saved removal and authenticated receipt survive lost ACK and receiver process restart; stale chain and old-phone delivery refused; retired phone can only fetch signed public changes")
	// Configuration withdrawals use the exact same receipt mechanism.
	proxy.Lock()
	proxy.withhold = false
	proxy.Unlock()
	macDelivery := &pb.Delivery{Result: &pb.Delivery_Sealed{Sealed: &pb.SealedDelivery{Decision: p.decision(record, false).GetDecide(), RequestRecord: record}}}
	macDelivery.GetSealed().Bundle = macDelivery.GetSealed().Decision.Bundle
	macDelivery.GetSealed().Decision.Bundle = nil
	must(os.WriteFile(path, encoded(macDelivery), 0600))
	require(runReceiptReceiver(stateDir, lease.LeaseId, path), "current Mac delivery failed")
	proxy.Lock()
	proxy.oldKeys = proto.Clone(p.keys).(*pb.SignedApproverKeySet)
	proxy.oldConfiguration = proto.Clone(p.signedConfiguration).(*pb.SignedConfiguration)
	proxy.withhold = true
	proxy.Unlock()
	p.configuration.Logins[0].Rule = pb.AccessRule_ACCESS_RULE_BLOCKED
	p.publishConfiguration()
	blocked := p.receiptTarget(&pb.TrustUpdate{Update: &pb.TrustUpdate_Configuration{Configuration: p.signedConfiguration}})
	p.submitReceipt(p.approver, blocked)
	p.submitReceipt(remaining, blocked)
	require(!p.hasReceipt(blocked, p.client), "Blocked completed without receiver")
	require(runReceiptReceiver(stateDir, lease.LeaseId, path), "withheld Blocked was magically known")
	proxy.Lock()
	proxy.withhold = false
	proxy.Unlock()
	require(!runReceiptReceiver(stateDir, lease.LeaseId, path), "learned Blocked accepted an old Mac delivery")
	require(p.hasReceipt(blocked, p.client), "Blocked receipt absent")
	proxy.Lock()
	proxy.withhold = true
	proxy.Unlock()
	require(!runReceiptReceiver(stateDir, lease.LeaseId, path), "old configuration restored permission after receiver restart")
	fmt.Println("PASS Ask-to-Blocked waits for the real receiver receipt; saved Blocked refuses old valid Mac delivery and stale configuration after restart")
	p.configuration.Logins[0].Rule = pb.AccessRule_ACCESS_RULE_AUTOMATIC
	p.publishConfiguration()
	p.configuration.Logins[0].Rule = pb.AccessRule_ACCESS_RULE_ASK
	p.publishConfiguration()
	a := p.receiptTarget(&pb.TrustUpdate{Update: &pb.TrustUpdate_Configuration{Configuration: p.signedConfiguration}})
	p.submitReceipt(p.approver, a)
	p.submitReceipt(remaining, a)
	require(!p.hasReceipt(a, p.client), "off-Automatic withdrawal skipped receiver")
	p.configuration.Machines = nil
	p.publishConfiguration()
	b := p.receiptTarget(&pb.TrustUpdate{Update: &pb.TrustUpdate_Configuration{Configuration: p.signedConfiguration}})
	p.submitReceipt(p.approver, b)
	require(!p.hasReceipt(b, remaining), "later removal completed before remaining phone saved it")
	// The owner's independent evidence for retiring A's missing receiver is B's
	// signed removal plus both B receipts verified against the original SPKIs.
	require(!p.hasReceipt(a, p.client) && !p.hasReceipt(b, remaining), "earlier requirement retired on relay ACK")
	require(!p.withdrawalCompleted(a) && !p.withdrawalCompleted(b), "unconfirmed later removal retired an earlier obligation")
	p.submitReceipt(remaining, b)
	require(p.hasReceipt(b, p.approver) && p.hasReceipt(b, remaining), "later removal lacks authenticated remaining-device evidence")
	require(!p.hasReceipt(a, p.client), "relay invented receipt for removed receiver")
	require(p.withdrawalCompleted(a) && p.withdrawalCompleted(b), "confirmed later removal failed to retire an absent device's earlier obligation")
	// A removed receiver learns each missed withdrawal in order, durably saves
	// its own removal, and can drain receipts that it was not required to send.
	proxy.Lock()
	proxy.withhold = false
	proxy.Unlock()
	require(!runReceiptReceiver(stateDir, lease.LeaseId, path), "removed receiver opened an old delivery")
	saved, err = store.Load(context.Background())
	must(err)
	require(bytes.Equal(saved.Configuration.Configuration, p.signedConfiguration.Configuration) && len(saved.PendingUpdateReceipts) == 0, "own removal/cursor/receipt outbox failed")
	require(p.client.call(find()).GetError() != nil, "removed receiver can still ask")
	fmt.Println("PASS off-Automatic and machine removal require receipts; later confirmed removal retires an earlier missing-device requirement without inventing its receipt")
	p.stop()
	p.start()
	require(p.hasReceipt(target, p.client) && p.hasReceipt(b, remaining), "relay restart lost authenticated receipt history")
	// Completed public history expires without making a very late lost-ACK
	// retry fail forever. The owner has already saved its verified evidence.
	p.stop()
	db := p.database()
	_, err = db.Exec("UPDATE trust_updates SET completed=? WHERE kind=? AND revision=?", time.Now().Unix()-8*86400, target.Kind, fmt.Sprintf("%020d", target.Revision))
	must(err)
	must(db.Close())
	p.start()
	p.submitReceipt(p.client, target)
	require(!p.hasReceipt(target, p.client), "pruned evidence was fabricated from a routine ACK")
	fmt.Println("PASS relay restart retains exact device evidence; no receipt asserts erasure of a lost phone's passwords or TOTP seeds")
}
