// Written by AI on 2026.10.31 by model gpt-6.1-sol.
// Full phone core against the real relay. Software keys stand in for Face ID;
// the Mac fixture supplies dummy logins, then signed encrypted copies.
package main

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"database/sql"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
	_ "modernc.org/sqlite"
)

type phoneProcess struct {
	cmd    *exec.Cmd
	input  io.WriteCloser
	output *bufio.Scanner
}

func startPhone(binary, directory string) *phoneProcess {
	cmd := exec.Command(binary, "--dummy-state", directory)
	input, err := cmd.StdinPipe()
	must(err)
	output, err := cmd.StdoutPipe()
	must(err)
	cmd.Stderr = os.Stderr
	must(cmd.Start())
	phone := &phoneProcess{cmd, input, bufio.NewScanner(output)}
	require(phone.line() == "READY", "phone fixture did not start")
	return phone
}
func (p *phoneProcess) line() string {
	result := make(chan string, 1)
	go func() {
		if p.output.Scan() {
			result <- p.output.Text()
		} else {
			result <- "EOF"
		}
	}()
	select {
	case line := <-result:
		return line
	case <-time.After(30 * time.Second):
		panic("phone fixture timed out")
	}
}
func (p *phoneProcess) send(command string)           { _, err := fmt.Fprintln(p.input, command); must(err) }
func (p *phoneProcess) command(command string) string { p.send(command); return p.line() }
func (p *phoneProcess) stop()                         { p.send("quit"); must(p.cmd.Wait()) }
func (p *phoneProcess) wait(command, contains string) string {
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		result := p.command(command)
		if strings.Contains(result, contains) {
			return result
		}
		require(!strings.HasPrefix(result, "ERROR"), result)
		time.Sleep(100 * time.Millisecond)
	}
	panic("phone never reported " + contains)
}

// This fixture's Go TLS 1.3 server sends five encrypted handshake records
// (extensions, certificate request, certificate, certificate verify, finished).
// Drop subsequent encrypted replies while forwarding the client's request.
// The Mac independently receives the committed phone answer before the
// connection is cut. This establishes a lost ack, not merely a failed send.
type phoneNetwork struct {
	sync.Mutex
	target, address string
	listener        net.Listener
	connections     []net.Conn
	loseReply       bool
	dropped         int
}

func (n *phoneNetwork) up() {
	listener, err := net.Listen("tcp", n.address)
	must(err)
	n.Lock()
	n.listener = listener
	n.address = listener.Addr().String()
	n.Unlock()
	go func() {
		for {
			downstream, err := listener.Accept()
			if err != nil {
				return
			}
			upstream, err := net.Dial("tcp", n.target)
			must(err)
			n.Lock()
			lose := n.loseReply
			n.connections = append(n.connections, downstream, upstream)
			n.Unlock()
			go func() { defer downstream.Close(); defer upstream.Close(); io.Copy(upstream, downstream) }()
			go func() {
				defer downstream.Close()
				defer upstream.Close()
				encrypted := 0
				for {
					header := make([]byte, 5)
					if _, err := io.ReadFull(upstream, header); err != nil {
						return
					}
					payload := make([]byte, int(binary.BigEndian.Uint16(header[3:])))
					if _, err := io.ReadFull(upstream, payload); err != nil {
						return
					}
					if header[0] == 23 {
						encrypted++
					}
					if lose && encrypted > 5 {
						n.Lock()
						n.dropped++
						n.Unlock()
						continue
					}
					if _, err := downstream.Write(append(header, payload...)); err != nil {
						return
					}
				}
			}()
		}
	}()
}
func (n *phoneNetwork) down() {
	n.Lock()
	defer n.Unlock()
	n.listener.Close()
	for _, connection := range n.connections {
		connection.Close()
	}
	n.connections = nil
}

func (p *proof) receivePhoneAnswer() *pb.SignedPhoneDecision {
	for {
		work := good(receive(p.work)).GetWork()
		if work.GetPhoneDecision() != nil {
			return work.GetPhoneDecision()
		}
	}
}

