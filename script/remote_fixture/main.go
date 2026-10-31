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
	site string
	sync.Mutex
	directory, sealer       string
	tlsSPKI                 []byte
	signer, next, automatic *ecdsa.PrivateKey
	sets                    []*pb.SignedApproverKeySet
	peers                   map[string]*pb.EnrolmentRecord
	requests                map[string][]byte
	leases                  map[string]*pb.Lease
	operations              map[string]*pb.OperationRecord
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
	return &pb.ApproverKey{KeyId: id, PublicKey: elliptic.Marshal(elliptic.P256(), key.X, key.Y)}
}
func (f *fixture) mode() string {
	data, _ := os.ReadFile(filepath.Join(f.directory, "mode"))
	return strings.TrimSpace(string(data))
}
func (f *fixture) currentSet() *pb.SignedApproverKeySet {
	if f.mode() == "rotated" || f.mode() == "bad-chain" {
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
func (f *fixture) grant() *pb.SignedAutomaticGrant {
	grant := &pb.AutomaticGrant{Domain: "agentkeyring.automatic.v1", Revision: 1, AutomaticSigningPublicKey: keyInfo("automatic", f.automatic).PublicKey, AutomaticKeyId: "automatic", LoginIds: []string{"dummy"}}
	for _, peer := range f.peers {
		grant.RecipientIds = append(grant.RecipientIds, peer.RecipientId)
	}
	data := encoded(grant)
	return &pb.SignedAutomaticGrant{Grant: data, Signature: f.sign(f.signer, data), ApproverKeyId: "approver"}
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
	if mode == "automatic" {
		key = f.automatic
		keyID = "automatic"
		statement.Authority = pb.DecisionAuthority_DECISION_AUTHORITY_AUTOMATIC_RULE
		statement.AutomaticGrantRevision = 1
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
		statement := encoded(&pb.EnrolmentStatement{Domain: "agentkeyring.enrolment.v1", EnrolmentDigest: relaycrypto.Digest("agentkeyring.enrolment.v1", encoded(record)), Choice: pb.EnrolmentChoice_ENROLMENT_CHOICE_APPROVE, AutomaticAllowed: true, DecidedUnixSeconds: time.Now().Unix()})
		f.peers[record.RecipientId] = record
		status := &pb.EnrolStatus{State: pb.EnrolState_ENROL_STATE_APPROVED, ApproverKeySet: f.sets[0], RecipientId: record.RecipientId, EnrolmentRecord: encoded(record), Decision: &pb.SignedEnrolmentDecision{Statement: statement, Signature: f.sign(f.signer, statement), ApproverKeyId: "approver"}}
		if f.mode() == "unsigned-enrol" {
			status.Decision = nil
		}
		f.write(conn, &pb.RelayWireResponse{Response: &pb.RelayWireResponse_EnrolStatus{EnrolStatus: status}})
	case request.GetGetApproverKeyChain() != nil:
		chain := &pb.ApproverKeyChain{}
		if request.GetGetApproverKeyChain().FromRevision == 1 && f.currentSet() == f.sets[1] {
			signed := proto.Clone(f.sets[1]).(*pb.SignedApproverKeySet)
			if f.mode() == "bad-chain" {
				signed.Signature[0] ^= 1
			}
			chain.KeySets = append(chain.KeySets, signed)
		}
		f.write(conn, &pb.RelayWireResponse{Response: &pb.RelayWireResponse_ApproverKeyChain{ApproverKeyChain: chain}})
	case request.GetGetAutomaticGrant() != nil:
		f.write(conn, &pb.RelayWireResponse{Response: &pb.RelayWireResponse_AutomaticGrant{AutomaticGrant: f.grant()}})
	case request.GetGetIndex() != nil:
		index := encoded(&pb.LoginIndex{Revision: 1, Logins: []*pb.Login{{LoginId: "dummy", Title: "Dummy login", Sites: []string{f.site}, Account: "dummy@example.com", Rule: pb.AccessRule_ACCESS_RULE_ASK, HasOneTimeCode: true}}})
		f.write(conn, &pb.RelayWireResponse{Response: &pb.RelayWireResponse_Index{Index: &pb.SignedIndex{Index: index, ApproverKeyId: "approver", Signature: f.sign(f.signer, index)}}})
	case request.GetClient() != nil:
		r := request.GetClient()
		var response *pb.WireResponse
		switch {
		case r.GetRequestLease() != nil:
			req := r.GetRequestLease()
			leaseID := req.RequestId
			if f.leases[leaseID] == nil {
				record := &pb.RequestRecord{LeaseId: leaseID, RequestId: req.RequestId, LoginId: req.LoginId, TaskRef: req.TaskRef, Reason: req.Reason, Purpose: req.Purpose, Program: req.Program, RecipientId: req.RecipientId, Automatic: f.mode() == "automatic"}
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
		case r.GetBeginOperation() != nil:
			begin := r.GetBeginOperation()
			key := begin.LeaseId + ":" + begin.RequestId
			if previous := f.operations[key]; previous != nil {
				response = &pb.WireResponse{Response: &pb.WireResponse_BeginOperation{BeginOperation: &pb.BeginOperationResponse{Result: &pb.BeginOperationResponse_AlreadyStarted{AlreadyStarted: previous}}}}
			} else {
				record := new(pb.RequestRecord)
				must(proto.Unmarshal(f.requests[begin.LeaseId], record))
				operation := &pb.OperationRecord{OperationId: key}
				f.operations[key] = operation
				response = &pb.WireResponse{Response: &pb.WireResponse_BeginOperation{BeginOperation: &pb.BeginOperationResponse{OperationId: key, Result: &pb.BeginOperationResponse_Sealed{Sealed: f.seal(record)}}}}
			}
		case r.GetFinishOperation() != nil:
			finish := r.GetFinishOperation()
			record := f.operations[finish.OperationId]
			if finish.GetFill() != 0 {
				record.Outcome = &pb.OperationRecord_Fill{Fill: finish.GetFill()}
			}
			if finish.GetProgram() != 0 {
				record.Outcome = &pb.OperationRecord_Program{Program: finish.GetProgram()}
				record.ExitCode = finish.ExitCode
			}
			if finish.GetReadDelivered() {
				record.Outcome = &pb.OperationRecord_ReadDelivered{ReadDelivered: true}
			}
			response = &pb.WireResponse{Response: &pb.WireResponse_Operation{Operation: record}}
		case r.GetGetOperation() != nil:
			lookup := r.GetGetOperation()
			record := f.operations[lookup.LeaseId+":"+lookup.RequestId]
			response = &pb.WireResponse{Response: &pb.WireResponse_GetOperation_{GetOperation_: &pb.GetOperationResponse{Operation: record}}}
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
	f := &fixture{directory: *directory, sealer: *sealer, site: *site, signer: signer, next: next, automatic: automatic, peers: map[string]*pb.EnrolmentRecord{}, requests: map[string][]byte{}, leases: map[string]*pb.Lease{}, operations: map[string]*pb.OperationRecord{}}
	for i, key := range []*ecdsa.PrivateKey{signer, next} {
		id := "approver"
		if i == 1 {
			id = "next"
		}
		set := encoded(&pb.ApproverKeySet{Domain: "agentkeyring.approvers.v1", Revision: uint64(i + 1), Keys: []*pb.ApproverKey{keyInfo(id, key)}, RuleOwnerKeyId: id})
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
