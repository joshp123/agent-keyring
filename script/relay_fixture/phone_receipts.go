// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package main

import (
	"bytes"
	"crypto"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func phoneQueuedReceipt(directory string, target *pb.UpdateReceiptQuery) *pb.SignedUpdateReceipt {
	for index := 0; ; index++ {
		value, err := phoneCheckpoint(directory, fmt.Sprintf("outbox.%d", index))
		if err != nil {
			return nil
		}
		raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(value)))
		must(err)
		command := new(pb.RelayWireRequest)
		must(proto.Unmarshal(raw, command))
		signed := command.GetPublishUpdateReceipt()
		if signed == nil {
			continue
		}
		receipt := new(pb.UpdateReceipt)
		must(proto.Unmarshal(signed.Receipt, receipt))
		if receipt.Kind == target.Kind && receipt.Revision == target.Revision && bytes.Equal(receipt.UpdateSha256, target.UpdateSha256) {
			return signed
		}
	}
}

func waitPhoneProof(check func() bool, failure string) {
	deadline := time.Now().Add(20 * time.Second)
	for !check() {
		require(time.Now().Before(deadline), failure)
		time.Sleep(30 * time.Millisecond)
	}
}

func (p *proof) phoneReceipt(target *pb.UpdateReceiptQuery, spki []byte) *pb.SignedUpdateReceipt {
	result := good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetUpdateReceipts{GetUpdateReceipts: target}})).GetUpdateReceipts()
	for _, signed := range result.Receipts {
		receipt := new(pb.UpdateReceipt)
		must(proto.Unmarshal(signed.Receipt, receipt))
		if bytes.Equal(receipt.DeviceSpkiSha256, relaycrypto.Hash(spki)) {
			must(relaycrypto.VerifyUpdateReceipt(spki, signed, target))
			return signed
		}
	}
	return nil
}