// The Mac substitute owns the dummy password. The Swift phone receives only
// the signed configuration and request; it never creates a vault or imports a login.
func (p *proof) deliverPhone(record []byte, phone *pb.SignedPhoneDecision, deliveryKey *ecdsa.PrivateKey) *pb.SignedDecision {
	decision := p.phoneDelivery(record, phone, deliveryKey).GetDecide()
	decision.ApproverKeyId = hex.EncodeToString(relaycrypto.Hash(public(deliveryKey)))
	answer := new(pb.PhoneDecision)
	must(proto.Unmarshal(phone.Decision, answer))
	if answer.Choice == pb.DecisionChoice_DECISION_CHOICE_DENY && phone.Reply == "" {
		statement := new(pb.DecisionStatement)
		must(proto.Unmarshal(decision.Statement, statement))
		statement.Authority = pb.DecisionAuthority_DECISION_AUTHORITY_APPROVER_CONNECTION
		decision.Statement = encoded(statement)
		decision.Signature = nil
		decision.PhoneDecision = nil
		decision.ApproverKeyId = p.key.KeyId
	}
	return decision
}

func (p *proof) phoneRequest(leaseID string) []byte {
	for {
		raw := p.nextRequest()
		record := new(pb.RequestRecord)
		must(proto.Unmarshal(raw, record))
		if record.LeaseId == leaseID {
			return raw
		}
	}
}

