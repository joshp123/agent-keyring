// Written by AI on 2026.10.31 by model gpt-6.1-sol.
// Real relay TLS, real receiver, simulated Face ID keys and HTTP/2 APNs gateway.
package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"github.com/joshp123/agent-keyring/internal/remote"
	"google.golang.org/protobuf/proto"
)

type pushReceipt struct {
	path, collapse, authorization string
	expires                       int64
}
type pushGateway struct {
	sync.Mutex
	receipts   []pushReceipt
	failStatus int
	drop       bool
	key        *ecdsa.PrivateKey
}

func (g *pushGateway) serve(w http.ResponseWriter, r *http.Request) {
	g.Lock()
	defer g.Unlock()
	require(r.ProtoMajor == 2 && r.Method == "POST", "push transport is not HTTP/2 POST")
	parts := strings.Split(strings.TrimPrefix(r.Header.Get("authorization"), "bearer "), ".")
	require(len(parts) == 3, "missing JWT")
	header, err := base64.RawURLEncoding.DecodeString(parts[0])
	must(err)
	claims, err := base64.RawURLEncoding.DecodeString(parts[1])
	must(err)
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	must(err)
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	require(len(signature) == 64 && ecdsa.Verify(&g.key.PublicKey, digest[:], new(big.Int).SetBytes(signature[:32]), new(big.Int).SetBytes(signature[32:])), "invalid JWT ES256 signature")
	var h struct{ Alg, Kid string }
	must(json.Unmarshal(header, &h))
	require(h.Alg == "ES256" && h.Kid == "DUMMYKEY01", "wrong JWT header")
	var c struct {
		Iss string
		Iat int64
	}
	must(json.Unmarshal(claims, &c))
	require(c.Iss == "DUMMYTEAM1" && c.Iat <= time.Now().Unix() && c.Iat > time.Now().Add(-time.Hour).Unix(), "wrong JWT claims")
	payload, err := io.ReadAll(r.Body)
	must(err)
	require(string(payload) == `{"aps":{"alert":"An agent is asking for a login.","sound":"default"}}`, "push leaked metadata or changed generic alert")
	require(r.Header.Get("apns-topic") == "test.agent-keyring.phone" && r.Header.Get("apns-push-type") == "alert" && r.Header.Get("apns-priority") == "10", "wrong push headers")
	var expiry int64
	_, err = fmt.Sscan(r.Header.Get("apns-expiration"), &expiry)
	must(err)
	require(len(r.Header.Get("apns-collapse-id")) == 64, "collapse ID missing or oversized")
	g.receipts = append(g.receipts, pushReceipt{r.URL.Path, r.Header.Get("apns-collapse-id"), r.Header.Get("authorization"), expiry})
	if g.drop {
		g.drop = false
		panic(http.ErrAbortHandler)
	}
	if g.failStatus != 0 {
		status := g.failStatus
		g.failStatus = 0
		w.WriteHeader(status)
		fmt.Fprint(w, `{"reason":"Unregistered"}`)
		return
	}
	w.WriteHeader(200)
}
func (g *pushGateway) waitCount(count int) []pushReceipt {
	deadline := time.Now().Add(12 * time.Second)
	for time.Now().Before(deadline) {
		g.Lock()
		receipts := append([]pushReceipt{}, g.receipts...)
		g.Unlock()
		if len(receipts) >= count {
			return receipts
		}
		time.Sleep(25 * time.Millisecond)
	}
	panic("expected push did not arrive")
}
func (g *pushGateway) count() int { g.Lock(); defer g.Unlock(); return len(g.receipts) }
func phoneAnswer(record []byte, key *ecdsa.PrivateKey, keyID, reply string, deny bool) *pb.SignedPhoneDecision {
	request := new(pb.RequestRecord)
	must(proto.Unmarshal(record, request))
	now := time.Now().Unix()
	decision := &pb.PhoneDecision{Domain: "agentkeyring.phonedecision.v1", RequestDigest: relaycrypto.Digest("agentkeyring.request.v1", record), LeaseId: request.LeaseId, Choice: pb.DecisionChoice_DECISION_CHOICE_APPROVE, DecidedUnixSeconds: now, NotAfterUnixSeconds: now + 1700, ReplySha256: relaycrypto.Hash([]byte(reply))}
	if deny {
		decision.Choice = pb.DecisionChoice_DECISION_CHOICE_DENY
		decision.NotAfterUnixSeconds = 0
	}
	raw := encoded(decision)
	answer := &pb.SignedPhoneDecision{Decision: raw, PhoneKeyId: keyID, Reply: reply}
	if !deny || reply != "" {
		answer.Signature = sign(key, raw)
	}
	return answer
}
func (p *proof) phoneDelivery(record []byte, answer *pb.SignedPhoneDecision, key *ecdsa.PrivateKey) *pb.RelayWireRequest {
	phone := new(pb.PhoneDecision)
	must(proto.Unmarshal(answer.Decision, phone))
	r := p.decision(record, phone.Choice == pb.DecisionChoice_DECISION_CHOICE_DENY, phone.NotAfterUnixSeconds-phone.DecidedUnixSeconds, phone.DecidedUnixSeconds)
	signed := r.GetDecide()
	statement := new(pb.DecisionStatement)
	must(proto.Unmarshal(signed.Statement, statement))
	statement.Authority = pb.DecisionAuthority_DECISION_AUTHORITY_PHONE
	statement.ApprovedAtUnixSeconds = phone.DecidedUnixSeconds
	statement.NotAfterUnixSeconds = phone.NotAfterUnixSeconds
	statement.ReplySha256 = phone.ReplySha256
	signed.Statement = encoded(statement)
	signed.Signature = sign(key, signed.Statement)
	signed.ApproverKeyId = "fixture-delivery"
	signed.PhoneDecision = answer
	signed.Reply = answer.Reply
	return r
}
func (p *proof) phoneApprovalProof() {
	gateway := &pushGateway{key: signingKey()}
	server := httptest.NewUnstartedServer(http.HandlerFunc(gateway.serve))
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()
	raw, err := x509.MarshalPKCS8PrivateKey(gateway.key)
	must(err)
	keyPath := filepath.Join(p.directory, "dummy-apns.p8")
	caPath := filepath.Join(p.directory, "dummy-apns-ca.pem")
	must(os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: raw}), 0600))
	must(os.WriteFile(caPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw}), 0600))
	p.extraFlags = []string{"--apns-key", keyPath, "--apns-key-id", "DUMMYKEY01", "--apns-team-id", "DUMMYTEAM1", "--apns-topic", "test.agent-keyring.phone", "--apns-test-gateway", server.URL, "--apns-test-ca", caPath}
	p.start()
	defer p.stop()
	p.pair()
	defer p.work.Close()
	p.enrol()
	// Publish roster, pair a phone, then add the non-TLS delivery signing key.
	machine := &pb.EnrolledMachine{RecipientId: p.enrolled.RecipientId, MachineLabel: p.enrolled.MachineLabel, ClientLabel: p.enrolled.ClientLabel, TailscaleNodeId: p.enrolled.TailscaleNodeId, TlsPublicKey: p.enrolled.TlsPublicKey, ReceiverPublicKey: p.enrolled.ReceiverPublicKey, ReceiverKeyId: p.enrolled.ReceiverKeyId}
	roster := encoded(&pb.EnrolmentSet{Domain: "agentkeyring.enrolments.v1", Revision: 1, Machines: []*pb.EnrolledMachine{machine}})
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishEnrolmentSet{PublishEnrolmentSet: &pb.SignedEnrolmentSet{EnrolmentSet: roster, Signature: sign(p.signer, roster), ApproverKeyId: p.key.KeyId}}}))
	phone := wireClient{address: p.address, certificate: identity(filepath.Join(p.directory, "approval-phone")), pin: p.approver.pin}
	phoneSigner := signingKey()
	spki, err := relaycrypto.CertificateSPKI(phone.certificate)
	must(err)
	phoneKey := &pb.ApproverKey{KeyId: "fixture-phone", Label: "Dummy iPhone", PublicKey: public(phoneSigner), TlsPublicKey: spki, Role: pb.ApproverRole_APPROVER_ROLE_PHONE}
	pairing := phone.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PairApprover{PairApprover: &pb.PairApproverRequest{Key: phoneKey, TlsPublicKey: spki}}})
	defer pairing.Close()
	good(receive(pairing))
	deliverySigner := signingKey()
	deliveryKey := &pb.ApproverKey{KeyId: "fixture-delivery", PublicKey: public(deliverySigner), Role: pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY}
	next := encoded(&pb.ApproverKeySet{Domain: "agentkeyring.approvers.v1", Revision: 2, Keys: []*pb.ApproverKey{p.key, phoneKey, deliveryKey}, RuleOwnerKeyId: p.key.KeyId, EnrolmentSetRevision: 1, EnrolmentSetSha256: relaycrypto.Hash(roster), PairingTranscriptSha256: relaycrypto.Hash(relaycrypto.PairTranscript(p.approver.pin, spki, phoneKey.PublicKey, p.keys.KeySet))})
	p.keys = &pb.SignedApproverKeySet{KeySet: next, Signature: sign(p.signer, next), SignerKeyId: p.key.KeyId}
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: p.keys}}))
	good(receive(pairing))
	reg := &pb.RelayWireRequest{Request: &pb.RelayWireRequest_RegisterPush{RegisterPush: &pb.PushRegistration{ApproverKeyId: phoneKey.KeyId, ApnsDeviceToken: []byte("dummy-token")}}}
	require(p.client.call(reg).GetError() != nil && p.approver.call(reg).GetError() != nil, "non-phone registered a phone token")
	good(phone.call(reg))
	leaseReq := leaseRequest("phone-approval-request", "phone-approval-task", p.enrolled.RecipientId)
	lease := good(p.client.call(leaseReq)).GetClient().GetLease()
	record := p.nextRequest()
	escalation := &pb.RelayWireRequest{Request: &pb.RelayWireRequest_EscalateToPhone{EscalateToPhone: &pb.PhoneEscalation{LeaseId: lease.LeaseId, Record: record}}}
	require(phone.call(escalation).GetError() != nil, "phone could escalate")
	// Non-escalated remote requests cannot be answered by the phone.
	answer := phoneAnswer(record, phoneSigner, phoneKey.KeyId, "", false)
	require(phone.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_AnswerFromPhone{AnswerFromPhone: answer}}).GetError() != nil, "un-escalated answer accepted")
	good(p.approver.call(escalation))
	good(p.approver.call(escalation))
	receipts := gateway.waitCount(1)
	require(receipts[0].path == "/sandbox/3/device/"+hex.EncodeToString([]byte("dummy-token")) && receipts[0].expires == lease.PendingUntilUnixSeconds, "sandbox gateway or original expiry differs")
	phoneWork := phone.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: phoneKey.KeyId}}})
	defer phoneWork.Close()
	var pending *pb.PendingRequest
	for pending == nil {
		pending = good(receive(phoneWork)).GetWork().GetRequest()
	}
	require(bytes.Equal(pending.Record, record) && pending.SourceMacKeyId == p.key.KeyId && pending.LocalLease == nil, "phone escalation source differs")
	// Lose the answer acknowledgement, then kill and restart the actual relay.
	lost := phone.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_AnswerFromPhone{AnswerFromPhone: answer}})
	p.nextPhoneAnswer(answer)
	lost.Close()
	p.work.Close()
	p.stop()
	p.start()
	ack := good(phone.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_AnswerFromPhone{AnswerFromPhone: answer}})).GetDecision()
	require(ack.Accepted && ack.Lease.State == pb.LeaseState_LEASE_STATE_PENDING, "answer was lost or falsely committed approval")
	p.work = p.approver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: p.key.KeyId}}})
	defer p.work.Close()
	p.nextPhoneAnswer(answer)
	good(p.approver.call(escalation))
	time.Sleep(1200 * time.Millisecond)
	require(gateway.count() == 1, "restart or escalation retry duplicated successful notification")
	decision := p.phoneDelivery(record, answer, deliverySigner)
	require(phone.call(decision).GetError() != nil, "phone could deliver passwords")
	for _, candidate := range []struct {
		id  string
		key *ecdsa.PrivateKey
	}{{phoneKey.KeyId, phoneSigner}, {"fixture-delivery", deliverySigner}} {
		invalid := proto.Clone(decision).(*pb.RelayWireRequest)
		signed := invalid.GetDecide()
		statement := new(pb.DecisionStatement)
		must(proto.Unmarshal(signed.Statement, statement))
		statement.Authority = pb.DecisionAuthority_DECISION_AUTHORITY_HUMAN
		signed.Statement = encoded(statement)
		signed.ApproverKeyId = candidate.id
		signed.Signature = sign(candidate.key, signed.Statement)
		require(p.approver.call(invalid).GetError() != nil, "non-Mac key signed a HUMAN decision")
	}
	require(good(p.approver.call(decision)).GetDecision().Accepted, "Mac phone delivery refused")
	begin := good(p.client.call(beginRequest(lease.LeaseId, "phone-delivery"))).GetClient().GetBeginOperation()
	receiver := p.receiverClient(lease, leaseReq.GetClient().GetRequestLease())
	values, _, err := receiver.OpenValues(context.Background(), lease, begin)
	must(err)
	require(values.Password == "fixture-password-for-relay-system-proof", "real receiver did not open phone-authorized login")
	values.Password = ""
	p.rejectPhoneTampering(receiver, lease, begin, deliverySigner)
	good(p.client.call(endRequest(lease.LeaseId)))
	retry := good(p.approver.call(decision)).GetDecision()
	require(retry.Accepted && retry.Lease.State == pb.LeaseState_LEASE_STATE_RELEASED, "phone delivery retry reopened released lease")
	fmt.Println("PASS one generic HTTP/2 ES256 APNs notification; exact retry and relay restart preserve phone consent; real receiver opens Mac delivery without a phone vault")
	p.remotePhoneDenialProof(phone, phoneSigner, phoneKey.KeyId, deliverySigner)
	p.phoneRemoteLeaseViewProof(phone, phoneKey.KeyId)
	p.localPhoneProof(phone, phoneSigner, phoneKey.KeyId, gateway)
}
func (p *proof) nextPhoneAnswer(expected *pb.SignedPhoneDecision) {
	for {
		work := good(receive(p.work)).GetWork()
		if work.GetPhoneDecision() != nil {
			require(proto.Equal(work.GetPhoneDecision(), expected), "forwarded phone answer changed")
			return
		}
	}
}
func (p *proof) receiverClient(lease *pb.Lease, scope *pb.RequestLeaseRequest) *remote.Client {
	store := clientstate.Store{Directory: filepath.Join(p.directory, "real-receiver-state")}
	must(store.Update(context.Background(), func(state *clientstate.State) error {
		state.RelayAddress = p.address
		state.RelaySpki = p.approver.pin
		state.RecipientId = p.enrolled.RecipientId
		state.ReceiverKeyId = p.enrolled.ReceiverKeyId
		state.Approvers = p.keys
		state.Requests = append(state.Requests, &clientstate.ExpectedRequest{LeaseId: lease.LeaseId, Scope: scope})
		return nil
	}))
	return &remote.Client{Store: store, Keys: &clientstate.PrivateKeys{ReceiverPrivateKey: p.receiver.D.FillBytes(make([]byte, 32))}, Certificate: p.client.certificate}
}
func (p *proof) rejectPhoneTampering(receiver *remote.Client, lease *pb.Lease, begin *pb.BeginOperationResponse, key *ecdsa.PrivateKey) {
	for _, mode := range []string{"missing-phone", "invalid-phone-signature", "different-deadline", "different-digest", "different-time", "different-lease", "different-choice", "different-reply", "invalid-delivery-signature", "wrong-delivery-role"} {
		altered := proto.Clone(begin).(*pb.BeginOperationResponse)
		signed := altered.GetSealed().Decision
		statement := new(pb.DecisionStatement)
		must(proto.Unmarshal(signed.Statement, statement))
		switch mode {
		case "missing-phone":
			signed.PhoneDecision = nil
		case "invalid-phone-signature":
			signed.PhoneDecision.Signature[0] ^= 1
		case "different-deadline":
			statement.NotAfterUnixSeconds--
		case "different-digest":
			statement.RequestDigest[0] ^= 1
		case "different-time":
			statement.ApprovedAtUnixSeconds--
		case "different-lease":
			statement.LeaseId = "different"
		case "different-choice":
			statement.Choice = pb.DecisionChoice_DECISION_CHOICE_DENY
		case "different-reply":
			signed.Reply = "Changed instruction"
			statement.ReplySha256 = relaycrypto.Hash([]byte(signed.Reply))
		case "wrong-delivery-role":
			signed.ApproverKeyId = p.key.KeyId
		}
		signed.Statement = encoded(statement)
		signed.Signature = sign(key, signed.Statement)
		if mode == "invalid-delivery-signature" {
			signed.Signature[0] ^= 1
		}
		if mode == "wrong-delivery-role" {
			signed.Signature = sign(p.signer, signed.Statement)
		}
		_, _, err := receiver.OpenValues(context.Background(), lease, altered)
		require(err != nil, "receiver accepted "+mode)
	}
	fmt.Println("PASS real receiver refuses missing/invalid phone signature, mismatched deadline/digest/time/lease/choice/reply, invalid Mac signature and wrong signing role")
}
func (p *proof) localPhoneProof(phone wireClient, signer *ecdsa.PrivateKey, keyID string, gateway *pushGateway) {
	now := time.Now().Unix()
	record := &pb.RequestRecord{LeaseId: "fixture-local-phone", RequestId: "fixture-local-request", LoginId: "fixture-login", TaskRef: "local-task", Purpose: pb.Purpose_PURPOSE_AGENT_PROCESS, Reason: "Dummy local sign-in", RecipientId: "local-not-enrolled", CreatedUnixSeconds: now, PendingUntilUnixSeconds: now + 600}
	raw := encoded(record)
	local := &pb.Lease{LeaseId: record.LeaseId, LoginId: record.LoginId, TaskRef: record.TaskRef, Purpose: record.Purpose, Reason: record.Reason, Recipient: &pb.Recipient{RecipientId: record.RecipientId, MachineLabel: "Dummy Mac"}, RequestedAtUnixSeconds: now, PendingUntilUnixSeconds: now + 600, State: pb.LeaseState_LEASE_STATE_PENDING}
	escalation := &pb.RelayWireRequest{Request: &pb.RelayWireRequest_EscalateToPhone{EscalateToPhone: &pb.PhoneEscalation{LeaseId: local.LeaseId, Record: raw, LocalLease: local}}}
	reg := &pb.RelayWireRequest{Request: &pb.RelayWireRequest_RegisterPush{RegisterPush: &pb.PushRegistration{ApproverKeyId: keyID, ApnsDeviceToken: []byte("production-dummy"), ApnsProduction: true}}}
	good(phone.call(reg))
	good(p.approver.call(escalation))
	receipts := gateway.waitCount(2)
	require(strings.HasPrefix(receipts[1].path, "/production/"), "production build used sandbox gateway")
	require(p.client.call(beginRequest(local.LeaseId, "local-steal")).GetError() != nil, "local display copy allowed receiver delivery")
	// A plain phone denial needs no signature, but only its pinned phone can send it.
	answer := phoneAnswer(raw, signer, keyID, "", true)
	require(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_AnswerFromPhone{AnswerFromPhone: answer}}).GetError() != nil, "Mac submitted phone answer")
	require(good(phone.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_AnswerFromPhone{AnswerFromPhone: answer}})).GetDecision().Accepted, "plain phone denial refused")
	p.nextPhoneAnswer(answer)
	update := func(lease *pb.Lease) *pb.RelayWireRequest {
		return &pb.RelayWireRequest{Request: &pb.RelayWireRequest_UpdateLocalPhoneLease{UpdateLocalPhoneLease: &pb.LocalPhoneLeaseUpdate{Lease: lease, RequestDigest: relaycrypto.Digest("agentkeyring.request.v1", raw)}}}
	}
	denied := proto.Clone(local).(*pb.Lease)
	denied.State = pb.LeaseState_LEASE_STATE_DENIED
	denied.EndedAtUnixSeconds = time.Now().Unix()
	denied.RetryNotBeforeUnixSeconds = now + 1800
	require(phone.call(update(denied)).GetError() != nil, "phone reported authoritative local outcome")
	require(good(p.approver.call(update(denied))).GetDecision().Accepted, "Mac local outcome refused")
	good(phone.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_ClearDenial{ClearDenial: &pb.ClearDenialRequest{RecipientId: record.RecipientId, LoginId: record.LoginId}}}))
	var action *pb.LocalLeaseAction
	for action == nil {
		action = good(receive(p.work)).GetWork().GetLocalLeaseAction()
	}
	require(action.GetClearDenial() != nil, "local ClearDenial action missing")
	p.work.Close()
	p.stop()
	p.start()
	p.work = p.approver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: p.key.KeyId}}})
	defer p.work.Close()
	action = nil
	for action == nil {
		action = good(receive(p.work)).GetWork().GetLocalLeaseAction()
	}
	require(action.GetClearDenial() != nil, "local action lost on restart")
	denied.RetryNotBeforeUnixSeconds = 0
	require(good(p.approver.call(update(denied))).GetDecision().Accepted, "local suppression clear report refused")
	require(!good(p.approver.call(update(local))).GetDecision().Accepted, "older snapshot reopened terminal local lease")
	good(p.approver.call(escalation))
	time.Sleep(1100 * time.Millisecond)
	require(gateway.count() == 2, "local retry re-notified after answer")
	// A second local request gets an End action, but its state remains pending until the Mac reports.
	record.LeaseId = "fixture-local-revoke"
	record.RequestId = "fixture-local-revoke-request"
	local.LeaseId = record.LeaseId
	raw = encoded(record)
	escalation.GetEscalateToPhone().LeaseId = record.LeaseId
	escalation.GetEscalateToPhone().Record = raw
	escalation.GetEscalateToPhone().LocalLease = local
	good(p.approver.call(escalation))
	gateway.waitCount(3)
	revoked := good(phone.call(revokeLeaseRequest(local.LeaseId))).GetLease()
	require(revoked.State == pb.LeaseState_LEASE_STATE_PENDING, "relay falsely claimed to revoke local authority")
	action = nil
	for action == nil {
		action = good(receive(p.work)).GetWork().GetLocalLeaseAction()
	}
	require(action.GetRevokeLease().GetLeaseId() == local.LeaseId, "local revoke not sent to owner")
	ended := proto.Clone(local).(*pb.Lease)
	ended.State = pb.LeaseState_LEASE_STATE_REVOKED
	ended.EndedAtUnixSeconds = time.Now().Unix()
	require(good(p.approver.call(update(ended))).GetDecision().Accepted, "local revoke report refused")
	require(good(phone.call(revokeLeaseRequest(local.LeaseId))).GetLease().State == pb.LeaseState_LEASE_STATE_REVOKED, "local revoke result not mirrored")
	fmt.Println("PASS production gateway; unsigned phone Deny; local copies never deliver; durable owner-only outcomes and actions; stale reports cannot reopen local leases")
	// Drop an HTTP/2 response after reading the POST: retry must reuse collapse ID.
	gateway.Lock()
	gateway.drop = true
	gateway.Unlock()
	record.LeaseId = "fixture-push-retry"
	record.RequestId = "fixture-push-retry-request"
	local.LeaseId = record.LeaseId
	raw = encoded(record)
	escalation.GetEscalateToPhone().LeaseId = record.LeaseId
	escalation.GetEscalateToPhone().Record = raw
	escalation.GetEscalateToPhone().LocalLease = local
	good(p.approver.call(escalation))
	receipts = gateway.waitCount(5)
	require(receipts[3].collapse == receipts[4].collapse && receipts[3].expires == receipts[4].expires, "uncertain push retry changed notification identity or expiry")
	require(receipts[3].authorization == receipts[4].authorization, "provider token rotated on every notification")
	local.State = pb.LeaseState_LEASE_STATE_CANCELLED
	local.EndedAtUnixSeconds = time.Now().Unix()
	good(p.approver.call(update(local)))
	// Invalid tokens are discarded, while fetching/answering requests remains usable.
	gateway.Lock()
	gateway.failStatus = 410
	gateway.Unlock()
	record.LeaseId = "fixture-invalid-token"
	record.RequestId = "fixture-invalid-token-request"
	local.LeaseId = record.LeaseId
	local.State = pb.LeaseState_LEASE_STATE_PENDING
	local.EndedAtUnixSeconds = 0
	raw = encoded(record)
	escalation.GetEscalateToPhone().LeaseId = record.LeaseId
	escalation.GetEscalateToPhone().Record = raw
	escalation.GetEscalateToPhone().LocalLease = local
	good(p.approver.call(escalation))
	gateway.waitCount(6)
	time.Sleep(1200 * time.Millisecond)
	require(gateway.count() == 6, "invalid device token retried")
	good(phone.call(reg))
	gateway.waitCount(7)
	fmt.Println("PASS uncertain push response retries with stable collapse ID; cached provider token; inactive device token stops notifications and replacement registration recovers")
}