func (p *proof) swiftReceiptProof(phone *phoneProcess, key *pb.ApproverKey, network *phoneNetwork, directory string) *phoneProcess {
	phone.command("stop")
	countPath := filepath.Join(directory, "authorization-count")
	before, err := os.ReadFile(countPath)
	must(err)
	other := wireClient{address: p.address, certificate: identity(filepath.Join(p.directory, "receipt-other-phone")), pin: p.approver.pin}
	spki, err := relaycrypto.CertificateSPKI(other.certificate)
	must(err)
	signer := signingKey()
	otherKey := &pb.ApproverKey{KeyId: hex.EncodeToString(relaycrypto.Hash(public(signer))), Label: "Other phone", PublicKey: public(signer), TlsPublicKey: spki, Role: pb.ApproverRole_APPROVER_ROLE_PHONE}
	pair := other.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PairApprover{PairApprover: &pb.PairApproverRequest{Key: otherKey, TlsPublicKey: spki}}})
	good(receive(pair))
	set := new(pb.ApproverKeySet)
	must(proto.Unmarshal(p.keys.KeySet, set))
	set.Revision++
	set.Keys = append(set.Keys, otherKey)
	set.ConfigurationRevision = p.configuration.Revision
	set.ConfigurationSha256 = relaycrypto.Hash(p.signedConfiguration.Configuration)
	set.PairingTranscriptSha256 = relaycrypto.Hash(relaycrypto.PairTranscript(p.approver.pin, spki, otherKey.PublicKey, p.keys.KeySet))
	p.keys = &pb.SignedApproverKeySet{KeySet: encoded(set), SignerKeyId: p.key.KeyId}
	p.keys.Signature = sign(p.signer, p.keys.KeySet)
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: p.keys}}))
	require(good(receive(pair)).GetEnrolStatus().State == pb.EnrolState_ENROL_STATE_APPROVED, "other phone was not paired")
	pair.Close()
	require(phone.command("refresh") == "REFRESHED", "phone could not learn added phone")
	phone.command("start")
	waitPhoneProof(func() bool { _, err := phoneCheckpoint(directory, "outbox.0"); return err != nil }, "routine receipts did not drain")
	phone.command("stop")
	set.Revision++
	set.Keys = set.Keys[:len(set.Keys)-1]
	p.keys = &pb.SignedApproverKeySet{KeySet: encoded(set), SignerKeyId: p.key.KeyId}
	p.keys.Signature = sign(p.signer, p.keys.KeySet)
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: p.keys}}))
	target, err := relaycrypto.UpdateTarget(&pb.TrustUpdate{Update: &pb.TrustUpdate_ApproverKeys{ApproverKeys: p.keys}})
	must(err)
	require(p.phoneReceipt(target, key.TlsPublicKey) == nil, "withheld removal had a phone receipt")
	forged, err := relaycrypto.SignUpdateReceipt(p.approver.certificate.PrivateKey.(crypto.Signer), target)
	must(err)
	statement := new(pb.UpdateReceipt)
	must(proto.Unmarshal(forged.Receipt, statement))
	statement.DeviceSpkiSha256 = relaycrypto.Hash(key.TlsPublicKey)
	forged.Receipt = encoded(statement)
	forged.Signature, err = p.approver.certificate.PrivateKey.(crypto.Signer).Sign(rand.Reader, relaycrypto.Hash(forged.Receipt), crypto.SHA256)
	must(err)
	require(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishUpdateReceipt{PublishUpdateReceipt: forged}}).GetError() != nil, "courier forged a phone receipt")
	require(phone.command("refresh") == "REFRESHED", "phone could not save other phone removal")
	require(phoneCheckpointKeys(directory).Revision == set.Revision && phoneQueuedReceipt(directory, target) != nil, "phone did not save key update with receipt")
	network.Lock()
	network.loseReply = true
	network.Unlock()
	phone.command("start")
	var accepted *pb.SignedUpdateReceipt
	waitPhoneProof(func() bool { accepted = p.phoneReceipt(target, key.TlsPublicKey); return accepted != nil }, "relay did not receive actual Swift TLS receipt")
	queued := phoneQueuedReceipt(directory, target)
	require(queued != nil && proto.Equal(queued, accepted), "lost ACK did not retain exact signed receipt")
	must(phone.cmd.Process.Kill())
	_ = phone.cmd.Wait()
	network.down()
	network.Lock()
	network.loseReply = false
	network.Unlock()
	network.up()
	phone = startPhone(phone.cmd.Path, directory)
	waitPhoneProof(func() bool { return phoneQueuedReceipt(directory, target) == nil }, "receipt did not drain after lost ACK/restart")
	require(proto.Equal(accepted, p.phoneReceipt(target, key.TlsPublicKey)), "receipt retry changed signed bytes")
	fmt.Println("PASS actual Swift phone saves other-phone removal with TLS receipt; withheld update has no receipt; forged receipt refused; lost ACK and SIGKILL resend identical bytes without authorization")

	// Miss several configuration withdrawals while the phone is disconnected.
	p.configuration.Logins = append(p.configuration.Logins, &pb.Login{LoginId: "withdraw-a", Title: "A", Sites: []string{"https://a.example"}, Rule: pb.AccessRule_ACCESS_RULE_ASK}, &pb.Login{LoginId: "withdraw-b", Title: "B", Sites: []string{"https://b.example"}, Rule: pb.AccessRule_ACCESS_RULE_ASK})
	p.publishConfiguration()
	unseenOlder := proto.Clone(p.configuration).(*pb.Configuration)
	unseenOlder.Logins[0].Title = "Unseen old snapshot"
	require(phone.command("refresh") == "REFRESHED", "phone did not save configuration grant")
	waitPhoneProof(func() bool { _, err := phoneCheckpoint(directory, "outbox.0"); return err != nil }, "grant receipt did not drain")
	phone.command("stop")
	var targets []*pb.UpdateReceiptQuery
	for _, id := range []string{"withdraw-a", "withdraw-b"} {
		for _, login := range p.configuration.Logins {
			if login.LoginId == id {
				login.Rule = pb.AccessRule_ACCESS_RULE_BLOCKED
			}
		}
		p.publishConfiguration()
		target, err := relaycrypto.UpdateTarget(&pb.TrustUpdate{Update: &pb.TrustUpdate_Configuration{Configuration: p.signedConfiguration}})
		must(err)
		targets = append(targets, target)
		require(p.phoneReceipt(target, key.TlsPublicKey) == nil, "offline phone acknowledged unseen configuration")
	}
	p.publishConfiguration() // Current refresh after both retained withdrawals.
	require(phone.command("refresh") == "REFRESHED", "phone did not fetch missed configuration updates")
	for _, target := range targets {
		require(phoneQueuedReceipt(directory, target) != nil, "phone skipped a retained intermediate withdrawal")
	}
	phone.command("start")
	for _, target := range targets {
		waitPhoneProof(func() bool { return p.phoneReceipt(target, key.TlsPublicKey) != nil }, "phone did not acknowledge exact intermediate withdrawal")
	}
	waitPhoneProof(func() bool { _, err := phoneCheckpoint(directory, "outbox.0"); return err != nil }, "configuration receipts did not drain")
	phone.command("stop")
	// A withholding courier invents an older history entry the phone never saved.
	// It is owner-signed fixture data, but must not lower the cursor or manufacture
	// an acknowledgement. A request after this work item proves the stream ran it.
	oldSigned := &pb.SignedConfiguration{Configuration: encoded(unseenOlder), ApproverKeyId: p.key.KeyId}
	oldSigned.Signature = sign(p.signer, oldSigned.Configuration)
	oldUpdate := &pb.TrustUpdate{Update: &pb.TrustUpdate_Configuration{Configuration: oldSigned}}
	oldTarget, err := relaycrypto.UpdateTarget(oldUpdate)
	must(err)
	p.stop()
	db, err := sql.Open("sqlite", filepath.Join(p.directory, "relay", "relay.sqlite"))
	must(err)
	_, err = db.Exec("INSERT INTO trust_updates(kind,revision,hash,value) VALUES(?,?,?,?)", oldTarget.Kind, fmt.Sprintf("%020d", oldTarget.Revision), oldTarget.UpdateSha256, encoded(oldUpdate))
	must(err)
	_, err = db.Exec("INSERT INTO update_devices(kind,revision,spki) VALUES(?,?,?)", oldTarget.Kind, fmt.Sprintf("%020d", oldTarget.Revision), key.TlsPublicKey)
	must(err)
	must(db.Close())
	p.start()
	p.work = p.approver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: p.key.KeyId}}})
	phone.command("start")
	lease := good(p.client.call(leaseRequest("old-trust-check", "old-trust-task", p.enrolled.RecipientId))).GetClient().GetLease()
	record := p.phoneRequest(lease.LeaseId)
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_EscalateToPhone{EscalateToPhone: &pb.PhoneEscalation{LeaseId: lease.LeaseId, Record: record}}}))
	id := hex.EncodeToString(relaycrypto.Digest("agentkeyring.request.v1", record))
	phone.wait("requests", id+"=waitingForYou")
	require(p.phoneReceipt(oldTarget, key.TlsPublicKey) == nil && phoneQueuedReceipt(directory, oldTarget) == nil, "older unseen live update invented a receipt")
	configurationBytes, err := phoneCheckpoint(directory, "configuration")
	must(err)
	configurationRaw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(configurationBytes)))
	must(err)
	savedConfiguration := new(pb.SignedConfiguration)
	must(proto.Unmarshal(configurationRaw, savedConfiguration))
	require(bytes.Equal(savedConfiguration.Configuration, p.signedConfiguration.Configuration), "older live update lowered or replaced saved configuration")
	require(strings.Contains(phone.command("deny\t"+id), "denied"), "phone could not answer after ignoring old history")
	phone.command("clear\t" + id)
	phone.command("stop")
	p.stop()
	db, err = sql.Open("sqlite", filepath.Join(p.directory, "relay", "relay.sqlite"))
	must(err)
	_, err = db.Exec("DELETE FROM update_devices WHERE kind=? AND revision=?", oldTarget.Kind, fmt.Sprintf("%020d", oldTarget.Revision))
	must(err)
	_, err = db.Exec("DELETE FROM trust_updates WHERE kind=? AND revision=?", oldTarget.Kind, fmt.Sprintf("%020d", oldTarget.Revision))
	must(err)
	must(db.Close())
	p.start()
	p.work = p.approver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: p.key.KeyId}}})
	phone.command("start")
	fmt.Println("PASS real WatchWork older unseen signed configuration cannot lower the Swift phone cursor or invent a receipt; subsequent request still works")
	after, err := os.ReadFile(countPath)
	must(err)
	require(bytes.Equal(before, after), "public trust updates requested biometric authorization")
	fmt.Println("PASS actual Swift phone fetches missed configuration withdrawals in order, durably queues each exact payload receipt before current, and authenticates both without Face ID")
	return phone
}
