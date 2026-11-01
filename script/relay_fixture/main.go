// Written by AI on 2026.10.31 by model gpt-6.1-sol.
// Scripted client/approver for the RFC 0005 system proof. Uses only fixture keys
// and opaque fixture ciphertext, never the Passwords mirror or real approvals.
package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hpke"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func require(ok bool, message string) {
	if !ok {
		panic(message)
	}
}
func encoded(m proto.Message) []byte { data, err := proto.Marshal(m); must(err); return data }
func sign(key *ecdsa.PrivateKey, data []byte) []byte {
	signature, err := ecdsa.SignASN1(rand.Reader, key, relaycrypto.Hash(data))
	must(err)
	return signature
}
func signingKey() *ecdsa.PrivateKey {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	must(err)
	return key
}
func public(key *ecdsa.PrivateKey) []byte { return elliptic.Marshal(elliptic.P256(), key.X, key.Y) }
func identity(directory string) tls.Certificate {
	must(os.MkdirAll(directory, 0700))
	certPath, keyPath := filepath.Join(directory, "cert.pem"), filepath.Join(directory, "key.pem")
	if _, err := os.Stat(certPath); errors.Is(err, os.ErrNotExist) {
		cert, key, err := relaycrypto.NewIdentity("relay fixture")
		must(err)
		must(os.WriteFile(certPath, cert, 0600))
		must(os.WriteFile(keyPath, key, 0600))
	}
	certificate, err := tls.LoadX509KeyPair(certPath, keyPath)
	must(err)
	return certificate
}

type wireClient struct {
	address     string
	certificate tls.Certificate
	pin         []byte
}

func (c wireClient) open(r *pb.RelayWireRequest) *tls.Conn {
	var config *tls.Config
	if c.pin == nil {
		config = relaycrypto.ObservingClientConfig(c.certificate, func([]byte) error { return nil })
	} else {
		var err error
		config, err = relaycrypto.ClientConfig(c.certificate, c.pin)
		must(err)
	}
	conn, err := tls.DialWithDialer(&net.Dialer{Timeout: 5 * time.Second}, "tcp", c.address, config)
	must(err)
	must(conn.SetDeadline(time.Now().Add(20 * time.Second)))
	must(authority.WriteFrame(conn, r))
	return conn
}
func receive(conn *tls.Conn) *pb.RelayWireResponse {
	for {
		r := new(pb.RelayWireResponse)
		must(authority.ReadFrame(conn, r))
		// Legacy scripted peers ignore public updates, without pretending to
		// acknowledge them. The receipt proof uses the production Go client.
		if r.GetTrustUpdate() == nil {
			return r
		}
	}
}
func (c wireClient) call(r *pb.RelayWireRequest) *pb.RelayWireResponse {
	conn := c.open(r)
	defer conn.Close()
	return receive(conn)
}
func good(r *pb.RelayWireResponse) *pb.RelayWireResponse {
	if r.GetError() != nil {
		panic(r.GetError().String())
	}
	return r
}
func clientRequest(r *pb.WireRequest) *pb.RelayWireRequest {
	return &pb.RelayWireRequest{Request: &pb.RelayWireRequest_Client{Client: r}}
}
func find() *pb.RelayWireRequest {
	return clientRequest(&pb.WireRequest{Request: &pb.WireRequest_FindLogins{FindLogins: &pb.FindLoginsRequest{Query: "example"}}})
}
func leaseRequest(id, task, recipient string) *pb.RelayWireRequest {
	return clientRequest(&pb.WireRequest{Request: &pb.WireRequest_RequestLease{RequestLease: &pb.RequestLeaseRequest{LoginId: "fixture-login", TaskRef: task, RequestId: id, RecipientId: recipient, Purpose: pb.Purpose_PURPOSE_BROWSER_SIGN_IN, Reason: "System proof"}}})
}
func deliverRequest(lease string, _ ...string) *pb.RelayWireRequest {
	return clientRequest(&pb.WireRequest{Request: &pb.WireRequest_Deliver{Deliver: &pb.DeliverRequest{LeaseId: lease, Kind: pb.OperationKind_OPERATION_KIND_FILL, Fields: []pb.CredentialField{pb.CredentialField_CREDENTIAL_FIELD_PASSWORD}}}})
}
func endRequest(lease string) *pb.RelayWireRequest {
	return clientRequest(&pb.WireRequest{Request: &pb.WireRequest_EndLease{EndLease: &pb.LeaseReference{LeaseId: lease}}})
}

