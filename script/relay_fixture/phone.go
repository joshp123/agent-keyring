// Written by AI on 2026.10.31 by model gpt-6.1-sol.
// Full phone core against the real relay. Keys, biometric authorization and
// Passwords input here are explicitly dummy substitutes, never device proof.
package main

import (
	"bufio"
	"bytes"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/hpke"
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
// The receiver independently observes the committed ACTIVE lease before the
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

func (p *proof) phoneProof(binary string) {
	require(binary != "", "--phone-binary required")
	p.start()
	defer p.stop()
	p.pair()
	defer p.work.Close()
	p.enrol()
	machine := &pb.EnrolledMachine{RecipientId: p.enrolled.RecipientId, MachineLabel: p.enrolled.MachineLabel,
		ClientLabel: p.enrolled.ClientLabel, TailscaleNodeId: p.enrolled.TailscaleNodeId, TlsPublicKey: p.enrolled.TlsPublicKey,
		ReceiverPublicKey: p.enrolled.ReceiverPublicKey, ReceiverKeyId: p.enrolled.ReceiverKeyId}
	rosterBytes := encoded(&pb.EnrolmentSet{Domain: "agentkeyring.enrolments.v1", Revision: 1, Machines: []*pb.EnrolledMachine{machine}})
	roster := &pb.SignedEnrolmentSet{EnrolmentSet: rosterBytes, Signature: sign(p.signer, rosterBytes), ApproverKeyId: p.key.KeyId}
	require(good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishEnrolmentSet{PublishEnrolmentSet: roster}})).GetPublish().Accepted, "roster refused")
	directory := filepath.Join(p.directory, "phone")
	must(os.MkdirAll(directory, 0700))
	certificate := identity(directory)
	tlsKey := certificate.PrivateKey.(*ecdsa.PrivateKey)
	must(os.WriteFile(filepath.Join(directory, "tls-cert.der"), certificate.Certificate[0], 0600))
	must(os.WriteFile(filepath.Join(directory, "tls-private.x963"), append(public(tlsKey), tlsKey.D.FillBytes(make([]byte, 32))...), 0600))
	phoneSigner, agreement := signingKey(), signingKey()
	must(os.WriteFile(filepath.Join(directory, "signing.raw"), phoneSigner.D.FillBytes(make([]byte, 32)), 0600))
	must(os.WriteFile(filepath.Join(directory, "agreement.raw"), agreement.D.FillBytes(make([]byte, 32)), 0600))
	network := &phoneNetwork{target: p.address, address: "127.0.0.1:0"}
	network.up()
	defer network.down()
	_, port, err := net.SplitHostPort(network.address)
	must(err)
	phone := startPhone(binary, directory)
	comparison := phone.command("pair\t" + port)
	var pair *pb.PairApproverRequest
	for pair == nil {
		pair = good(receive(p.work)).GetWork().GetPairing()
	}
	transcript := relaycrypto.PairTranscript(p.approver.pin, pair.TlsPublicKey, pair.Key.PublicKey, p.keys.KeySet)
	require(comparison == "PAIR\t"+relaycrypto.Fingerprint(transcript), "Swift and Go pairing comparisons differ")
	nextBytes := encoded(&pb.ApproverKeySet{Domain: "agentkeyring.approvers.v1", Revision: 2, Keys: []*pb.ApproverKey{p.key, pair.Key},
		RuleOwnerKeyId: p.key.KeyId, EnrolmentSetRevision: 1, EnrolmentSetSha256: relaycrypto.Hash(rosterBytes), PairingTranscriptSha256: relaycrypto.Hash(transcript)})
	next := &pb.SignedApproverKeySet{KeySet: nextBytes, Signature: sign(p.signer, nextBytes), SignerKeyId: p.key.KeyId}
	// Close before the Mac signs: the next open must verify its saved comparison,
	// rather than trust the relay's already-approved flag.
	phone.stop()
	require(good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: next}})).GetPublish().Accepted, "phone addition refused")
	phone = startPhone(binary, directory)
	phone.wait("status", "paired")
	fmt.Println("PASS phone compared the exact transcript, verified the Mac-signed addition and adopted the existing receiver")

	lease := good(p.client.call(leaseRequest("phone-1", "phone-task-1", p.enrolled.RecipientId))).GetClient().GetLease()
	record := p.nextRequest()
	id := hex.EncodeToString(relaycrypto.Digest("agentkeyring.request.v1", record))
	phone.wait("requests", id+"=waitingForYou")
	// Stop and reopen while the request is pending: WatchWork must replay it.
	phone.stop()
	phone = startPhone(binary, directory)
	phone.wait("requests", id+"=waitingForYou")
	fmt.Println("PASS pending request survived phone process restart and backlog replay")
	hold := filepath.Join(directory, "hold-authorization")
	must(os.WriteFile(hold, []byte("hold"), 0600))
	phone.send("approve\t" + id)
	countPath := filepath.Join(directory, "authorization-count")
	deadline := time.Now().Add(20 * time.Second)
	for {
		if count, _ := os.ReadFile(countPath); string(count) == "1" {
			break
		}
		require(time.Now().Before(deadline), "phone did not authorize")
		time.Sleep(50 * time.Millisecond)
	}
	network.Lock()
	network.loseReply = true
	network.Unlock()
	// Fixture control file only; no user file or production data is removed.
	must(os.Rename(hold, hold+".released"))
	for {
		current := good(p.client.call(clientRequest(&pb.WireRequest{Request: &pb.WireRequest_GetLease{GetLease: &pb.LeaseReference{LeaseId: lease.LeaseId}}}))).GetClient().GetLease()
		if current.State == pb.LeaseState_LEASE_STATE_ACTIVE {
			break
		}
		require(time.Now().Before(deadline), "phone answer never committed at relay")
		time.Sleep(50 * time.Millisecond)
	}
	network.down()
	require(strings.Contains(phone.line(), "sendingAnswer"), "phone received an acknowledgement during the lost-ack proof")
	network.Lock()
	dropped := network.dropped
	network.Unlock()
	require(dropped > 0, "proxy dropped no encrypted replies")
	phone.stop()
	p.work.Close()
	p.stop()
	p.start()
	network.Lock()
	network.loseReply = false
	network.Unlock()
	network.up()
	phone = startPhone(binary, directory)
	defer phone.stop()
	phone.wait("requests", id+"=approved")
	count, err := os.ReadFile(countPath)
	must(err)
	require(string(count) == "1", "recovery asked for authorization twice")
	fmt.Println("PASS lost acknowledgement after relay commit, relay and phone restart, same queued answer delivered with one authorization")
	delivery := good(p.client.call(beginRequest(lease.LeaseId, "phone-operation"))).GetClient().GetBeginOperation().GetSealed()
	require(delivery != nil, "approved phone lease did not deliver")
	statement := new(pb.DecisionStatement)
	must(proto.Unmarshal(delivery.Decision.Statement, statement))
	must(relaycrypto.Verify(pair.Key.PublicKey, delivery.Decision.Statement, delivery.Decision.Signature))
	require(bytes.Equal(statement.RequestDigest, relaycrypto.Digest("agentkeyring.request.v1", record)), "signed request digest differs")
	receiver, err := ecdh.P256().NewPrivateKey(p.receiver.D.FillBytes(make([]byte, 32)))
	must(err)
	private, err := hpke.NewDHKEMPrivateKey(receiver)
	must(err)
	opener, err := hpke.NewRecipient(delivery.Bundle.EncapsulatedKey, private, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte("agentkeyring.bundle.v1"))
	must(err)
	cleartext, err := opener.Open(statement.RequestDigest, delivery.Bundle.Ciphertext)
	must(err)
	contents := new(pb.BundleContents)
	must(proto.Unmarshal(cleartext, contents))
	clear(cleartext)
	require(contents.LoginId == "fixture-login" && contents.LeaseId == lease.LeaseId && contents.Password == "phone-fixture-password" && contents.Username == "fixture" && len(contents.OneTimeCodes) >= 60, "phone bundle contents or authoritative IDs differ")
	fmt.Println("PASS Go receiver verified the phone signature and opened CryptoKit HPKE username, password and timed codes")
	require(strings.Contains(phone.command("end\t"+id), "ended"), "phone early revocation failed")
	require(p.client.call(beginRequest(lease.LeaseId, "after-phone-revoke")).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "phone-revoked lease delivered again")
	require(strings.Contains(phone.command("end\t"+id), "ended"), "phone repeated revocation failed")
	fmt.Println("PASS phone End Access confirmed by relay; repeated revoke is harmless and receiver can no longer deliver")
	// A new task must still require its own answer. Plain denial is unsigned;
	// a reply must be signed and ask the software biometric stand-in once.
	p.work = p.approver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: p.key.KeyId}}})
	for _, reply := range []string{"", "Use the test account instead"} {
		index := strconv.Itoa(len(reply))
		l := good(p.client.call(leaseRequest("deny-"+index, "deny-task-"+index, p.enrolled.RecipientId))).GetClient().GetLease()
		raw := p.nextRequest()
		digest := hex.EncodeToString(relaycrypto.Digest("agentkeyring.request.v1", raw))
		phone.wait("requests", digest+"=waitingForYou")
		require(strings.Contains(phone.command("deny\t"+digest+"\t"+reply), "denied"), "phone denial failed")
		result := good(p.client.call(clientRequest(&pb.WireRequest{Request: &pb.WireRequest_GetLease{GetLease: &pb.LeaseReference{LeaseId: l.LeaseId}}}))).GetClient().GetLease()
		require(result.State == pb.LeaseState_LEASE_STATE_DENIED && result.Reply == reply, "receiver did not get denial")
		if reply == "" {
			require(result.SignedDenial == nil, "plain denial was signed")
		} else {
			require(result.SignedDenial != nil, "reply denial lacks signature")
			must(relaycrypto.Verify(pair.Key.PublicKey, result.SignedDenial.Decision.Statement, result.SignedDenial.Decision.Signature))
		}
		require(strings.HasPrefix(phone.command("clear\t"+digest), "CLEARED"), "phone could not clear denial")
	}
	count, err = os.ReadFile(countPath)
	must(err)
	require(string(count) == "2", "plain denial asked for authorization or reply did not")
	fmt.Println("PASS plain Deny without authorization, signed reply with authorization, and scoped ClearDenial")
	fmt.Println("Phone fixture state:", p.directory)
}
