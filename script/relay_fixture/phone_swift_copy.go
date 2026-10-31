// Written by AI on 2026.11.01 by model gpt-6.1-sol.
// Actual Swift phone core, software biometric keys, real relay and Go receiver.
package main

import (
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/hpke"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func (p *proof) swiftCopyProof(phone *phoneProcess, key *pb.ApproverKey, signer *ecdsa.PrivateKey, network *phoneNetwork, directory string) *phoneProcess {
	p.configuration.Logins[0].HasOneTimeCode = true
	p.publishConfiguration()
	count := func() int {
		data, err := os.ReadFile(filepath.Join(directory, "authorization-count"))
		must(err)
		value, err := strconv.Atoi(string(data))
		must(err)
		return value
	}
	before := count()
	revision := uint64(0)
	publish := func(password string, sites []string) *pb.SignedCopyUpdate {
		revision++
		destination := relaycrypto.CopyDestinationID(key.EncryptionPublicKey)
		update := &pb.CopyUpdate{Domain: "agentkeyring.copy-update.v1", DestinationKeyId: destination, ConfigurationRevision: p.configuration.Revision, Revision: revision}
		if password != "" {
			contents := &pb.AutomaticLoginContents{LoginId: "fixture-login", Sites: sites, Username: "fixture-user", Password: password, TotpSeed: []byte("12345678901234567890"), TotpPeriodSeconds: 30, TotpDigits: 6, TotpAlgorithm: "SHA1"}
			public, err := ecdh.P256().NewPublicKey(key.EncryptionPublicKey)
			must(err)
			hpkeKey, err := hpke.NewDHKEMPublicKey(public)
			must(err)
			enc, sealer, err := hpke.NewSender(hpkeKey, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte(relaycrypto.CopyLoginInfo))
			must(err)
			raw := encoded(contents)
			ciphertext, err := sealer.Seal(relaycrypto.CopyLoginAAD(destination, update.ConfigurationRevision, revision, contents.LoginId), raw)
			clear(raw)
			must(err)
			update.Logins = []*pb.SealedAutomaticLogin{{LoginId: contents.LoginId, Sealed: &pb.SealedBundle{EncapsulatedKey: enc, Ciphertext: ciphertext, ReceiverKeyId: destination}}}
		}
		raw := encoded(update)
		signed := &pb.SignedCopyUpdate{Update: raw, Signature: sign(signer, raw), SignerKeyId: hex.EncodeToString(relaycrypto.Hash(public(signer)))}
		require(good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishCopyUpdate{PublishCopyUpdate: signed}})).GetPublish().Accepted, "phone copy publication failed")
		require(count() == before, "copy synchronization requested authentication")
		return signed
	}
	sequence := 0
	request := func() (*pb.Lease, []byte, string, *pb.RequestLeaseRequest) {
		sequence++
		command := leaseRequest(fmt.Sprintf("copy-%d", sequence), fmt.Sprintf("copy-task-%d", sequence), p.enrolled.RecipientId)
		lease := good(p.client.call(command)).GetClient().GetLease()
		raw := p.phoneRequest(lease.LeaseId)
		good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_EscalateToPhone{EscalateToPhone: &pb.PhoneEscalation{LeaseId: lease.LeaseId, Record: raw}}}))
		id := hex.EncodeToString(relaycrypto.Digest("agentkeyring.request.v1", raw))
		phone.wait("requests", id+"=waitingForYou")
		return lease, raw, id, command.GetClient().GetRequestLease()
	}
	open := func(lease *pb.Lease, request *pb.RequestLeaseRequest, password string) {
		delivery := good(p.client.call(deliverRequest(lease.LeaseId, fmt.Sprintf("copy-open-%d", sequence)))).GetClient().GetDelivery()
		signed := delivery.GetSealed().Decision
		statement := new(pb.DecisionStatement)
		must(proto.Unmarshal(signed.Statement, statement))
		require(signed.ApproverKeyId == key.KeyId && statement.Authority == pb.DecisionAuthority_DECISION_AUTHORITY_HUMAN && signed.PhoneDecision == nil && statement.ConfigurationRevision == 0, "phone did not deliver a direct HUMAN decision")
		receiver := p.receiverClient(lease, request)
		values, _, err := receiver.OpenValues(context.Background(), lease, delivery)
		must(err)
		require(values.Password == password && values.OneTimeCode != "", "real receiver did not open the refreshed phone login and code")
		values.Password = ""
		values.OneTimeCode = ""
	}
	first := publish("phone-copy-password-one", []string{"https://example.com"})
	lease, _, id, requested := request()
	require(strings.Contains(phone.command("approve\t"+id), "approved"), "current copy did not deliver directly")
	require(count() == before+1, "opening and signing needed more than one authorization")
	before = count()
	open(lease, requested, "phone-copy-password-one")
	require(strings.Contains(phone.command("end\t"+id), "ended"), "direct phone lease did not revoke")
	publish("phone-copy-password-two", []string{"https://example.com"})
	require(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishCopyUpdate{PublishCopyUpdate: first}}).GetError() != nil, "older phone copy replay accepted")
	phone.stop()
	phone = startPhone(phone.cmd.Path, directory)
	lease, _, id, requested = request()
	require(strings.Contains(phone.command("approve\t"+id), "approved"), "refreshed copy did not survive reopen")
	require(count() == before+1, "refresh/open needed extra authorization")
	before = count()
	open(lease, requested, "phone-copy-password-two")
	phone.command("end\t" + id)
	fmt.Println("PASS actual Swift phone syncs sealed copies without authorization; one authorization opens and signs HUMAN delivery; real Go receiver opens current password and TOTP; password-only refresh survives reopen; old replay refused")

	// A current signed envelope can still contain wrong sites; only the phone can open it.
	publish("wrong-site-password", []string{"https://wrong.example"})
	lease, _, id, _ = request()
	require(strings.Contains(phone.command("approve\t"+id), "opened login copy does not match"), "phone did not refuse decrypted site mismatch")
	require(count() == before+1, "bad-copy check used extra authorization")
	before = count()
	require(good(p.client.call(clientRequest(&pb.WireRequest{Request: &pb.WireRequest_GetLease{GetLease: &pb.LeaseReference{LeaseId: lease.LeaseId}}}))).GetClient().GetLease().State == pb.LeaseState_LEASE_STATE_PENDING, "bad copy granted a lease")
	phone.command("deny\t" + id)
	phone.command("clear\t" + id)
	publish("phone-copy-password-two", []string{"https://example.com"})

	// Stale configuration means no password is held, while approval-only still works.
	p.publishConfiguration()
	lease, raw, id, _ := request()
	require(strings.Contains(phone.command("approve\t"+id), "waitingForMac"), "stale copy did not fall back to approval-only")
	answer := p.receivePhoneAnswer()
	require(good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_Decide{Decide: p.deliverPhone(raw, answer, signer)}})).GetDecision().Accepted, "stale-copy fallback Mac delivery failed")
	phone.wait("requests", id+"=approved")
	require(count() == before+1, "fallback prompted twice")
	before = count()
	phone.command("end\t" + id)
	fmt.Println("PASS actual Swift phone refuses opened site mismatch; stale configuration drops the copy and falls back to approval-only on the same lease")

	publish("phone-copy-password-three", []string{"https://example.com"})
	// Phone wins. Discard its ACK, then let the Mac submit its competing decision.
	lease, raw, id, requested = request()
	phone.command("stop") // Prevent a lease push from substituting for the dropped ACK.
	hold := filepath.Join(directory, "hold-authorization")
	must(os.WriteFile(hold, []byte("hold"), 0600))
	phone.send("approve\t" + id)
	deadline := time.Now().Add(20 * time.Second)
	for count() != before+1 {
		require(time.Now().Before(deadline), "authorization not reached")
		time.Sleep(20 * time.Millisecond)
	}
	network.Lock()
	network.loseReply = true
	network.Unlock()
	must(os.Rename(hold, hold+".released"))
	for {
		current := good(p.client.call(clientRequest(&pb.WireRequest{Request: &pb.WireRequest_GetLease{GetLease: &pb.LeaseReference{LeaseId: lease.LeaseId}}}))).GetClient().GetLease()
		if current.State == pb.LeaseState_LEASE_STATE_ACTIVE {
			require(current.ApprovedBy == pb.ApprovedBy_APPROVED_BY_IPHONE, "phone did not win")
			break
		}
		require(time.Now().Before(deadline), "phone delivery not committed")
		time.Sleep(20 * time.Millisecond)
	}
	losing := good(p.approver.call(p.decision(raw, false))).GetDecision()
	require(!losing.Accepted && losing.Lease.ApprovedBy == pb.ApprovedBy_APPROVED_BY_IPHONE, "Mac replaced the phone winner")
	network.down()
	require(strings.Contains(phone.line(), "sendingAnswer"), "phone received the lost ACK")
	phone.stop()
	p.work.Close()
	p.stop()
	p.start()
	p.work = p.approver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: p.key.KeyId}}})
	network.Lock()
	network.loseReply = false
	network.Unlock()
	network.up()
	phone = startPhone(phone.cmd.Path, directory)
	phone.wait("requests", id+"=approved")
	require(count() == before+1, "direct delivery replay asked twice")
	before = count()
	open(lease, requested, "phone-copy-password-three")
	phone.command("end\t" + id)
	fmt.Println("PASS phone wins one remote lease; competing Mac answer loses; lost direct-delivery ACK, relay and phone restart replay the identical signed decision without another authorization")

	// Mac wins while the phone is authorizing. Stop the watch so the losing
	// phone really submits Decide and displays the returned Mac outcome.
	lease, raw, id, _ = request()
	phone.command("stop")
	must(os.WriteFile(hold, []byte("hold"), 0600))
	phone.send("approve\t" + id)
	deadline = time.Now().Add(20 * time.Second)
	for count() != before+1 {
		require(time.Now().Before(deadline), "race authorization not reached")
		time.Sleep(20 * time.Millisecond)
	}
	mac := good(p.approver.call(p.decision(raw, false))).GetDecision()
	require(mac.Accepted && mac.Lease.ApprovedBy == pb.ApprovedBy_APPROVED_BY_MAC, "Mac did not win")
	must(os.Rename(hold, hold+".released"))
	outcome := phone.line()
	require(strings.Contains(outcome, "approved(") && strings.Contains(outcome, ".mac"), "losing phone did not return the committed Mac outcome")
	phone.wait("requests", id+"=approved")
	require(count() == before+1, "losing phone prompted again")
	fmt.Println("PASS Mac wins the same lease while phone authorizes; losing Swift Decide shows the Mac outcome without a second prompt")
	before = count()
	phone.command("end\t" + id)
	phone.command("start")

	// A pending request reaches the actual phone when the last Mac watcher drops.
	sequence++
	command := leaseRequest(fmt.Sprintf("copy-%d", sequence), fmt.Sprintf("copy-task-%d", sequence), p.enrolled.RecipientId)
	lease = good(p.client.call(command)).GetClient().GetLease()
	raw = p.phoneRequest(lease.LeaseId)
	id = hex.EncodeToString(relaycrypto.Digest("agentkeyring.request.v1", raw))
	p.work.Close()
	phone.wait("requests", id+"=waitingForYou")
	require(strings.Contains(phone.command("approve\t"+id), "approved"), "phone could not deliver with Mac disconnected")
	require(count() == before+1, "offline Mac delivery needed extra authorization")
	open(lease, command.GetClient().GetRequestLease(), "phone-copy-password-three")
	phone.command("end\t" + id)
	fmt.Println("PASS last Mac watcher disconnect escalates a waiting request; actual Swift phone delivers and real Go receiver opens it with the Mac offline")
	return phone
}
