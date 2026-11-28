// Written by AI on 2026.11.18 by model claude opus 5.5.
// What the Swift apps sealed and signed (AgentKeyringSealingTests), opened here
// as the command opens it on the asking machine; and a push sealed here as the
// relay seals it, for the Swift test to open. AKR_WRITE_VECTORS=1 rewrites
// the Go side's file.
package keyring

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"google.golang.org/protobuf/proto"
)

const vectors = "../../testdata/keyring/"

func testKey(t *testing.T, name string) *ecdh.PrivateKey {
	t.Helper()
	raw, err := os.ReadFile(vectors + "keys.json")
	if err != nil {
		t.Fatal(err)
	}
	keys := map[string]string{}
	if err := json.Unmarshal(raw, &keys); err != nil {
		t.Fatal(err)
	}
	scalar, err := hex.DecodeString(keys[name])
	if err != nil {
		t.Fatal(err)
	}
	key, err := ecdh.P256().NewPrivateKey(scalar)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func readKeyringTestFixture[T proto.Message](t *testing.T, name string, message T) T {
	t.Helper()
	raw, err := os.ReadFile(vectors + name)
	if err != nil {
		t.Fatal(err)
	}
	if err := proto.Unmarshal(raw, message); err != nil {
		t.Fatal(err)
	}
	return message
}

func TestTheMachineOpensWhatADeviceApproved(t *testing.T) {
	members, err := VerifySignedMembers(readKeyringTestFixture(t, "swift-members.pb", &pb.Signed{}), nil)
	if err != nil {
		t.Fatal(err)
	}
	machine := testKey(t, "machine_receiving")
	approval := readKeyringTestFixture(t, "swift-approval.pb", &pb.Approval{})
	answer, _, err := VerifyRequestAnswer(approval, members)
	if err != nil {
		t.Fatal(err)
	}
	contents, err := OpenApprovedCredential(approval, members, machine, time.Unix(answer.DecidedUnixSeconds+1, 0))
	if err != nil {
		t.Fatal(err)
	}
	if contents.Password != "example-password" || len(contents.OneTimeCodes) != 61 || contents.OneTimeCodes[0].Code != "527227" {
		t.Fatalf("unexpected delivery: password ok %v, %d codes", contents.Password == "example-password", len(contents.OneTimeCodes))
	}
	if _, err := OpenApprovedCredential(approval, members, machine, time.Unix(answer.NotAfterUnixSeconds, 0)); !errors.Is(err, ErrExpired) {
		t.Fatalf("an approval past its 30 minutes must not open, got %v", err)
	}

	denial, _, err := VerifyRequestAnswer(readKeyringTestFixture(t, "swift-denial.pb", &pb.Approval{}), members)
	if err != nil || denial.Reply != "The invoice is in my email." {
		t.Fatalf("denial with words: %v", err)
	}

	automaticCopy := readKeyringTestFixture(t, "swift-automatic.pb", &pb.SealedLogin{})
	listed := &pb.Login{LoginId: "login-example", Version: 1_795_000_000_000_000_000}
	if err := VerifySealedLogin(automaticCopy, members, listed); err != nil {
		t.Fatalf("the Swift device's signature on its sealed copy: %v", err)
	}
	newer := &pb.Login{LoginId: "login-example", Version: listed.Version + 1}
	if err := VerifySealedLogin(automaticCopy, members, newer); !errors.Is(err, ErrMismatch) {
		t.Fatalf("a copy from before the catalogue's import must be refused, got %v", err)
	}
	deleted := &pb.Login{LoginId: "login-example"}
	automaticCopy.Version = 0
	if err := VerifySealedLogin(automaticCopy, members, deleted); !errors.Is(err, ErrMismatch) {
		t.Fatalf("a login whose password was deleted when it was blocked has no usable copy, got %v", err)
	}
	automaticCopy.Version = listed.Version
	automatic, err := OpenSealedLogin(automaticCopy, machine)
	if err != nil || automatic.Password != "example-password" {
		t.Fatalf("Automatic login: %v", err)
	}
}

func TestTheRelaySealsAPushForOneDevice(t *testing.T) {
	members, err := VerifySignedMembers(readKeyringTestFixture(t, "swift-members.pb", &pb.Signed{}), nil)
	if err != nil {
		t.Fatal(err)
	}
	device := members.Devices[0]
	approval := readKeyringTestFixture(t, "swift-approval.pb", &pb.Approval{})
	notice, err := SealNotice(&pb.SignedRequestEnvelope{Request: approval.Request, Login: &pb.Login{LoginId: "login-example", Title: "Example"}},
		testKey(t, "device_notice").PublicKey().Bytes(), device.KeyId)
	if err != nil {
		t.Fatal(err)
	}
	envelope, err := OpenNotice(notice, testKey(t, "device_notice"), device.KeyId)
	if err != nil || len(envelope.Request) == 0 {
		t.Fatalf("notice: %v", err)
	}
	if os.Getenv("AKR_WRITE_VECTORS") == "1" {
		raw, _ := proto.Marshal(notice)
		if err := os.WriteFile(vectors+"go-notice.pb", raw, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// The asking machine signs its request with the key Members lists as its tls_public_key; a device checks it
// against Members (the Swift test opens go-request.pb and does the same).
func TestARequestIsSignedByTheMachineThatAsks(t *testing.T) {
	members, err := VerifySignedMembers(readKeyringTestFixture(t, "swift-members.pb", &pb.Signed{}), nil)
	if err != nil {
		t.Fatal(err)
	}
	tlsKey, err := ecdsa.ParseRawPrivateKey(elliptic.P256(), testKey(t, "machine_tls").Bytes())
	if err != nil {
		t.Fatal(err)
	}
	machine := members.Machines[0]
	signed, err := SignRequest(&pb.Request{Domain: RequestDomain, RequestId: "request-2", LoginId: "login-example", MachineId: machine.MachineId,
		Reason: "You asked me to download October's invoice.", Agent: "Codex", AskedUnixSeconds: 1_795_000_000, AnswerByUnixSeconds: 1_795_000_600,
		AnswerBoxId: strings.Repeat("ab", 32), AnswerBoxKey: bytes.Repeat([]byte{7}, 32)},
		NewSoftwarePayloadSigner(tlsKey))
	if err != nil {
		t.Fatal(err)
	}
	if _, got, err := VerifySignedLeaseRequest(signed.Payload, signed.Signature, members); err != nil || got.MachineId != machine.MachineId {
		t.Fatalf("the machine's own request was refused: %v", err)
	}
	redirected := &pb.Request{}
	if err := proto.Unmarshal(signed.Payload, redirected); err != nil {
		t.Fatal(err)
	}
	redirected.LoginId = "another-login"
	raw, _ := proto.Marshal(redirected)
	if _, _, err := VerifySignedLeaseRequest(raw, signed.Signature, members); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("a request the relay changed must be refused, got %v", err)
	}
	if os.Getenv("AKR_WRITE_VECTORS") == "1" {
		raw, _ := proto.Marshal(&pb.SignedRequestEnvelope{Request: signed.Payload, RequestSignature: signed.Signature})
		if err := os.WriteFile(vectors+"go-request.pb", raw, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestAJoinProofIsTheSameInGoAndSwift(t *testing.T) {
	members, err := VerifySignedMembers(readKeyringTestFixture(t, "swift-members.pb", &pb.Signed{}), nil)
	if err != nil {
		t.Fatal(err)
	}
	secret := make([]byte, 32)
	for i := range secret {
		secret[i] = 1
	}
	joining := &pb.JoinRequest{Joining: &pb.JoinRequest_Device{Device: members.Devices[0]}}
	joining.Proof = ComputeJoinProof(secret, joining)
	if len(joining.Proof) != 32 || string(ComputeJoinProof(secret[:31], joining)) == string(joining.Proof) {
		t.Fatal("the proof does not depend on the secret")
	}
	if os.Getenv("AKR_WRITE_VECTORS") == "1" {
		raw, _ := proto.Marshal(joining)
		if err := os.WriteFile(vectors+"go-join.pb", raw, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	withNotice := &pb.Device{
		KeyId:            members.Devices[0].KeyId,
		Kind:             members.Devices[0].Kind,
		Label:            members.Devices[0].Label,
		SigningPublicKey: members.Devices[0].SigningPublicKey,
		OpeningPublicKey: members.Devices[0].OpeningPublicKey,
		TlsPublicKey:     members.Devices[0].TlsPublicKey,
		ReplyKeyId:       members.Devices[0].ReplyKeyId,
		ReplyPublicKey:   members.Devices[0].ReplyPublicKey,
		NoticePublicKey:  []byte{0x04, 1, 2, 3},
	}
	noticeProof := ComputeJoinProof(secret, &pb.JoinRequest{Joining: &pb.JoinRequest_Device{Device: withNotice}})
	if string(noticeProof) == string(joining.Proof) {
		t.Fatal("join proof must bind Device.NoticePublicKey when set")
	}
}

func TestARefusalIsTheSameInGoAndSwift(t *testing.T) {
	secret := make([]byte, 32)
	for i := range secret {
		secret[i] = 1
	}
	refusal := &pb.JoinRefusal{JoinerId: "machine-id", Key: DeriveRefusalReplyKey(secret, "machine-id"), Reply: "Not this one.",
		ReplyProof: ComputeRefusalReplyProof(secret, "machine-id", "Not this one.")}
	if string(ComputeRefusalReplyProof(secret, "machine-id", "Something else.")) == string(refusal.ReplyProof) || string(DeriveRefusalReplyKey(secret[:31], "machine-id")) == string(refusal.Key) {
		t.Fatal("the refusal does not depend on its words and the secret")
	}
	if os.Getenv("AKR_WRITE_VECTORS") == "1" {
		raw, _ := proto.Marshal(refusal)
		if err := os.WriteFile(vectors+"go-refusal.pb", raw, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func testSigningKey(t *testing.T) (*ecdsa.PrivateKey, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	public, err := key.PublicKey.Bytes()
	if err != nil {
		t.Fatal(err)
	}
	return key, public
}

// The relay lets a Mac answer its own agents' requests and a Watch post
// answers, by kind; the members list keeps each device's kind.
func TestAMacCannotBecomeAnIPhone(t *testing.T) {
	key, public := testSigningKey(t)
	mac := &pb.Device{KeyId: DeriveKeyID(public), Kind: pb.DeviceKind_DEVICE_KIND_MAC, Label: "MacBook Pro", SigningPublicKey: public}
	sign := func(members *pb.Members) *pb.Signed {
		raw, _ := proto.Marshal(members)
		signed, err := SignKeyringDocument(raw, mac.KeyId, NewSoftwarePayloadSigner(key))
		if err != nil {
			t.Fatal(err)
		}
		return signed
	}
	current, err := VerifySignedMembers(sign(&pb.Members{Domain: MembersDomain, Revision: 1, Devices: []*pb.Device{mac}}), nil)
	if err != nil {
		t.Fatal(err)
	}
	asIPhone := proto.Clone(mac).(*pb.Device)
	asIPhone.Kind = pb.DeviceKind_DEVICE_KIND_IPHONE
	if _, err := VerifySignedMembers(sign(&pb.Members{Domain: MembersDomain, Revision: 2, Devices: []*pb.Device{asIPhone}}), current); err == nil {
		t.Fatal("a Mac re-listed itself as an iPhone")
	}
	renamed := proto.Clone(mac).(*pb.Device)
	renamed.Label = "Work MacBook"
	if _, err := VerifySignedMembers(sign(&pb.Members{Domain: MembersDomain, Revision: 2, Devices: []*pb.Device{renamed}}), current); err != nil {
		t.Fatalf("an ordinary change was refused: %v", err)
	}
}

// A forged members list in iCloud names the user's iPhone by its key ID but
// carries the attacker's key, and is signed with it: it must not verify as
// signed by the iPhone.
func TestAListCannotPairADevicesIDWithAnotherKey(t *testing.T) {
	_, phonePublic := testSigningKey(t)
	attacker, attackerPublic := testSigningKey(t)
	forged := &pb.Device{KeyId: DeriveKeyID(phonePublic), Kind: pb.DeviceKind_DEVICE_KIND_IPHONE, SigningPublicKey: attackerPublic}
	raw, _ := proto.Marshal(&pb.Members{Domain: MembersDomain, Revision: 1, Devices: []*pb.Device{forged}})
	signed, err := SignKeyringDocument(raw, forged.KeyId, NewSoftwarePayloadSigner(attacker))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := VerifySignedMembers(signed, nil); err == nil {
		t.Fatal("a list pairing the iPhone's key ID with another key was taken as signed by the iPhone")
	}
}