func (p *proof) phoneProof(binary, legacyBinary string) {
	require(binary != "", "--phone-binary required")
	p.start()
	defer p.stop()
	p.pair()
	defer func() { p.work.Close() }()
	p.enrol()
	initialKeys := p.keys
	directory := filepath.Join(p.directory, "phone")
	must(os.MkdirAll(directory, 0700))
	certificate := identity(directory)
	tlsKey := certificate.PrivateKey.(*ecdsa.PrivateKey)
	must(os.WriteFile(filepath.Join(directory, "tls-cert.der"), certificate.Certificate[0], 0600))
	must(os.WriteFile(filepath.Join(directory, "tls-private.x963"), append(public(tlsKey), tlsKey.D.FillBytes(make([]byte, 32))...), 0600))
	phoneSigner := signingKey()
	must(os.WriteFile(filepath.Join(directory, "signing.raw"), phoneSigner.D.FillBytes(make([]byte, 32)), 0600))
	network := &phoneNetwork{target: p.address, address: "127.0.0.1:0"}
	network.up()
	defer network.down()
	_, port, err := net.SplitHostPort(network.address)
	must(err)
	startingBinary := binary
	if legacyBinary != "" {
		startingBinary = legacyBinary
	}
	phone := startPhone(startingBinary, directory)
	require(strings.HasPrefix(phone.command("probe-non-tailnet\t"+port), "REFUSED"), "phone accepted a resolved non-tailnet peer")
	fmt.Println("PASS resolved non-tailnet peer refused before a request")
	comparison := phone.command("pair\t" + port)
	var pair *pb.PairApproverRequest
	for pair == nil {
		pair = good(receive(p.work)).GetWork().GetPairing()
	}
	require(pair.Key.Role == pb.ApproverRole_APPROVER_ROLE_PHONE, "phone paired with the wrong authority")
	if legacyBinary != "" {
		require(len(pair.Key.EncryptionPublicKey) == 0, "legacy fixture did not start with an approval-only identity")
	}
	transcript := relaycrypto.PairTranscript(p.approver.pin, pair.TlsPublicKey, pair.Key.PublicKey, p.keys.KeySet, pair.Key.EncryptionPublicKey)
	require(comparison == "PAIR\t"+relaycrypto.Fingerprint(transcript), "Swift and Go pairing comparisons differ")
	deliverySigner := signingKey()
	deliveryKey := &pb.ApproverKey{KeyId: hex.EncodeToString(relaycrypto.Hash(public(deliverySigner))), PublicKey: public(deliverySigner), Label: "Fixture Mac delivery", Role: pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY}
	nextBytes := encoded(&pb.ApproverKeySet{Domain: "agentkeyring.approvers.v1", Revision: 2, Keys: []*pb.ApproverKey{p.key, pair.Key, deliveryKey},
		RuleOwnerKeyId: p.key.KeyId, ConfigurationRevision: p.configuration.Revision, ConfigurationSha256: relaycrypto.Hash(p.signedConfiguration.Configuration), PairingTranscriptSha256: relaycrypto.Hash(transcript)})
	next := &pb.SignedApproverKeySet{KeySet: nextBytes, Signature: sign(p.signer, nextBytes), SignerKeyId: p.key.KeyId}
	phone.stop()
	require(good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: next}})).GetPublish().Accepted, "phone addition refused")
	p.keys = next
	phone = startPhone(startingBinary, directory)
	phone.wait("status", "paired")
	if legacyBinary != "" {
		phone.stop()
		phone = startPhone(binary, directory)
		phone.wait("status", "paired")
	}
	_, err = os.Stat(filepath.Join(directory, "vault"))
	require(os.IsNotExist(err), "fixture created a phone vault")
	fmt.Println("PASS PHONE role pairing, exact transcript, saved comparison recovery and bound configuration, with no phone vault")

	escalate := func(record []byte, local *pb.Lease) {
		r := new(pb.RequestRecord)
		must(proto.Unmarshal(record, r))
		ack := good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_EscalateToPhone{EscalateToPhone: &pb.PhoneEscalation{LeaseId: r.LeaseId, Record: record, LocalLease: local}}})).GetPublish()
		require(ack.Accepted, "escalation refused")
	}
	leaseCommand := leaseRequest("phone-1", "phone-task-1", p.enrolled.RecipientId)
	lease := good(p.client.call(leaseCommand)).GetClient().GetLease()
	p.keys = initialKeys
	receiver := p.receiverClient(lease, leaseCommand.GetClient().GetRequestLease())
	p.keys = next
	record := p.phoneRequest(lease.LeaseId)
	id := hex.EncodeToString(relaycrypto.Digest("agentkeyring.request.v1", record))
	require(!strings.Contains(phone.command("requests"), id), "un-escalated request reached the phone")
	escalate(record, nil)
	phone.wait("requests", id+"=waitingForYou")
	phone.stop()
	phone = startPhone(binary, directory)
	phone.wait("requests", id+"=waitingForYou")
	fmt.Println("PASS only escalated requests arrive; pending request fetched on reopen without an import")

	hold := filepath.Join(directory, "hold-authorization")
	must(os.WriteFile(hold, []byte("hold"), 0600))
	phone.send("approve\t" + id)
	countPath := filepath.Join(directory, "authorization-count")
	deadline := time.Now().Add(20 * time.Second)
	for {
		count, _ := os.ReadFile(countPath)
		if string(count) == "1" {
			break
		}
		require(time.Now().Before(deadline), "phone did not authorize")
		time.Sleep(50 * time.Millisecond)
	}
	network.Lock()
	network.loseReply = true
	network.Unlock()
	must(os.Rename(hold, hold+".released"))
	answer := p.receivePhoneAnswer()
	must(relaycrypto.Verify(pair.Key.PublicKey, answer.Decision, answer.Signature))
	require(good(p.client.call(clientRequest(&pb.WireRequest{Request: &pb.WireRequest_GetLease{GetLease: &pb.LeaseReference{LeaseId: lease.LeaseId}}}))).GetClient().GetLease().State == pb.LeaseState_LEASE_STATE_PENDING, "relay acknowledgement prematurely approved the lease")
	// The Mac has received the exact signed answer, but deliberately does not
	// deliver yet. Cut the reply, then restart both processes before retrying.
	for {
		network.Lock()
		dropped := network.dropped
		network.Unlock()
		if dropped > 0 {
			break
		}
		require(time.Now().Before(deadline), "proxy dropped no replies")
		time.Sleep(10 * time.Millisecond)
	}
	network.down()
	require(strings.Contains(phone.line(), "sendingAnswer"), "phone received the acknowledgement")
	phone.stop()
	p.work.Close()
	p.stop()
	p.start()
	p.work = p.approver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: p.key.KeyId}}})
	replayed := p.receivePhoneAnswer()
	require(proto.Equal(answer, replayed), "relay did not replay the exact phone decision")
	network.Lock()
	network.loseReply = false
	network.Unlock()
	network.up()
	phone = startPhone(binary, directory)
	defer func() { phone.stop() }()
	phone.wait("requests", id+"=waitingForMac")
	count, err := os.ReadFile(countPath)
	must(err)
	require(string(count) == "1", "recovery asked for authorization twice")
	fmt.Println("PASS lost acknowledgement, phone and relay restart, exact answer retry, one authorization, waiting for Mac")
	decision := p.deliverPhone(record, answer, deliverySigner)
	require(good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_Decide{Decide: decision}})).GetDecision().Accepted, "Mac delivery refused")
	phone.wait("requests", id+"=approved")
	begin := good(p.client.call(deliverRequest(lease.LeaseId, "phone-operation"))).GetClient().GetDelivery()
	require(begin.GetSealed() != nil && proto.Equal(begin.GetSealed().Decision.PhoneDecision, answer), "delivery lost the phone signature")
	values, _, err := receiver.OpenValues(context.Background(), lease, begin)
	must(err)
	require(values.Password == "fixture-password-for-relay-system-proof", "Mac delivered the wrong login")
	values.Password = ""
	fmt.Println("PASS real Go receiver advanced the pinned key set, verified Swift phone consent and opened the Mac's dummy login")

	require(strings.Contains(phone.command("end\t"+id), "ended"), "phone remote revocation failed")
	require(p.client.call(deliverRequest(lease.LeaseId, "after-phone-revoke")).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "revoked lease delivered")

	for index, reply := range []string{"", "Use the test account instead"} {
		l := good(p.client.call(leaseRequest("deny-"+strconv.Itoa(index), "deny-task-"+strconv.Itoa(index), p.enrolled.RecipientId))).GetClient().GetLease()
		raw := p.phoneRequest(l.LeaseId)
		digest := hex.EncodeToString(relaycrypto.Digest("agentkeyring.request.v1", raw))
		escalate(raw, nil)
		phone.wait("requests", digest+"=waitingForYou")
		require(strings.Contains(phone.command("deny\t"+digest+"\t"+reply), "denied"), "remote denial did not commit directly")
		phone.wait("requests", digest+"=denied")
		result := good(p.client.call(clientRequest(&pb.WireRequest{Request: &pb.WireRequest_GetLease{GetLease: &pb.LeaseReference{LeaseId: l.LeaseId}}}))).GetClient().GetLease()
		require(result.State == pb.LeaseState_LEASE_STATE_DENIED && result.Reply == reply && result.ApprovedBy == pb.ApprovedBy_APPROVED_BY_IPHONE, "receiver lost the denial reply or phone attribution")
		require(strings.HasPrefix(phone.command("clear\t"+digest), "CLEARED"), "phone could not clear denial")
	}
	count, err = os.ReadFile(countPath)
	must(err)
	require(string(count) == "2", "plain denial prompted or signed reply did not")
	fmt.Println("PASS remote plain denial and signed reply commit directly without a copy or Mac delivery; scoped clear")

	// A local Mac recipient has never enrolled as a remote receiver.
	now := time.Now().Unix()
	localRecord := &pb.RequestRecord{LeaseId: "local-fixture-lease", RequestId: "local-fixture-request", LoginId: "fixture-login", RecipientId: "local-Mac-only",
		TaskRef: "local-fixture-task", Purpose: pb.Purpose_PURPOSE_BROWSER_SIGN_IN, Reason: "Local system proof", AgentLabel: "Fixture agent", CreatedUnixSeconds: now, PendingUntilUnixSeconds: now + 600}
	local := &pb.Lease{LeaseId: localRecord.LeaseId, LoginId: localRecord.LoginId, Recipient: &pb.Recipient{RecipientId: localRecord.RecipientId}, TaskRef: localRecord.TaskRef,
		Purpose: localRecord.Purpose, Reason: localRecord.Reason, Sites: []string{"https://example.com"}, State: pb.LeaseState_LEASE_STATE_PENDING, RequestedAtUnixSeconds: now, PendingUntilUnixSeconds: now + 600}
	localBytes := encoded(localRecord)
	localDigest := relaycrypto.Digest("agentkeyring.request.v1", localBytes)
	localID := hex.EncodeToString(localDigest)
	escalate(localBytes, local)
	phone.wait("requests", localID+"=waitingForYou")
	require(strings.Contains(phone.command("approve\t"+localID), "waitingForMac"), "local approval did not wait for Mac")
	localAnswer := p.receivePhoneAnswer()
	localDecision := new(pb.PhoneDecision)
	must(proto.Unmarshal(localAnswer.Decision, localDecision))
	local.State = pb.LeaseState_LEASE_STATE_ACTIVE
	local.ApprovedBy = pb.ApprovedBy_APPROVED_BY_IPHONE
	local.ApprovedAtUnixSeconds = localDecision.DecidedUnixSeconds
	local.NotAfterUnixSeconds = localDecision.NotAfterUnixSeconds
	updateLocal := func() {
		require(good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_UpdateLocalPhoneLease{UpdateLocalPhoneLease: &pb.LocalPhoneLeaseUpdate{RequestDigest: localDigest, Lease: local}}})).GetDecision().Accepted, "local state report refused")
	}
	updateLocal()
	phone.wait("requests", localID+"=approved")
	require(strings.Contains(phone.command("end\t"+localID), "approved"), "phone claimed local access ended before the Mac confirmed")
	for {
		work := good(receive(p.work)).GetWork()
		if work.GetLocalLeaseAction().GetRevokeLease().GetLeaseId() == local.LeaseId {
			break
		}
	}
	local.State = pb.LeaseState_LEASE_STATE_REVOKED
	local.EndedAtUnixSeconds = time.Now().Unix()
	updateLocal()
	phone.wait("requests", localID+"=ended")
	count, err = os.ReadFile(countPath)
	must(err)
	require(string(count) == "3", "local action prompted more than once")
	_, err = os.Stat(filepath.Join(directory, "vault"))
	require(os.IsNotExist(err), "phone used a vault")
	fmt.Println("PASS local request without receiver enrolment, actual Mac outcome, End waits for Mac confirmation; no phone vault")
	// Advance the configuration, then simulate a relay restored from stale or
	// altered state. The real relay serves it; the production Swift phone must
	// preserve its highest valid revision and refuse before authentication.
	nextConfiguration := proto.Clone(p.configuration).(*pb.Configuration)
	nextConfiguration.Revision++
	nextConfigurationBytes := encoded(nextConfiguration)
	latestConfiguration := &pb.SignedConfiguration{Configuration: nextConfigurationBytes, Signature: sign(p.signer, nextConfigurationBytes), ApproverKeyId: p.key.KeyId}
	require(good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishConfiguration{PublishConfiguration: &pb.ConfigurationPublication{Configuration: latestConfiguration}}})).GetPublish().Accepted, "configuration advance refused")
	configurationLease := good(p.client.call(leaseRequest("configuration-check", "configuration-task", p.enrolled.RecipientId))).GetClient().GetLease()
	configurationRecord := p.phoneRequest(configurationLease.LeaseId)
	configurationRequestID := hex.EncodeToString(relaycrypto.Digest("agentkeyring.request.v1", configurationRecord))
	escalate(configurationRecord, nil)
	phone.wait("requests", configurationRequestID+"=waitingForYou")
	altered := proto.Clone(nextConfiguration).(*pb.Configuration)
	altered.Logins[0].Title = "Changed at the same revision"
	alteredBytes := encoded(altered)
	cases := []*pb.SignedConfiguration{
		p.signedConfiguration,
		{Configuration: alteredBytes, Signature: sign(p.signer, alteredBytes), ApproverKeyId: p.key.KeyId},
		{Configuration: nextConfigurationBytes, Signature: sign(phoneSigner, nextConfigurationBytes), ApproverKeyId: pair.Key.KeyId},
		{Configuration: nextConfigurationBytes, Signature: sign(phoneSigner, nextConfigurationBytes), ApproverKeyId: p.key.KeyId},
	}
	for index, candidate := range cases {
		phone.stop()
		p.work.Close()
		p.stop()
		replacePhoneProofConfiguration(p.directory, candidate)
		p.start()
		p.work = p.approver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: p.key.KeyId}}})
		phone = startPhone(binary, directory)
		failure := phone.command("approve\t" + configurationRequestID)
		expected := "The configuration rolled back or changed at the same revision."
		if index == 2 {
			expected = "Only the rule owner may sign the configuration."
		}
		if index == 3 {
			expected = "The signed record does not match the trusted approvers."
		}
		require(strings.Contains(failure, expected), "phone failed for the wrong reason: "+failure)
		count, err := os.ReadFile(countPath)
		must(err)
		require(string(count) == "3", "invalid configuration reached authentication")
	}
	phone.stop()
	p.work.Close()
	p.stop()
	replacePhoneProofConfiguration(p.directory, latestConfiguration)
	p.start()
	p.work = p.approver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: p.key.KeyId}}})
	phone = startPhone(binary, directory)
	require(strings.Contains(phone.command("deny\t"+configurationRequestID+"\t"), "denied"), "phone did not recover with the highest valid configuration")
	phone.wait("requests", configurationRequestID+"=denied")
	fmt.Println("PASS Swift phone retains highest configuration across restart; downgrade, same-revision replacement, PHONE signer and invalid owner signature refused before authorization; valid configuration recovers")
	phone.command("clear\t" + configurationRequestID)
	p.configuration = nextConfiguration
	p.signedConfiguration = latestConfiguration
	if legacyBinary != "" {
		phone, pair.Key = p.swiftReplacementProof(phone, pair.Key, phoneSigner, directory, port, network)
	}
	phone = p.swiftCopyProof(phone, pair.Key, deliverySigner, network, directory)
	fmt.Println("Phone fixture state:", p.directory)
}

// The relay is stopped. Replace only this fixture's configuration, preserving
// the TLS identity, key chain and requests so the phone encounters stale data.
func replacePhoneProofConfiguration(directory string, configuration *pb.SignedConfiguration) {
	db, err := sql.Open("sqlite", filepath.Join(directory, "relay", "relay.sqlite"))
	must(err)
	defer db.Close()
	result, err := db.Exec("UPDATE objects SET value=? WHERE kind='current' AND id='configuration'", encoded(configuration))
	must(err)
	count, err := result.RowsAffected()
	must(err)
	require(count == 1, "fixture configuration missing")
}