func (p *proof) remotePhoneDenialProof(phone wireClient, key *ecdsa.PrivateKey, keyID string, deliveryKey *ecdsa.PrivateKey) {
	good(phone.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_RegisterPush{RegisterPush: &pb.PushRegistration{ApproverKeyId: keyID}}}))
	request := leaseRequest("phone-denial-request", "phone-denial-task", p.enrolled.RecipientId)
	lease := good(p.client.call(request)).GetClient().GetLease()
	var record []byte
	for record == nil {
		candidate := p.nextRequest()
		parsed := new(pb.RequestRecord)
		must(proto.Unmarshal(candidate, parsed))
		if parsed.LeaseId == lease.LeaseId {
			record = candidate
		}
	}
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_EscalateToPhone{EscalateToPhone: &pb.PhoneEscalation{LeaseId: lease.LeaseId, Record: record}}}))
	answer := phoneAnswer(record, key, keyID, "Use the dummy staging account instead.", true)
	bad := proto.Clone(answer).(*pb.SignedPhoneDecision)
	bad.Signature[0] ^= 1
	require(phone.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_AnswerFromPhone{AnswerFromPhone: bad}}).GetError() != nil, "invalid signed denial accepted")
	require(good(phone.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_AnswerFromPhone{AnswerFromPhone: answer}})).GetDecision().Accepted, "signed phone denial refused")
	p.nextPhoneAnswer(answer)
	require(good(p.approver.call(p.phoneDelivery(record, answer, deliveryKey))).GetDecision().Accepted, "Mac reply denial refused")
	receiver := p.receiverClient(lease, request.GetClient().GetRequestLease())
	denied, err := receiver.Authority().Lease(context.Background(), lease.LeaseId)
	must(err)
	require(denied.Reply == answer.Reply && denied.SignedDenial != nil, "real receiver did not verify both denial signatures")
	good(phone.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_ClearDenial{ClearDenial: &pb.ClearDenialRequest{RecipientId: p.enrolled.RecipientId, LoginId: lease.LoginId}}}))
	fmt.Println("PASS signed phone denial reply passes through Mac and real receiver; invalid phone signature refused; ClearDenial preserves the denied lease")
}

