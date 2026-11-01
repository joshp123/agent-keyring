// Written by AI on 2026.10.31 by model gpt-6.1-sol.
// Dummy relay/approver for exercising the shipped CLI before the real relay is
// available. It deliberately has no production authorisation or persistence.
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
	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
)

func encoded(message proto.Message) []byte {
	data, err := proto.Marshal(message)
	must(err)
	return data
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}

type fixture struct {
	site                  string
	configurationRevision uint64
	lastConfiguration     []byte
	sync.Mutex
	directory, sealer       string
	tlsSPKI                 []byte
	signer, next, automatic *ecdsa.PrivateKey
	sets                    []*pb.SignedApproverKeySet
	peers                   map[string]*pb.EnrolmentRecord
	requests                map[string][]byte
	leases                  map[string]*pb.Lease
}

func (f *fixture) external(arguments ...string) error {
	command := exec.Command(f.sealer, arguments...)
	command.Stdout = nil
	command.Stderr = nil
	return command.Run()
}
func (f *fixture) sign(key *ecdsa.PrivateKey, statement []byte) []byte {
	if f.sealer == "" {
		signature, err := ecdsa.SignASN1(rand.Reader, key, relaycrypto.Hash(statement))
		must(err)
		return signature
	}
	directory, err := os.MkdirTemp(f.directory, "signature-")
	must(err)
	defer os.RemoveAll(directory)
	must(os.WriteFile(filepath.Join(directory, "private"), key.D.FillBytes(make([]byte, 32)), 0600))
	must(os.WriteFile(filepath.Join(directory, "statement"), statement, 0600))
	must(f.external("sign", filepath.Join(directory, "private"), filepath.Join(directory, "statement"), filepath.Join(directory, "signature")))
	signature, err := os.ReadFile(filepath.Join(directory, "signature"))
	must(err)
	return signature
}
func keyInfo(id string, key *ecdsa.PrivateKey) *pb.ApproverKey {
	return &pb.ApproverKey{Role: pb.ApproverRole_APPROVER_ROLE_MAC, KeyId: id, PublicKey: elliptic.Marshal(elliptic.P256(), key.X, key.Y)}
}
func (f *fixture) mode() string {
	data, _ := os.ReadFile(filepath.Join(f.directory, "mode"))
	return strings.TrimSpace(string(data))
}
func (f *fixture) currentSet() *pb.SignedApproverKeySet {
	if f.mode() == "rotated" || f.mode() == "bad-chain" || f.mode() == "phone-chain" || f.mode() == "delivery-chain" {
		return f.sets[1]
	}
	return f.sets[0]
}
func (f *fixture) write(conn net.Conn, message *pb.RelayWireResponse) {
	message.EndOfStream = true
	must(authority.WriteFrame(conn, message))
}
func clientReply(response *pb.WireResponse) *pb.RelayWireResponse {
	return &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Client{Client: response}}
}
func (f *fixture) configuration() *pb.SignedConfiguration {
	rule := pb.AccessRule_ACCESS_RULE_ASK
	if strings.HasPrefix(f.mode(), "automatic") {
		rule = pb.AccessRule_ACCESS_RULE_AUTOMATIC
	}
	config := &pb.Configuration{Domain: "agentkeyring.configuration.v1", Revision: 0, Logins: []*pb.Login{{LoginId: "dummy", Title: "Dummy login", Sites: []string{f.site}, Account: "dummy@example.com", Rule: rule, HasOneTimeCode: true}}, AutomaticKeyId: "automatic", AutomaticSigningPublicKey: keyInfo("automatic", f.automatic).PublicKey}
	for _, peer := range f.peers {
		config.Machines = append(config.Machines, &pb.EnrolledMachine{RecipientId: peer.RecipientId, MachineLabel: peer.MachineLabel, ClientLabel: peer.ClientLabel, TailscaleNodeId: peer.TailscaleNodeId, TlsPublicKey: peer.TlsPublicKey, ReceiverPublicKey: peer.ReceiverPublicKey, ReceiverKeyId: peer.ReceiverKeyId, AutomaticAllowed: true})
	}
	slices.SortFunc(config.Machines, func(a, b *pb.EnrolledMachine) int { return strings.Compare(a.RecipientId, b.RecipientId) })
	switch f.mode() {
	case "automatic-rule-withdrawn":
		config.Logins[0].Rule = pb.AccessRule_ACCESS_RULE_ASK
	case "automatic-permission-withdrawn":
		for _, machine := range config.Machines {
			machine.AutomaticAllowed = false
		}
	case "automatic-key-withdrawn":
		config.AutomaticKeyId = "retired"
		config.AutomaticSigningPublicKey = keyInfo("next", f.next).PublicKey
	case "automatic-newer-configuration":
		config.MirrorRefreshedUnixSeconds = 1
	}
	unsigned := encoded(config)
	if !bytes.Equal(unsigned, f.lastConfiguration) {
		f.configurationRevision++
		f.lastConfiguration = unsigned
	}
	if strings.HasPrefix(f.mode(), "automatic-") && f.configurationRevision < 2 {
		f.configurationRevision = 2
	}
	config.Revision = f.configurationRevision
	data := encoded(config)
	id, key := "approver", f.signer
	if f.mode() == "rotated" {
		id, key = "next", f.next
	}
	return &pb.SignedConfiguration{Configuration: data, Signature: f.sign(key, data), ApproverKeyId: id}
}
func (f *fixture) seal(record *pb.RequestRecord) *pb.SealedDelivery {
	mode := f.mode()
	approvedRecord := f.requests[record.LeaseId]
	if mode == "changed-task" {
		record.TaskRef = "another-task"
		approvedRecord = encoded(record)
	}
	now := time.Now().Unix()
	deadline := now + 1700
	if mode == "expired" {
		deadline = now - 1
		now -= 1800
	}
	statement := &pb.DecisionStatement{Domain: "agentkeyring.decision.v1", RequestDigest: relaycrypto.Digest("agentkeyring.request.v1", approvedRecord), Choice: pb.DecisionChoice_DECISION_CHOICE_APPROVE, ApprovedAtUnixSeconds: now, NotAfterUnixSeconds: deadline, RecipientId: record.RecipientId, LeaseId: record.LeaseId, ReplySha256: relaycrypto.Hash(nil), Authority: pb.DecisionAuthority_DECISION_AUTHORITY_HUMAN}
	peer := f.peers[record.RecipientId]
	statement.ReceiverKeyId = peer.ReceiverKeyId
	contents := &pb.BundleContents{LeaseId: record.LeaseId, LoginId: record.LoginId, Sites: []string{f.site}, Username: "dummy@example.com", Password: "keyring-r3-dummy-password", NotAfterUnixSeconds: deadline, OneTimeCodes: []*pb.TimedCode{{ValidFromUnixSeconds: now, ValidUntilUnixSeconds: deadline, Code: "583912"}}}
	if mode == "wrong-recipient" {
		statement.RecipientId = "another-machine"
	}
	if mode == "wrong-lease" {
		statement.LeaseId = "another-lease"
	}
	if mode == "wrong-site" {
		contents.Sites = []string{"https://outside.example"}
	}
	if mode == "bundle-login" {
		contents.LoginId = "another-login"
	}
	key := f.signer
	keyID := "approver"
	if mode == "rotated" {
		key = f.next
		keyID = "next"
	}
	if strings.HasPrefix(mode, "automatic") {
		key = f.automatic
		keyID = "automatic"
		statement.Authority = pb.DecisionAuthority_DECISION_AUTHORITY_AUTOMATIC_RULE
		statement.ConfigurationRevision = 1
	}
	if mode == "unknown-signer" {
		keyID = "untrusted"
	}
	sealed := &pb.SealedBundle{ReceiverKeyId: peer.ReceiverKeyId}
	if f.sealer != "" {
		directory, err := os.MkdirTemp(f.directory, "sealed-")
		must(err)
		defer os.RemoveAll(directory)
		paths := []string{}
		for _, name := range []string{"recipient", "plaintext", "aad", "enc", "ciphertext"} {
			paths = append(paths, filepath.Join(directory, name))
		}
		must(os.WriteFile(paths[0], peer.ReceiverPublicKey, 0600))
		must(os.WriteFile(paths[1], encoded(contents), 0600))
		must(os.WriteFile(paths[2], statement.RequestDigest, 0600))
		must(f.external(append([]string{"seal"}, paths...)...))
		sealed.EncapsulatedKey, err = os.ReadFile(paths[3])
		must(err)
		sealed.Ciphertext, err = os.ReadFile(paths[4])
		must(err)
	} else {
		public, err := ecdh.P256().NewPublicKey(peer.ReceiverPublicKey)
		must(err)
		pk, err := hpke.NewDHKEMPublicKey(public)
		must(err)
		enc, sender, err := hpke.NewSender(pk, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte("agentkeyring.bundle.v1"))
		must(err)
		sealed.EncapsulatedKey = enc
		sealed.Ciphertext, err = sender.Seal(statement.RequestDigest, encoded(contents))
		must(err)
	}
	statement.BundleCiphertextSha256 = relaycrypto.Hash(sealed.Ciphertext)
	signed := &pb.SignedDecision{Statement: encoded(statement), ApproverKeyId: keyID}
	signed.Signature = f.sign(key, signed.Statement)
	if mode == "tampered-ciphertext" {
		sealed.Ciphertext[0] ^= 1
	}
	if mode == "bad-enc" {
		sealed.EncapsulatedKey[3] ^= 1
	}
	return &pb.SealedDelivery{Decision: signed, Bundle: sealed, RequestRecord: approvedRecord}
}
func (f *fixture) serve(conn net.Conn) {
	defer conn.Close()
	request := new(pb.RelayWireRequest)
	if authority.ReadFrame(conn, request) != nil {
		return
	}
	f.Lock()
	defer f.Unlock()
	switch {
	case request.GetEnrol() != nil:
		req := request.GetEnrol()
		certificate := conn.(*tls.Conn).ConnectionState().PeerCertificates
		if len(certificate) != 1 || !bytes.Equal(certificate[0].RawSubjectPublicKeyInfo, req.TlsPublicKey) {
			return
		}
		id := hex.EncodeToString(relaycrypto.Hash(req.ReceiverPublicKey))
		record := &pb.EnrolmentRecord{RecipientId: id[:16], MachineLabel: req.MachineLabel, ClientLabel: req.ClientLabel, TlsPublicKey: req.TlsPublicKey, ReceiverPublicKey: req.ReceiverPublicKey, ReceiverKeyId: id, ApproverKeySetSha256: relaycrypto.Hash(f.sets[0].KeySet), CreatedUnixSeconds: time.Now().Unix()}
		fmt.Println("COMPARE", relaycrypto.Fingerprint(relaycrypto.EnrolTranscript(f.tlsSPKI, req.TlsPublicKey, req.ReceiverPublicKey, f.sets[0].KeySet)))
		pending := &pb.RelayWireResponse{Response: &pb.RelayWireResponse_EnrolStatus{EnrolStatus: &pb.EnrolStatus{State: pb.EnrolState_ENROL_STATE_PENDING, ApproverKeySet: f.sets[0]}}}
		must(authority.WriteFrame(conn, pending))
		f.peers[record.RecipientId] = record
		status := &pb.EnrolStatus{State: pb.EnrolState_ENROL_STATE_APPROVED, ApproverKeySet: f.sets[0], RecipientId: record.RecipientId, Configuration: f.configuration()}
		if f.mode() == "unsigned-enrol" {
			status.Configuration = nil
		}
		f.write(conn, &pb.RelayWireResponse{Response: &pb.RelayWireResponse_EnrolStatus{EnrolStatus: status}})
	case request.GetGetApproverKeyChain() != nil:
		chain := &pb.ApproverKeyChain{}
		if request.GetGetApproverKeyChain().FromRevision == 1 && f.currentSet() == f.sets[1] {
			signed := proto.Clone(f.sets[1]).(*pb.SignedApproverKeySet)
			if f.mode() == "bad-chain" {
				signed.Signature[0] ^= 1
			}
			if f.mode() == "phone-chain" {
				signed.SignerKeyId = "phone"
				signed.Signature = f.sign(f.next, signed.KeySet)
			}
			if f.mode() == "delivery-chain" {
				signed.SignerKeyId = "automatic"
				signed.Signature = f.sign(f.automatic, signed.KeySet)
			}
			chain.KeySets = append(chain.KeySets, signed)
		}
		f.write(conn, &pb.RelayWireResponse{Response: &pb.RelayWireResponse_ApproverKeyChain{ApproverKeyChain: chain}})
	case request.GetGetConfigurationUpdates() != nil:
		f.write(conn, &pb.RelayWireResponse{Response: &pb.RelayWireResponse_ConfigurationUpdates{ConfigurationUpdates: &pb.ConfigurationUpdates{Configurations: []*pb.SignedConfiguration{f.configuration()}}}})
	case request.GetPublishUpdateReceipt() != nil:
		receipt := new(pb.UpdateReceipt)
		signed := request.GetPublishUpdateReceipt()
		must(proto.Unmarshal(signed.Receipt, receipt))
		spki := conn.(*tls.Conn).ConnectionState().PeerCertificates[0].RawSubjectPublicKeyInfo
		must(relaycrypto.VerifyUpdateReceipt(spki, signed, &pb.UpdateReceiptQuery{Kind: receipt.Kind, Revision: receipt.Revision, UpdateSha256: receipt.UpdateSha256}))
		f.write(conn, &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Publish{Publish: &pb.PublishAck{Accepted: true}}})
	case request.GetGetConfiguration() != nil:
		f.write(conn, &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Configuration{Configuration: f.configuration()}})
	case request.GetClient() != nil:
		r := request.GetClient()
		var response *pb.WireResponse
		switch {
		case r.GetRequestLease() != nil:
			req := r.GetRequestLease()
			leaseID := req.RequestId
			if f.leases[leaseID] == nil {
				record := &pb.RequestRecord{LeaseId: leaseID, RequestId: req.RequestId, LoginId: req.LoginId, TaskRef: req.TaskRef, Reason: req.Reason, Purpose: req.Purpose, Program: req.Program, RecipientId: req.RecipientId, Automatic: strings.HasPrefix(f.mode(), "automatic")}
				f.requests[leaseID] = encoded(record)
				f.leases[leaseID] = &pb.Lease{LeaseId: leaseID, LoginId: req.LoginId, TaskRef: req.TaskRef, Reason: req.Reason, Purpose: req.Purpose, Program: req.Program, Recipient: &pb.Recipient{RecipientId: req.RecipientId}, State: pb.LeaseState_LEASE_STATE_ACTIVE, NotAfterUnixSeconds: time.Now().Unix() + 1700}
			}

			if strings.HasPrefix(f.mode(), "denial-") {
				lease := f.leases[leaseID]
				lease.State = pb.LeaseState_LEASE_STATE_DENIED
				lease.Reply = "Unsigned relay instruction"
				if f.mode() != "denial-unsigned" {
					peer := f.peers[req.RecipientId]
					statement := encoded(&pb.DecisionStatement{Domain: "agentkeyring.decision.v1", RequestDigest: relaycrypto.Digest("agentkeyring.request.v1", f.requests[leaseID]), Choice: pb.DecisionChoice_DECISION_CHOICE_DENY, Authority: pb.DecisionAuthority_DECISION_AUTHORITY_HUMAN, RecipientId: req.RecipientId, ReceiverKeyId: peer.ReceiverKeyId, LeaseId: leaseID, ReplySha256: relaycrypto.Hash([]byte("Use the dummy staging login instead."))})
					signed := &pb.SignedDecision{Statement: statement, Signature: f.sign(f.signer, statement), ApproverKeyId: "approver", Reply: "Use the dummy staging login instead."}
					lease.SignedDenial = &pb.SealedDelivery{Decision: signed, RequestRecord: f.requests[leaseID]}
					if f.mode() == "denial-tampered" {
						signed.Reply = "Tampered reply"
					}
					if f.mode() == "denial-bundle" {
						signed.Bundle = &pb.SealedBundle{Ciphertext: []byte("unexpected")}
					}
				}
			}

			response = &pb.WireResponse{Response: &pb.WireResponse_Lease{Lease: f.leases[leaseID]}}
		case r.GetGetLease() != nil:
			response = &pb.WireResponse{Response: &pb.WireResponse_Lease{Lease: f.leases[r.GetGetLease().LeaseId]}}
		case r.GetEndLease() != nil:
			lease := f.leases[r.GetEndLease().LeaseId]
			lease.State = pb.LeaseState_LEASE_STATE_RELEASED
			response = &pb.WireResponse{Response: &pb.WireResponse_Lease{Lease: lease}}
		case r.GetDeliver() != nil:
			record := new(pb.RequestRecord)
			must(proto.Unmarshal(f.requests[r.GetDeliver().LeaseId], record))
			response = &pb.WireResponse{Response: &pb.WireResponse_Delivery{Delivery: &pb.Delivery{Result: &pb.Delivery_Sealed{Sealed: f.seal(record)}}}}
		}
		if response == nil {
			panic(errors.New("unsupported fixture call"))
		}
		f.write(conn, clientReply(response))
	}
}
func main() {
	address := flag.String("listen", "127.0.0.1:0", "isolated fixture address")
	directory := flag.String("state", "", "private fixture directory")
	site := flag.String("site", "https://example.com", "saved dummy site")
	sealer := flag.String("cryptokit", "", "compiled seal_dummy_bundle.swift; omit for Go-only fixture")
	flag.Parse()
	if *directory == "" {
		panic("--state required")
	}
	must(os.MkdirAll(*directory, 0700))
	signer, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	must(err)
	next, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	must(err)
	automatic, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	must(err)
	f := &fixture{directory: *directory, sealer: *sealer, site: *site, signer: signer, next: next, automatic: automatic, peers: map[string]*pb.EnrolmentRecord{}, requests: map[string][]byte{}, leases: map[string]*pb.Lease{}}
	for i, key := range []*ecdsa.PrivateKey{signer, next} {
		id := "approver"
		if i == 1 {
			id = "next"
		}
		set := encoded(&pb.ApproverKeySet{Domain: "agentkeyring.approvers.v1", Revision: uint64(i + 1), Keys: []*pb.ApproverKey{keyInfo(id, key), {KeyId: "phone", PublicKey: keyInfo("phone", next).PublicKey, Role: pb.ApproverRole_APPROVER_ROLE_PHONE}, {KeyId: "automatic", PublicKey: keyInfo("automatic", automatic).PublicKey, Role: pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY}}, RuleOwnerKeyId: id})
		f.sets = append(f.sets, &pb.SignedApproverKeySet{KeySet: set, SignerKeyId: "approver", Signature: f.sign(signer, set)})
	}
	cert, key, err := relaycrypto.NewIdentity("dummy relay")
	must(err)
	identity, err := tls.X509KeyPair(cert, key)
	must(err)
	f.tlsSPKI, err = relaycrypto.CertificateSPKI(identity)
	must(err)
	listener, err := tls.Listen("tcp", *address, &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{identity}, ClientAuth: tls.RequireAnyClientCert})
	must(err)
	fmt.Println("LISTEN", listener.Addr())
	for {
		conn, err := listener.Accept()
		must(err)
		go f.serve(conn)
	}
}