type proof struct {
	address, directory, relayBinary string
	extraFlags                      []string
	process                         *exec.Cmd
	relayLog                        *os.File
	approver, client                wireClient
	signer                          *ecdsa.PrivateKey
	receiver                        *ecdsa.PrivateKey
	key                             *pb.ApproverKey
	keys                            *pb.SignedApproverKeySet
	enrolled                        *pb.EnrolmentRecord
	configuration                   *pb.Configuration
	signedConfiguration             *pb.SignedConfiguration
	pairingAutomaticKeys            *pb.AutomaticKeys
	work                            *tls.Conn
	browserFixture                  *browserFixture
}

func (p *proof) start() {
	p.process = exec.Command(p.relayBinary, append([]string{"--listen", p.address, "--state", filepath.Join(p.directory, "relay"), "--loopback-test"}, p.extraFlags...)...)
	p.process.Stdout = os.Stdout
	p.process.Stderr = os.Stderr
	if p.relayLog != nil {
		p.process.Stdout = p.relayLog
		p.process.Stderr = p.relayLog
	}
	must(p.process.Start())
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); {
		conn, err := net.DialTimeout("tcp", p.address, 100*time.Millisecond)
		if err == nil {
			conn.Close()
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	panic("relay did not start")
}
func (p *proof) stop() {
	if p.process != nil {
		must(p.process.Process.Kill())
		p.process.Wait()
		p.process = nil
	}
}
func (p *proof) pair() {
	p.signer = signingKey()
	spki, err := relaycrypto.CertificateSPKI(p.approver.certificate)
	must(err)
	p.key = &pb.ApproverKey{KeyId: hex.EncodeToString(relaycrypto.Hash(public(p.signer))), Label: "Fixture approver", PublicKey: public(p.signer), TlsPublicKey: spki}
	pair := &pb.PairApproverRequest{Key: p.key, TlsPublicKey: spki}
	conn := p.approver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PairApprover{PairApprover: pair}})
	defer conn.Close()
	pending := good(receive(conn))
	require(pending.GetEnrolStatus().GetState() == pb.EnrolState_ENROL_STATE_PENDING, "pair was not pending")
	p.pairingAutomaticKeys = pending.GetEnrolStatus().GetAutomaticKeys()
	require(len(p.pairingAutomaticKeys.GetSigningPublicKey()) == 65 && len(p.pairingAutomaticKeys.GetEncryptionPublicKey()) == 65, "pairing stream did not return Automatic keys")
	p.approver.pin = conn.ConnectionState().PeerCertificates[0].RawSubjectPublicKeyInfo
	transcript := relaycrypto.PairTranscript(p.approver.pin, spki, p.key.PublicKey, nil)
	fmt.Println("Fixture pair fingerprint:", relaycrypto.Fingerprint(transcript))
	confirmation := encoded(&pb.PairingConfirmation{Domain: "agentkeyring.pairconfirm.v1", TranscriptSha256: relaycrypto.Hash(transcript), ConfirmedUnixSeconds: time.Now().Unix()})
	data := encoded(&pb.ApproverKeySet{Domain: "agentkeyring.approvers.v1", Revision: 1, Keys: []*pb.ApproverKey{p.key}, RuleOwnerKeyId: p.key.KeyId, PairingTranscriptSha256: relaycrypto.Hash(transcript)})
	p.keys = &pb.SignedApproverKeySet{KeySet: data, Signature: sign(p.signer, data), SignerKeyId: p.key.KeyId}
	r := &pb.RelayWireRequest{Request: &pb.RelayWireRequest_ConfirmPairing{ConfirmPairing: &pb.SignedPairingConfirmation{Confirmation: confirmation, Signature: sign(p.signer, confirmation), ApproverKeyId: p.key.KeyId, InitialKeySet: p.keys}}}
	require(good(p.approver.call(r)).GetEnrolment().Accepted, "first pair failed")
	require(good(receive(conn)).GetEnrolStatus().State == pb.EnrolState_ENROL_STATE_APPROVED, "pair stream did not complete")
	require(good(p.approver.call(r)).GetEnrolment().Accepted, "pair retry failed")
	p.client.pin = p.approver.pin
	p.publishIndex(pb.AccessRule_ACCESS_RULE_ASK)
	p.work = p.approver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: p.key.KeyId}}})
}
func (p *proof) publishIndex(rule pb.AccessRule) {
	if p.configuration == nil {
		p.configuration = &pb.Configuration{Domain: "agentkeyring.configuration.v1"}
	}
	p.configuration.Logins = []*pb.Login{{LoginId: "fixture-login", Title: "example.com", Account: "fixture", Sites: []string{"https://example.com"}, Rule: rule, HasOneTimeCode: true}}
	p.publishConfiguration()
}
func (p *proof) publishConfiguration() {
	p.configuration.Revision++
	data := encoded(p.configuration)
	p.signedConfiguration = &pb.SignedConfiguration{Configuration: data, Signature: sign(p.signer, data), ApproverKeyId: p.key.KeyId}
	require(good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishConfiguration{PublishConfiguration: &pb.ConfigurationPublication{Configuration: p.signedConfiguration}}})).GetPublish().Accepted, "publish configuration failed")
}
func (p *proof) enrolledMachine(automatic bool) *pb.EnrolledMachine {
	r := p.enrolled
	return &pb.EnrolledMachine{RecipientId: r.RecipientId, MachineLabel: r.MachineLabel, ClientLabel: r.ClientLabel, TailscaleNodeId: r.TailscaleNodeId, TlsPublicKey: r.TlsPublicKey, ReceiverPublicKey: r.ReceiverPublicKey, ReceiverKeyId: r.ReceiverKeyId, AutomaticAllowed: automatic}
}
func (p *proof) nextRequest() []byte {
	for {
		r := good(receive(p.work))
		if r.GetWork().GetRequest() != nil {
			return r.GetWork().GetRequest().Record
		}
	}
}
func (p *proof) nextEnrolment() []byte {
	for {
		r := good(receive(p.work))
		if r.GetWork().GetEnrolment() != nil {
			return r.GetWork().GetEnrolment().Record
		}
	}
}
func (p *proof) approveEnrolment(record []byte, automatic ...bool) {
	p.enrolled = new(pb.EnrolmentRecord)
	must(proto.Unmarshal(record, p.enrolled))
	expected := relaycrypto.Fingerprint(relaycrypto.EnrolTranscript(p.approver.pin, p.enrolled.TlsPublicKey, p.enrolled.ReceiverPublicKey, p.keys.KeySet))
	require(p.enrolled.Code == expected, "enrol transcript mismatch")
	allowed := len(automatic) > 0 && automatic[0]
	p.configuration.Machines = append(p.configuration.Machines, p.enrolledMachine(allowed))
	p.publishConfiguration()
}
func (p *proof) enrol(automatic ...bool) {
	spki, err := relaycrypto.CertificateSPKI(p.client.certificate)
	must(err)
	receiver := signingKey()
	p.receiver = receiver
	r := &pb.RelayWireRequest{Request: &pb.RelayWireRequest_Enrol{Enrol: &pb.EnrolRequest{MachineLabel: "Fixture machine", ClientLabel: "Fixture agent", TlsPublicKey: spki, ReceiverPublicKey: public(receiver)}}}
	conn := p.client.open(r)
	defer conn.Close()
	require(good(receive(conn)).GetEnrolStatus().State == pb.EnrolState_ENROL_STATE_PENDING, "enrol not pending")
	record := p.nextEnrolment()
	p.approveEnrolment(record, automatic...)
	status := good(receive(conn)).GetEnrolStatus()
	require(status.State == pb.EnrolState_ENROL_STATE_APPROVED && proto.Equal(status.Configuration, p.signedConfiguration), "enrolment stream lost exact proof bytes")
	require(good(p.client.call(find())).GetClient().GetLogins().Logins[0].LoginId == "fixture-login", "enrolled client cannot find")
}
func (p *proof) decision(record []byte, deny bool, lifetime ...int64) *pb.RelayWireRequest {
	request := new(pb.RequestRecord)
	must(proto.Unmarshal(record, request))
	statement := &pb.DecisionStatement{Domain: "agentkeyring.decision.v1", RequestDigest: relaycrypto.Digest("agentkeyring.request.v1", record), Choice: pb.DecisionChoice_DECISION_CHOICE_APPROVE, ApprovedAtUnixSeconds: time.Now().Unix(), NotAfterUnixSeconds: time.Now().Unix() + 1800, RecipientId: p.enrolled.RecipientId, ReceiverKeyId: p.enrolled.ReceiverKeyId, LeaseId: request.LeaseId, ReplySha256: relaycrypto.Hash(nil), Authority: pb.DecisionAuthority_DECISION_AUTHORITY_HUMAN}
	if len(lifetime) > 1 {
		statement.ApprovedAtUnixSeconds = lifetime[1]
	}
	if len(lifetime) > 0 {
		statement.NotAfterUnixSeconds = statement.ApprovedAtUnixSeconds + lifetime[0]
	}
	receiverKey, err := ecdh.P256().NewPublicKey(p.enrolled.ReceiverPublicKey)
	must(err)
	hpkeKey, err := hpke.NewDHKEMPublicKey(receiverKey)
	must(err)
	encapsulated, sealer, err := hpke.NewSender(hpkeKey, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte("agentkeyring.bundle.v1"))
	must(err)
	values := &pb.BundleContents{LeaseId: request.LeaseId, LoginId: request.LoginId, Sites: []string{"https://example.com"}, Username: "fixture-user", Password: "fixture-password-for-relay-system-proof", NotAfterUnixSeconds: statement.NotAfterUnixSeconds}
	if p.browserFixture != nil {
		p.browserFixture.populate(values)
	}
	contents := encoded(values)
	ciphertext, err := sealer.Seal(statement.RequestDigest, contents)
	must(err)
	clear(contents)
	bundle := &pb.SealedBundle{EncapsulatedKey: encapsulated, Ciphertext: ciphertext, ReceiverKeyId: p.enrolled.ReceiverKeyId}
	statement.BundleCiphertextSha256 = relaycrypto.Hash(bundle.Ciphertext)
	reply := ""
	if deny {
		statement.Choice = pb.DecisionChoice_DECISION_CHOICE_DENY
		statement.BundleCiphertextSha256 = nil
		statement.NotAfterUnixSeconds = 0
		reply = "Fixture denial"
		statement.ReplySha256 = relaycrypto.Hash([]byte(reply))
		bundle = nil
	}
	data := encoded(statement)
	return &pb.RelayWireRequest{Request: &pb.RelayWireRequest_Decide{Decide: &pb.SignedDecision{Statement: data, Signature: sign(p.signer, data), ApproverKeyId: p.key.KeyId, Reply: reply, Bundle: bundle}}}
}
func (p *proof) revoke() {
	var retained []*pb.EnrolledMachine
	for _, machine := range p.configuration.Machines {
		if machine.RecipientId != p.enrolled.RecipientId {
			retained = append(retained, machine)
		}
	}
	p.configuration.Machines = retained
	p.publishConfiguration()
}
func (p *proof) local() {
	p.start()
	defer p.stop()
	p.pair()
	defer p.work.Close()
	stranger := wireClient{address: p.address, certificate: identity(filepath.Join(p.directory, "stranger")), pin: p.approver.pin}
	require(stranger.call(find()).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "unknown peer could call Find")
	p.enrol()
	fmt.Println("PASS initial pairing, exact enrolment proof and role authentication")
	p.approverLeaseProof()
	first := leaseRequest("request-1", "task-1", p.enrolled.RecipientId)
	l := good(p.client.call(first)).GetClient().GetLease()
	record := p.nextRequest()
	joined := good(p.client.call(leaseRequest("request-2", "task-1", p.enrolled.RecipientId))).GetClient().GetLease()
	require(joined.LeaseId == l.LeaseId, "concurrent scope did not join")
	conflictRequest := proto.Clone(first).(*pb.RelayWireRequest)
	conflictRequest.GetClient().GetRequestLease().Reason = "changed"
	require(p.client.call(conflictRequest).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_CONFLICT, "request retry mutation accepted")
	decision := p.decision(record, false)
	tampered := proto.Clone(decision).(*pb.RelayWireRequest)
	tampered.GetDecide().Signature[0] ^= 1
	require(p.approver.call(tampered).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "tampered signature accepted")
	watchRequest := clientRequest(&pb.WireRequest{Request: &pb.WireRequest_WatchLease{WatchLease: &pb.LeaseReference{LeaseId: l.LeaseId}}})
	watch := p.client.open(watchRequest)
	require(good(receive(watch)).GetClient().GetLease().PendingUntilUnixSeconds == l.PendingUntilUnixSeconds, "watch changed pending deadline")
	watch.Close()
	watch = p.client.open(watchRequest)
	require(good(receive(watch)).GetClient().GetLease().LeaseId == l.LeaseId, "watch reconnect lost pending request")
	approved := good(p.approver.call(decision)).GetDecision()
	require(approved.Accepted, "decision refused")
	require(good(receive(watch)).GetClient().GetLease().State == pb.LeaseState_LEASE_STATE_ACTIVE, "watch missed activation")
	watch.Close()
	require(good(p.approver.call(decision)).GetDecision().Accepted, "decision resend refused")
	altered := proto.Clone(decision).(*pb.RelayWireRequest)
	altered.GetDecide().Reply = "tamper"
	require(!good(p.approver.call(altered)).GetDecision().Accepted, "conflicting decision accepted")
	begin := deliverRequest(l.LeaseId, "step-1")
	started := good(p.client.call(begin)).GetClient().GetDelivery()
	require(started.GetSealed() != nil && bytes.Equal(started.GetSealed().RequestRecord, record), "delivery lost signed request bytes")
	require(started.GetSealed().Decision.Bundle == nil, "bundle attachment duplicated")
	fmt.Println("PASS request joining, conflicting retry IDs, signed approval and delivery")
	p.work.Close()
	p.stop()
	p.start()
	retry := good(p.client.call(begin)).GetClient().GetDelivery()
	require(proto.Equal(retry, started), "restart lost the original sealed delivery")
	require(good(p.approver.call(decision)).GetDecision().Accepted, "restart lost decision")
	afterRestart := good(p.client.call(clientRequest(&pb.WireRequest{Request: &pb.WireRequest_GetLease{GetLease: &pb.LeaseReference{LeaseId: l.LeaseId}}}))).GetClient().GetLease()
	require(afterRestart.NotAfterUnixSeconds == approved.Lease.NotAfterUnixSeconds && afterRestart.ApprovedAtUnixSeconds == approved.Lease.ApprovedAtUnixSeconds, "restart extended approval deadline")
	require(good(p.client.call(endRequest(l.LeaseId))).GetClient().GetLease().State == pb.LeaseState_LEASE_STATE_RELEASED, "release failed")
	require(p.client.call(deliverRequest(l.LeaseId, "step-3")).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "released lease delivered")
	require(good(p.client.call(first)).GetClient().GetLease().State == pb.LeaseState_LEASE_STATE_RELEASED, "request retry created a new lease")
	fmt.Println("PASS SIGKILL restart, exact sealed delivery, unchanged deadline and release")
	p.work = p.approver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: p.key.KeyId}}})
	p.delegationProof()
	expiryLease := good(p.client.call(leaseRequest("request-expiry", "task-expiry", p.enrolled.RecipientId))).GetClient().GetLease()
	expiryDecision := p.decision(p.nextRequest(), false, 2)
	require(good(p.approver.call(expiryDecision)).GetDecision().Accepted, "short signed deadline refused")
	approverExpiry := p.watchWork()
	nextLease(approverExpiry, expiryLease.LeaseId, pb.LeaseState_LEASE_STATE_ACTIVE)
	watch = p.client.open(clientRequest(&pb.WireRequest{Request: &pb.WireRequest_WatchLease{WatchLease: &pb.LeaseReference{LeaseId: expiryLease.LeaseId}}}))
	require(good(receive(watch)).GetClient().GetLease().State == pb.LeaseState_LEASE_STATE_ACTIVE, "expiry watcher missed active lease")
	require(good(receive(watch)).GetClient().GetLease().State == pb.LeaseState_LEASE_STATE_EXPIRED, "signed deadline did not expire")
	nextLease(approverExpiry, expiryLease.LeaseId, pb.LeaseState_LEASE_STATE_EXPIRED)
	approverExpiry.Close()
	watch.Close()
	require(good(p.approver.call(expiryDecision)).GetDecision().Accepted, "accepted decision resend refused after expiry")
	require(p.client.call(deliverRequest(expiryLease.LeaseId, "expired-operation")).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "expired lease delivered")
	cancelLease := good(p.client.call(leaseRequest("request-cancel", "task-cancel", p.enrolled.RecipientId))).GetClient().GetLease()
	lateDecision := p.decision(p.nextRequest(), false)
	require(good(p.client.call(endRequest(cancelLease.LeaseId))).GetClient().GetLease().State == pb.LeaseState_LEASE_STATE_CANCELLED, "pending release did not cancel")
	require(!good(p.approver.call(lateDecision)).GetDecision().Accepted, "late approval reactivated cancelled lease")
	policyLease := good(p.client.call(leaseRequest("request-policy", "task-policy", p.enrolled.RecipientId))).GetClient().GetLease()
	require(good(p.approver.call(p.decision(p.nextRequest(), false))).GetDecision().Accepted, "policy lease refused")
	p.publishIndex(pb.AccessRule_ACCESS_RULE_BLOCKED)
	require(p.client.call(deliverRequest(policyLease.LeaseId, "blocked-operation")).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "policy change did not revoke active lease")
	p.publishIndex(pb.AccessRule_ACCESS_RULE_ASK)
	fmt.Println("PASS WatchLease reconnect, signed expiry, accepted resend after expiry, cancellation and current-policy revocation")
	pending := good(p.client.call(leaseRequest("request-denied", "task-denied", p.enrolled.RecipientId))).GetClient().GetLease()
	denial := p.decision(p.nextRequest(), true)
	denialView := p.watchWork()
	nextLease(denialView, pending.LeaseId, pb.LeaseState_LEASE_STATE_PENDING)
	signedDenial := good(p.approver.call(denial)).GetDecision()
	denialUpdate := nextLease(denialView, pending.LeaseId, pb.LeaseState_LEASE_STATE_DENIED)
	denialView.Close()
	require(signedDenial.Accepted, "deny failed")
	require(signedDenial.Lease.SignedDenial != nil && signedDenial.Lease.SignedDenial.Bundle == nil, "denial ack lost proof")
	deniedSnapshot := clientRequest(&pb.WireRequest{Request: &pb.WireRequest_GetLease{GetLease: &pb.LeaseReference{LeaseId: pending.LeaseId}}})
	assertProof := func(snapshot *pb.Lease) {
		require(snapshot.SignedDenial != nil && snapshot.SignedDenial.Bundle == nil && proto.Equal(snapshot.SignedDenial.Decision, denial.GetDecide()), "lease response lost exact denial decision")
		statement := new(pb.DecisionStatement)
		must(proto.Unmarshal(snapshot.SignedDenial.Decision.Statement, statement))
		require(bytes.Equal(statement.RequestDigest, relaycrypto.Digest("agentkeyring.request.v1", snapshot.SignedDenial.RequestRecord)), "denial request bytes changed")
		must(relaycrypto.Verify(p.key.PublicKey, snapshot.SignedDenial.Decision.Statement, snapshot.SignedDenial.Decision.Signature))
	}
	assertProof(good(p.client.call(deniedSnapshot)).GetClient().GetLease())
	assertProof(good(p.client.call(clientRequest(&pb.WireRequest{Request: &pb.WireRequest_WatchLease{WatchLease: &pb.LeaseReference{LeaseId: pending.LeaseId}}}))).GetClient().GetLease())
	assertProof(good(p.client.call(endRequest(pending.LeaseId))).GetClient().GetLease())
	assertProof(denialUpdate)
	assertProof(good(p.approver.call(revokeLeaseRequest(pending.LeaseId))).GetLease())
	suppressed := good(p.client.call(leaseRequest("request-suppressed", "new-task", p.enrolled.RecipientId))).GetClient().GetLease()
	require(suppressed.State == pb.LeaseState_LEASE_STATE_DENIED && suppressed.RetryNotBeforeUnixSeconds > 0, "human denial did not suppress")
	require(pending.LeaseId != suppressed.LeaseId && suppressed.SignedDenial == nil && suppressed.Reply == "", "suppression claimed a signed reply for the wrong request")
	fmt.Println("PASS signed denial reply proof in ack, GetLease, WatchLease and EndLease")
	p.publishIndex(pb.AccessRule_ACCESS_RULE_BLOCKED)
	blocked := good(p.client.call(leaseRequest("blocked", "blocked-task", p.enrolled.RecipientId))).GetClient().GetLease()
	require(blocked.State == pb.LeaseState_LEASE_STATE_DENIED, "blocked request prompted")
	p.connectionDenialProof()
	p.dismissEnrolmentProof()
	p.retentionProof()
	p.setupExpiryProof()
	p.revoke()
	require(p.client.call(find()).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "revoked client authorized")
	fmt.Println("PASS human denial suppression, Blocked policy and machine revocation")
}
func main() {
	leaseID := flag.String("lease", "", "Receiver proof lease")
	deliveryPath := flag.String("delivery", "", "Receiver proof sealed delivery")
	mode := flag.String("mode", "proof", "proof, phone, tailnet, or machine")
	phoneBinary := flag.String("phone-binary", "", "Swift phone fixture for phone mode")
	legacyPhoneBinary := flag.String("legacy-phone-binary", "", "Previous approval-only Swift fixture to prove replacement from its saved pairing")
	address := flag.String("address", "127.0.0.1:0", "Relay address")
	directory := flag.String("state", "", "Fixture directory")
	relayBinary := flag.String("relay", "", "Relay binary for loopback proof")
	pinHex := flag.String("pin", "", "Relay SPKI hex for machine mode")
	action := flag.String("action", "enrol", "Machine action: enrol or find")
	linuxHost := flag.String("linux", "mini-server-1", "Linux proof host")
	remoteBinary := flag.String("remote-binary", "", "Linux fixture binary path")
	copySite := flag.String("site", "https://example.com", "Dummy copy login origin")
	browserFixturePath := flag.String("browser-fixture", "", "Dummy test_login_server fixture for scripted browser approvals")
	flag.Parse()
	if *directory == "" {
		var err error
		*directory, err = os.MkdirTemp("", "keyring-relay-proof-")
		must(err)
	}
	if *mode == "receipt-receiver" {
		receiptReceiver(*directory, *leaseID, *deliveryPath)
		return
	}
	if *mode == "machine" {
		machine(*address, *directory, *pinHex, *action)
		return
	}
	p := &proof{address: *address, directory: *directory, relayBinary: *relayBinary}
	if *mode == "proof" || *mode == "phone" || *mode == "phone-approval" || *mode == "phone-copy" || *mode == "receipts" || *mode == "idle" {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		must(err)
		p.address = listener.Addr().String()
		listener.Close()
	}
	p.approver = wireClient{address: p.address, certificate: identity(filepath.Join(p.directory, "approver"))}
	p.client = wireClient{address: p.address, certificate: identity(filepath.Join(p.directory, "receiver"))}
	if *mode == "copy" {
		p.copyFixture(*action, *copySite)
		return
	}
	if *mode == "approver" {
		if *browserFixturePath != "" {
			p.browserFixture = loadBrowserFixture(*browserFixturePath)
		}
		p.serveApprover()
		return
	}
	if *mode == "receipts" {
		p.receiptProof()
	} else if *mode == "idle" {
		p.idleProof()
	} else if *mode == "phone-approval" {
		p.phoneApprovalProof()
	} else if *mode == "phone-copy" {
		p.phoneCopyProof()
	} else if *mode == "phone" {
		p.phoneProof(*phoneBinary, *legacyPhoneBinary)
	} else if *mode == "tailnet" {
		p.tailnet(*linuxHost, *remoteBinary)
	} else {
		p.local()
	}
	fmt.Println("All relay system checks passed. Fixture state:", p.directory)
}
func machine(address, directory, pinHex, action string) {
	pin, err := hex.DecodeString(pinHex)
	must(err)
	c := wireClient{address: address, certificate: identity(directory), pin: pin}
	if action == "find" {
		response := c.call(find())
		if response.GetError() != nil {
			fmt.Println(response.GetError().Code)
			os.Exit(3)
		}
		good(response)
		fmt.Println("authorized")
		return
	}
	spki, err := relaycrypto.CertificateSPKI(c.certificate)
	must(err)
	receiverPath := filepath.Join(directory, "receiver-public")
	receiver, err := os.ReadFile(receiverPath)
	if errors.Is(err, os.ErrNotExist) {
		receiver = public(signingKey())
		must(os.WriteFile(receiverPath, receiver, 0600))
	} else {
		must(err)
	}
	conn := c.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_Enrol{Enrol: &pb.EnrolRequest{MachineLabel: "Fixture Linux machine", ClientLabel: "Fixture agent", TlsPublicKey: spki, ReceiverPublicKey: receiver}}})
	defer conn.Close()
	for {
		status := good(receive(conn)).GetEnrolStatus()
		if status.State == pb.EnrolState_ENROL_STATE_APPROVED {
			must(os.WriteFile(filepath.Join(directory, "enrolment.pb"), encoded(status), 0600))
			fmt.Println("approved", status.RecipientId)
			break
		}
		require(status.State == pb.EnrolState_ENROL_STATE_PENDING, "enrolment did not approve")
	}
	good(c.call(find()))
	fmt.Println("authorized")
}
func (p *proof) tailnet(linuxHost, binary string) {
	require(binary != "", "remote-binary required")
	p.pair()
	defer p.work.Close()
	remoteDir := filepath.Dir(binary) + "/receiver"
	args := []string{linuxHost, binary, "--mode", "machine", "--address", p.address, "--state", remoteDir, "--pin", hex.EncodeToString(p.approver.pin)}
	process := exec.Command("ssh", args...)
	process.Stdout = os.Stdout
	process.Stderr = os.Stderr
	must(process.Start())
	p.approveEnrolment(p.nextEnrolment())
	must(process.Wait())
	fmt.Println("PASS real Linux enrolment over Tailscale")
	copyDir := filepath.Join(p.directory, "copied-receiver")
	must(os.MkdirAll(copyDir, 0700))
	for _, name := range []string{"cert.pem", "key.pem"} {
		command := exec.Command("scp", linuxHost+":"+remoteDir+"/"+name, filepath.Join(copyDir, name))
		output, err := command.CombinedOutput()
		if err != nil {
			panic(string(output))
		}
	}
	copied := wireClient{address: p.address, certificate: identity(copyDir), pin: p.approver.pin}
	require(copied.call(find()).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "same receiver keys authorized from different node")
	fmt.Println("PASS same Linux TLS keys refused from MacBook's different Tailscale node")
	p.revoke()
	args = append(args, "--action", "find")
	command := exec.Command("ssh", args...)
	output, err := command.CombinedOutput()
	require(err != nil && bytes.Contains(output, []byte("PERMISSION_DENIED")), "revoked Linux machine was not refused: "+string(output))
	fmt.Println("PASS enrolled Linux machine refused after signed revocation")
}