func (p *proof) phoneRemoteLeaseViewProof(phone wireClient, keyID string) {
	lease := good(p.client.call(leaseRequest("not-escalated", "mac-panel-task", p.enrolled.RecipientId))).GetClient().GetLease()
	var raw []byte
	for raw == nil {
		candidate := p.nextRequest()
		record := new(pb.RequestRecord)
		must(proto.Unmarshal(candidate, record))
		if record.LeaseId == lease.LeaseId {
			raw = candidate
		}
	}
	watch := phone.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: keyID}}})
	must(watch.SetReadDeadline(time.Now().Add(750 * time.Millisecond)))
	response := new(pb.RelayWireResponse)
	err := authority.ReadFrame(watch, response)
	watch.Close()
	require(err != nil, "phone received an un-escalated pending request")
	good(p.approver.call(p.decision(raw, false)))
	watch = phone.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: keyID}}})
	defer watch.Close()
	nextLease(watch, lease.LeaseId, pb.LeaseState_LEASE_STATE_ACTIVE)
	require(good(phone.call(revokeLeaseRequest(lease.LeaseId))).GetLease().State == pb.LeaseState_LEASE_STATE_REVOKED, "phone could not end Mac-approved remote lease")
	nextLease(watch, lease.LeaseId, pb.LeaseState_LEASE_STATE_REVOKED)
	require(p.client.call(beginRequest(lease.LeaseId, "after-phone-end")).GetError() != nil, "phone-ended Mac lease delivered")
	fmt.Println("PASS un-escalated pending requests stay on Mac; phone sees and ends active Mac-approved remote leases")
}
