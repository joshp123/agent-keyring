// Written by AI on 2026.10.31 by model gpt-6.1-sol.
// Real Swift approver / Go relay / Go HPKE receiver system proof, dummy only.
package main

import (
	"bufio"
	"bytes"
	"crypto/ecdh"
	"crypto/hpke"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"flag"
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
	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func must(err error) {
	if err != nil {
		if exit, ok := err.(*exec.ExitError); ok && len(exit.Stderr) > 0 {
			panic(string(exit.Stderr))
		}
		panic(err)
	}
}
func require(ok bool, message string) {
	if !ok {
		panic(message)
	}
}
func encode(m proto.Message) []byte { b, e := proto.Marshal(m); must(e); return b }

const loginID = "00000000-0000-0000-0000-000000000301"

type owner struct {
	command                *exec.Cmd
	input                  io.WriteCloser
	events                 chan []string
	pair                   string
	enrol                  []string
	requests               map[string][]string
	leases                 map[string][]string
	localLeases            map[string][]string
	queued, authorizations int
	backgroundSignatures   int
	saved                  map[string]string
	copies                 map[string]string
	applying               bool
	pairVisible            bool
	pendingApprovers       string
	expectedFailure        string
}

func startOwner(binary, root string) *owner {
	p := &owner{events: make(chan []string, 2048), requests: map[string][]string{}, leases: map[string][]string{}, localLeases: map[string][]string{}, saved: map[string]string{}, copies: map[string]string{}}
	p.command = exec.Command(binary, "--dummy-only", root)
	var err error
	p.input, err = p.command.StdinPipe()
	must(err)
	output, err := p.command.StdoutPipe()
	must(err)
	p.command.Stderr = os.Stderr
	must(p.command.Start())
	go func() {
		defer close(p.events)
		scanner := bufio.NewScanner(output)
		for scanner.Scan() {
			p.events <- strings.Split(scanner.Text(), "\t")
		}
	}()
	p.wait(func(e []string) bool { return e[0] == "READY" })
	return p
}
func (p *owner) wait(predicate func([]string) bool) []string {
	timeout := time.NewTimer(40 * time.Second)
	defer timeout.Stop()
	for {
		select {
		case e, ok := <-p.events:
			require(ok, "Swift approver exited")
			switch e[0] {
			case "SETUP":
				p.pairVisible = e[1] == "true"
				p.pendingApprovers = e[2]
			case "PAIR":
				p.pair = e[1]
			case "ENROL":
				p.enrol = e
			case "REQUEST":
				p.requests[e[2]] = e
			case "LEASE":
				p.leases[e[1]] = e
			case "LOCAL":
				p.localLeases[e[1]] = e
			case "STATUS":
				p.queued, _ = strconv.Atoi(e[2])
				p.authorizations, _ = strconv.Atoi(e[4])
				p.applying = e[5] == "true"
			case "COPY":
				p.copies[e[1]] = e[2]
			case "SAVED":
				p.saved[e[1]] = e[2]
			case "BACKGROUND":
				p.backgroundSignatures, _ = strconv.Atoi(e[1])
			case "FAILED":
				if e[1] != p.expectedFailure {
					panic(strings.Join(e, " "))
				}
			}
			if predicate(e) {
				return e
			}
		case <-timeout.C:
			panic("timed out waiting for Swift approver")
		}
	}
}
func (p *owner) action(parts ...string) {
	_, err := fmt.Fprintln(p.input, strings.Join(parts, "\t"))
	must(err)
	p.wait(func(e []string) bool { return e[0] == "DONE" && e[1] == parts[0] })
}
func (p *owner) status() { p.action("status") }
func (p *owner) expectFailure(parts ...string) []string {
	p.expectedFailure = parts[0]
	defer func() { p.expectedFailure = "" }()
	_, err := fmt.Fprintln(p.input, strings.Join(parts, "\t"))
	must(err)
	return p.wait(func(e []string) bool { return e[0] == "FAILED" && e[1] == parts[0] })
}
func (p *owner) stop() {
	if p.command != nil {
		p.input.Close()
		p.command.Process.Kill()
		p.command.Wait()
		p.command = nil
	}
}
func (p *owner) pending(lease string) string {
	if e := p.requests[lease]; len(e) > 0 {
		return e[1]
	}
	e := p.wait(func(e []string) bool { return e[0] == "REQUEST" && e[2] == lease })
	return e[1]
}

type client struct {
	address string
	cert    tls.Certificate
	pin     []byte
}

func (c client) open(request *pb.RelayWireRequest) *tls.Conn {
	var config *tls.Config
	if c.pin == nil {
		config = relaycrypto.ObservingClientConfig(c.cert, func([]byte) error { return nil })
	} else {
		var err error
		config, err = relaycrypto.ClientConfig(c.cert, c.pin)
		must(err)
	}
	conn, err := tls.DialWithDialer(&net.Dialer{Timeout: 5 * time.Second}, "tcp", c.address, config)
	must(err)
	must(conn.SetDeadline(time.Now().Add(30 * time.Second)))
	must(authority.WriteFrame(conn, request))
	return conn
}
func receive(c *tls.Conn) *pb.RelayWireResponse {
	r := new(pb.RelayWireResponse)
	must(authority.ReadFrame(c, r))
	if e := r.GetError(); e != nil {
		panic(e.String())
	}
	return r
}
func (c client) call(r *pb.RelayWireRequest) *pb.RelayWireResponse {
	conn := c.open(r)
	defer conn.Close()
	return receive(conn)
}
func request(r *pb.WireRequest) *pb.RelayWireRequest {
	return &pb.RelayWireRequest{Request: &pb.RelayWireRequest_Client{Client: r}}
}
func (c client) lease(task, recipient string) *pb.Lease {
	return c.call(request(&pb.WireRequest{Request: &pb.WireRequest_RequestLease{RequestLease: &pb.RequestLeaseRequest{LoginId: loginID, TaskRef: task, RequestId: task, Purpose: pb.Purpose_PURPOSE_BROWSER_SIGN_IN, Reason: "Dummy system sign-in", RecipientId: recipient}}})).GetClient().GetLease()
}
func (c client) status(lease string) *pb.Lease {
	return c.call(request(&pb.WireRequest{Request: &pb.WireRequest_GetLease{GetLease: &pb.LeaseReference{LeaseId: lease}}})).GetClient().GetLease()
}
func (c client) waitLease(lease string, state pb.LeaseState) *pb.Lease {
	for deadline := time.Now().Add(35 * time.Second); time.Now().Before(deadline); {
		l := c.status(lease)
		if l.State == state {
			return l
		}
		time.Sleep(100 * time.Millisecond)
	}
	panic("lease did not reach " + state.String())
}
func (c client) deliver(lease string) *pb.Delivery {
	return c.call(request(&pb.WireRequest{Request: &pb.WireRequest_Deliver{Deliver: &pb.DeliverRequest{LeaseId: lease, Kind: pb.OperationKind_OPERATION_KIND_FILL, Fields: []pb.CredentialField{pb.CredentialField_CREDENTIAL_FIELD_PASSWORD, pb.CredentialField_CREDENTIAL_FIELD_ONE_TIME_CODE}}}})).GetClient().GetDelivery()
}
func identity() tls.Certificate {
	cert, key, e := relaycrypto.NewIdentity("Mac approver dummy receiver")
	must(e)
	c, e := tls.X509KeyPair(cert, key)
	must(e)
	return c
}

type proof struct {
	root, relayBinary, fixture       string
	cli, cliRecipient, browserScript string
	phoneBinary, approverPort        string
	relay                            *exec.Cmd
	log                              *os.File
	owner                            *owner
	receiver                         client
	receiverKey                      *ecdh.PrivateKey
	keys                             *pb.SignedApproverKeySet
	recipient                        string
}

func (p *proof) startRelay() {
	var e error
	p.log, e = os.OpenFile(filepath.Join(p.root, "relay.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	must(e)
	p.relay = exec.Command(p.relayBinary, "--listen", "127.0.0.1:17445", "--state", filepath.Join(p.root, "relay"), "--loopback-test")
	p.relay.Stdout = p.log
	p.relay.Stderr = p.log
	must(p.relay.Start())
	for d := time.Now().Add(10 * time.Second); time.Now().Before(d); {
		c, e := net.DialTimeout("tcp", "127.0.0.1:17445", 50*time.Millisecond)
		if e == nil {
			c.Close()
			return
		}
		time.Sleep(30 * time.Millisecond)
	}
	panic("relay failed to start")
}
func (p *proof) stopRelay() {
	if p.relay != nil {
		p.relay.Process.Kill()
		p.relay.Wait()
		p.relay = nil
		p.log.Close()
	}
}
func (p *proof) pair() {
	port := p.approverPort
	if port == "" {
		port = "17445"
	}
	p.owner.action("pair", port)
	if p.owner.pair == "" {
		p.owner.wait(func(e []string) bool { return e[0] == "PAIR" })
	}
	log, e := os.ReadFile(filepath.Join(p.root, "relay.log"))
	must(e)
	require(bytes.Contains(log, []byte(p.owner.pair)), "Swift pairing fingerprint differs from Go relay log")
	p.owner.action("confirm", p.owner.pair)
	p.owner.status()
	require(p.owner.queued == 0, "setup publication not acknowledged")
	fmt.Println("PASS Swift/Go full pairing fingerprint and human-signed initial key set")
}
func (p *proof) enrol() {
	p.receiver = client{address: "127.0.0.1:17445", cert: identity()}
	var e error
	p.receiverKey, e = ecdh.P256().GenerateKey(rand.Reader)
	must(e)
	spki, e := relaycrypto.CertificateSPKI(p.receiver.cert)
	must(e)
	conn := p.receiver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_Enrol{Enrol: &pb.EnrolRequest{MachineLabel: "Dummy receiver", ClientLabel: "System proof", TlsPublicKey: spki, ReceiverPublicKey: p.receiverKey.PublicKey().Bytes()}}})
	defer conn.Close()
	pending := receive(conn).GetEnrolStatus()
	require(pending.State == pb.EnrolState_ENROL_STATE_PENDING, "not pending enrolment")
	p.receiver.pin = conn.ConnectionState().PeerCertificates[0].RawSubjectPublicKeyInfo
	p.keys = pending.ApproverKeySet
	fingerprint := relaycrypto.Fingerprint(relaycrypto.EnrolTranscript(p.receiver.pin, spki, p.receiverKey.PublicKey().Bytes(), p.keys.KeySet))
	if len(p.owner.enrol) == 0 {
		p.owner.wait(func(e []string) bool { return e[0] == "ENROL" })
	}
	require(p.owner.enrol[2] == fingerprint, "Swift enrol fingerprint differs from independently computed Go fingerprint")
	p.owner.action("enrol", p.owner.enrol[1], fingerprint, "true")
	approved := receive(conn).GetEnrolStatus()
	require(approved.State == pb.EnrolState_ENROL_STATE_APPROVED, "enrolment not approved")
	var keys pb.ApproverKeySet
	must(proto.Unmarshal(p.keys.KeySet, &keys))
	must(relaycrypto.Verify(keys.Keys[0].PublicKey, approved.Configuration.Configuration, approved.Configuration.Signature))
	require(bytes.Equal(pending.ApproverKeySet.KeySet, approved.ApproverKeySet.KeySet), "keyset changed")
	p.recipient = approved.RecipientId
	fmt.Println("PASS independently compared machine fingerprint, signed configuration listing the enrolled machine")
}
func (p *proof) open(delivery *pb.SealedDelivery, lease string) *pb.BundleContents {
	return p.openExpected(delivery, lease, "example-password")
}
func (p *proof) openExpected(delivery *pb.SealedDelivery, lease, password string) *pb.BundleContents {
	require(delivery != nil, "no sealed delivery")
	var st pb.DecisionStatement
	must(proto.Unmarshal(delivery.Decision.Statement, &st))
	var record pb.RequestRecord
	must(proto.Unmarshal(delivery.RequestRecord, &record))
	require(st.LeaseId == lease && record.LeaseId == lease && record.LoginId == loginID && record.RecipientId == p.recipient, "wrong delivery scope")
	require(bytes.Equal(st.RequestDigest, relaycrypto.Digest("agentkeyring.request.v1", delivery.RequestRecord)), "request digest differs")
	require(st.NotAfterUnixSeconds == st.ApprovedAtUnixSeconds+1800, "deadline is not fixed 30 minutes")
	require(bytes.Equal(st.BundleCiphertextSha256, relaycrypto.Hash(delivery.Bundle.Ciphertext)), "ciphertext hash differs")
	var public []byte
	if st.Authority == pb.DecisionAuthority_DECISION_AUTHORITY_HUMAN {
		var keys pb.ApproverKeySet
		must(proto.Unmarshal(p.keys.KeySet, &keys))
		public = keys.Keys[0].PublicKey
	} else {
		configuration := p.receiver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetConfiguration{GetConfiguration: &pb.GetConfigurationRequest{}}}).GetConfiguration()
		var keys pb.ApproverKeySet
		must(proto.Unmarshal(p.keys.KeySet, &keys))
		must(relaycrypto.Verify(keys.Keys[0].PublicKey, configuration.Configuration, configuration.Signature))
		var contents pb.Configuration
		must(proto.Unmarshal(configuration.Configuration, &contents))
		require(contents.Revision >= st.ConfigurationRevision, "Automatic configuration revision differs")
		public = contents.AutomaticSigningPublicKey
	}
	must(relaycrypto.Verify(public, delivery.Decision.Statement, delivery.Decision.Signature))
	key, e := hpke.NewDHKEMPrivateKey(p.receiverKey)
	must(e)
	opener, e := hpke.NewRecipient(delivery.Bundle.EncapsulatedKey, key, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte("agentkeyring.bundle.v1"))
	must(e)
	plaintext, e := opener.Open(st.RequestDigest, delivery.Bundle.Ciphertext)
	must(e)
	var contents pb.BundleContents
	must(proto.Unmarshal(plaintext, &contents))
	clear(plaintext)
	require(contents.Password == password && contents.Username == "example@example.com", "dummy credential mismatch")
	require(contents.LeaseId == lease && contents.NotAfterUnixSeconds == st.NotAfterUnixSeconds, "opened bundle scope differs")
	require(len(contents.OneTimeCodes) > 0 && len(contents.OneTimeCodes) <= 61, "TOTP steps missing")
	hasCurrentCode := false
	for i, c := range contents.OneTimeCodes {
		require(len(c.Code) == 6 && c.ValidUntilUnixSeconds <= st.NotAfterUnixSeconds, "invalid timed code")
		if i > 0 {
			require(contents.OneTimeCodes[i-1].ValidUntilUnixSeconds == c.ValidFromUnixSeconds, "gap in TOTP codes")
		}
		if c.ValidFromUnixSeconds <= time.Now().Unix() && time.Now().Unix() < c.ValidUntilUnixSeconds {
			hasCurrentCode = true
		}
	}
	require(hasCurrentCode, "delivery has no currently valid TOTP code")
	require(contents.OneTimeCodes[len(contents.OneTimeCodes)-1].ValidUntilUnixSeconds == st.NotAfterUnixSeconds, "codes exceed or miss deadline")
	return &contents
}
func (p *proof) run() {
	p.startRelay()
	defer p.stopRelay()
	p.owner = startOwner(p.fixture, p.root)
	defer func() { p.owner.stop() }()
	p.pair()
	p.enrol()
	p.realCLIProgram()
	l := p.receiver.lease("offline-after-approval", p.recipient)
	id := p.owner.pending(l.LeaseId)
	p.owner.status()
	before := p.owner.authorizations
	p.stopRelay()
	p.owner.action("approve", id)
	p.owner.action("saved")
	hash := p.owner.saved[id]
	require(hash != "", "approval not durable")
	p.owner.status()
	require(p.owner.authorizations == before+1 && p.owner.queued == 1, "approval did not queue exactly once")
	p.owner.stop()
	p.owner = startOwner(p.fixture, p.root)
	p.owner.action("saved")
	require(p.owner.saved[id] == hash, "restart changed signed decision or ciphertext")
	p.owner.status()
	require(p.owner.authorizations == before+1, "restart repeated approval")
	p.startRelay()
	active := p.receiver.waitLease(l.LeaseId, pb.LeaseState_LEASE_STATE_ACTIVE)
	first := p.receiver.deliver(l.LeaseId)
	p.open(first.GetSealed(), l.LeaseId)
	returned := proto.Clone(first.GetSealed().Decision).(*pb.SignedDecision)
	returned.Bundle = first.GetSealed().Bundle
	require(hex.EncodeToString(relaycrypto.Hash(encode(returned))) == hash, "relay received different decision bytes")
	p.owner.status()
	require(p.owner.authorizations == before+1, "reconnect asked again")
	fmt.Println("PASS network loss after approval, app restart, exact durable decision and Go HPKE opening with all TOTP steps")
	p.stopRelay()
	p.owner.stop()
	p.startRelay()
	p.owner = startOwner(p.fixture, p.root)
	require(p.receiver.status(l.LeaseId).NotAfterUnixSeconds == active.NotAfterUnixSeconds, "restart reset deadline")
	require(proto.Equal(p.receiver.deliver(l.LeaseId).GetSealed(), first.GetSealed()), "restart changed the accepted sealed delivery")
	p.open(p.receiver.deliver(l.LeaseId).GetSealed(), l.LeaseId)
	fmt.Println("PASS both restarts preserve the deadline and exact sealed delivery; receipts belong to the receiving CLI")
	p.owner.status()
	before = p.owner.authorizations
	d := p.receiver.lease("plain-deny", p.recipient)
	did := p.owner.pending(d.LeaseId)
	p.owner.action("deny", did)
	p.receiver.waitLease(d.LeaseId, pb.LeaseState_LEASE_STATE_DENIED)
	p.owner.status()
	require(p.owner.authorizations == before, "plain Deny requested biometrics")
	suppressed := p.receiver.lease("held-off", p.recipient)
	require(suppressed.State == pb.LeaseState_LEASE_STATE_DENIED, "denial hold-off lost")
	p.owner.action("clear", p.recipient)
	require(p.receiver.status(d.LeaseId).RetryNotBeforeUnixSeconds == 0, "relay denial history still shows a hold-off")
	p.owner.status()
	require(p.owner.requests[d.LeaseId][6] == "0", "Mac denial history still shows a hold-off")
	r := p.receiver.lease("reply-deny", p.recipient)
	rid := p.owner.pending(r.LeaseId)
	p.owner.action("deny", rid, "Use the example account only")
	denied := p.receiver.waitLease(r.LeaseId, pb.LeaseState_LEASE_STATE_DENIED)
	require(denied.Reply == "Use the example account only" && denied.SignedDenial != nil, "signed reply proof missing")
	p.owner.status()
	require(p.owner.authorizations == before+1, "reply did not use one authorization")
	fmt.Println("PASS plain Deny without a touch, signed reply with one, hold-off and remote ClearDenial")
	p.owner.action("clear", p.recipient)
	p.owner.action("rule", "auto")
	p.owner.status()
	before = p.owner.authorizations
	a := p.receiver.lease("automatic", p.recipient)
	p.receiver.waitLease(a.LeaseId, pb.LeaseState_LEASE_STATE_ACTIVE)
	p.open(p.receiver.deliver(a.LeaseId).GetSealed(), a.LeaseId)
	p.owner.status()
	require(p.owner.authorizations == before, "Automatic requested biometrics")
	p.realCLIBrowser()
	p.endRemoteLease(a.LeaseId)
	p.owner.action("rule", "ask")
	ask := p.receiver.lease("stale-grant", p.recipient)
	p.owner.pending(ask.LeaseId)
	time.Sleep(300 * time.Millisecond)
	require(p.receiver.status(ask.LeaseId).State == pb.LeaseState_LEASE_STATE_PENDING, "stale grant approved under Ask")
	fmt.Println("PASS delegated Automatic signing without a touch and confirmed own-rule enforcement and atomic configuration publication")
	p.addApprover()
	p.owner.action("revoke", p.recipient)
	conn := p.receiver.open(request(&pb.WireRequest{Request: &pb.WireRequest_GetLease{GetLease: &pb.LeaseReference{LeaseId: ask.LeaseId}}}))
	response := new(pb.RelayWireResponse)
	must(authority.ReadFrame(conn, response))
	conn.Close()
	require(response.GetError() != nil, "revoked machine still authorized")
	fmt.Println("PASS signed configuration revocation refuses the machine")
	fmt.Println("ALL MAC APPROVER SYSTEM PROOFS PASSED")
}
func main() {
	p := new(proof)
	pairingControls := flag.Bool("pairing-controls", false, "short pairing cancellation and resolved-address proof")
	localPhone := flag.Bool("local-phone-flow", false, "joint phone approval of local agent.sock requests")
	copyUpdates := flag.Bool("copy-updates", false, "Automatic copy refresh and outbox restart proof")
	phoneCopies := flag.Bool("phone-copy-updates", false, "Ask-only phone copy import and outbox restart proof")
	flag.StringVar(&p.phoneBinary, "phone-binary", "", "production Swift phone fixture; runs the joint phone flow")
	flag.StringVar(&p.root, "root", "", "fresh dummy root inside the app container")
	flag.StringVar(&p.fixture, "approver", "", "signed mini-only Swift fixture executable")
	flag.StringVar(&p.relayBinary, "relay", "", "relay executable")
	flag.StringVar(&p.cli, "cli", "", "actual Go client binary")
	flag.StringVar(&p.browserScript, "browser-script", "", "mini-only headless browser proof script")
	flag.Parse()
	require(p.root != "" && p.fixture != "" && p.relayBinary != "", "supply --root --approver --relay")
	must(os.MkdirAll(p.root, 0700))
	if *phoneCopies {
		p.runPhoneCopyUpdates()
	} else if *copyUpdates {
		p.runCopyUpdates()
	} else if *localPhone {
		require(p.phoneBinary != "", "--local-phone-flow needs --phone-binary")
		p.runLocalPhoneFlow()
	} else if p.phoneBinary != "" {
		p.runPhoneFlow()
	} else if *pairingControls {
		p.runPairingControls()
	} else {
		p.run()
	}
}