func (p *proof) serveApprover() {
	p.pair()
	defer p.work.Close()
	must(p.work.SetDeadline(time.Time{}))
	if p.browserFixture != nil {
		p.configuration.Logins[0].Sites = []string{p.browserFixture.Origin}
		p.configuration.Logins[0].Title = "Dummy browser login"
		p.configuration.Logins[0].Account = p.browserFixture.Username
		p.publishConfiguration()
	}
	fmt.Println("Fixture approver ready. Only dummy credentials are published.")
	for {
		work := good(receive(p.work)).GetWork()
		switch item := work.Item.(type) {
		case *pb.ApproverWork_Enrolment:
			p.approveEnrolment(item.Enrolment.Record)
			fmt.Println("Fixture machine approved:", p.enrolled.RecipientId)
		case *pb.ApproverWork_Request:
			request := new(pb.RequestRecord)
			must(proto.Unmarshal(item.Request.Record, request))
			for _, machine := range p.configuration.Machines {
				if machine.RecipientId == request.RecipientId {
					p.enrolled = &pb.EnrolmentRecord{RecipientId: machine.RecipientId, MachineLabel: machine.MachineLabel, ClientLabel: machine.ClientLabel, TailscaleNodeId: machine.TailscaleNodeId, TlsPublicKey: machine.TlsPublicKey, ReceiverPublicKey: machine.ReceiverPublicKey, ReceiverKeyId: machine.ReceiverKeyId}
					break
				}
			}
			require(p.enrolled != nil && p.enrolled.RecipientId == request.RecipientId, "unknown fixture receiver")
			require(request.LoginId == "fixture-login", "fixture approver refuses unknown login")
			require(good(p.approver.call(p.decision(item.Request.Record, false))).GetDecision().Accepted, "fixture decision refused")
			fmt.Println("Fixture lease approved:", request.LeaseId)
		}
	}
}
