// Written by AI on 2026.11.18 by model claude opus 5.5.
// What the Swift apps sealed and signed (AgentKeyringSealingTests), opened here
// as the command opens it on the asking machine; and a push sealed here as the
// relay seals it, for the Swift test to open. AKR_WRITE_VECTORS=1 rewrites
// the Go side's file.
package keyring

import (
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
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

func read[T proto.Message](t *testing.T, name string, message T) T {
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
	members, err := VerifiedMembers(read(t, "swift-members.pb", &pb.Signed{}), nil)
	if err != nil {
		t.Fatal(err)
	}
	machine := testKey(t, "machine_receiving")
	approval := read(t, "swift-approval.pb", &pb.Approval{})
	answer, _, err := VerifiedAnswer(approval, members)
	if err != nil {
		t.Fatal(err)
	}
	contents, err := OpenApproval(approval, members, machine, time.Unix(answer.DecidedUnixSeconds+1, 0))
	if err != nil {
		t.Fatal(err)
	}
	if contents.Password != "example-password" || len(contents.OneTimeCodes) != 61 || contents.OneTimeCodes[0].Code != "527227" {
		t.Fatalf("unexpected delivery: password ok %v, %d codes", contents.Password == "example-password", len(contents.OneTimeCodes))
	}
	if _, err := OpenApproval(approval, members, machine, time.Unix(answer.NotAfterUnixSeconds, 0)); err != ErrExpired {
		t.Fatalf("an approval past its 30 minutes must not open, got %v", err)
	}

	denial, _, err := VerifiedAnswer(read(t, "swift-denial.pb", &pb.Approval{}), members)
	if err != nil || denial.Reply != "The invoice is in my email." {
		t.Fatalf("denial with words: %v", err)
	}

	automaticCopy := read(t, "swift-automatic.pb", &pb.SealedLogin{})
	listed := &pb.Login{LoginId: "login-example", Version: 1_795_000_000_000_000_000}
	if err := CheckSealed(automaticCopy, members, listed); err != nil {
		t.Fatalf("the Swift device's signature on its sealed copy: %v", err)
	}
	newer := &pb.Login{LoginId: "login-example", Version: listed.Version + 1}
	if err := CheckSealed(automaticCopy, members, newer); err != ErrMismatch {
		t.Fatalf("a copy from before the catalogue's import must be refused, got %v", err)
	}
	automatic, err := OpenLogin(automaticCopy, machine)
	if err != nil || automatic.Password != "example-password" {
		t.Fatalf("Automatic login: %v", err)
	}
}

func TestTheRelaySealsAPushForOneDevice(t *testing.T) {
	members, err := VerifiedMembers(read(t, "swift-members.pb", &pb.Signed{}), nil)
	if err != nil {
		t.Fatal(err)
	}
	device := members.Devices[0]
	approval := read(t, "swift-approval.pb", &pb.Approval{})
	relayKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	sealed, err := SealLogin(&pb.LoginSecret{LoginId: "login-example", Username: "example@example.com", Password: "example-password"},
		1, device.OpeningPublicKey, device.KeyId, "test", SoftwareSigner(relayKey))
	if err != nil {
		t.Fatal(err)
	}
	notice, err := SealNotice(&pb.Work{Request: approval.Request, SealedLogin: sealed}, testKey(t, "device_notice").PublicKey().Bytes(), device.KeyId)
	if err != nil {
		t.Fatal(err)
	}
	work, err := OpenNotice(notice, testKey(t, "device_notice"), device.KeyId)
	if err != nil || len(work.Request) == 0 {
		t.Fatalf("notice: %v", err)
	}
	if os.Getenv("AKR_WRITE_VECTORS") == "1" {
		raw, _ := proto.Marshal(notice)
		if err := os.WriteFile(vectors+"go-notice.pb", raw, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// The asking machine signs its request with its TLS key; a device checks it
// against Members (the Swift test opens go-request.pb and does the same).
func TestARequestIsSignedByTheMachineThatAsks(t *testing.T) {
	members, err := VerifiedMembers(read(t, "swift-members.pb", &pb.Signed{}), nil)
	if err != nil {
		t.Fatal(err)
	}
	tlsKey, err := ecdsa.ParseRawPrivateKey(elliptic.P256(), testKey(t, "machine_tls").Bytes())
	if err != nil {
		t.Fatal(err)
	}
	machine := members.Machines[0]
	signed, err := SignRequest(&pb.Request{Domain: RequestDomain, RequestId: "request-2", LoginId: "login-example", MachineId: machine.MachineId,
		Reason: "You asked me to download October's invoice.", Agent: "Codex", AskedUnixSeconds: 1_795_000_000, AnswerByUnixSeconds: 1_795_000_600},
		SoftwareSigner(tlsKey))
	if err != nil {
		t.Fatal(err)
	}
	if _, got, err := CheckRequest(signed.Payload, signed.Signature, members); err != nil || got.MachineId != machine.MachineId {
		t.Fatalf("the machine's own request was refused: %v", err)
	}
	redirected := &pb.Request{}
	proto.Unmarshal(signed.Payload, redirected)
	redirected.LoginId = "another-login"
	raw, _ := proto.Marshal(redirected)
	if _, _, err := CheckRequest(raw, signed.Signature, members); err != ErrBadSignature {
		t.Fatalf("a request the relay changed must be refused, got %v", err)
	}
	if os.Getenv("AKR_WRITE_VECTORS") == "1" {
		raw, _ := proto.Marshal(&pb.Work{Request: signed.Payload, RequestSignature: signed.Signature})
		if err := os.WriteFile(vectors+"go-request.pb", raw, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestAJoinProofIsTheSameInGoAndSwift(t *testing.T) {
	members, err := VerifiedMembers(read(t, "swift-members.pb", &pb.Signed{}), nil)
	if err != nil {
		t.Fatal(err)
	}
	secret := make([]byte, 32)
	for i := range secret {
		secret[i] = 1
	}
	joining := &pb.JoinRequest{Joining: &pb.JoinRequest_Device{Device: members.Devices[0]}}
	joining.Proof = JoinProof(secret, joining)
	if len(joining.Proof) != 32 || string(JoinProof(secret[:31], joining)) == string(joining.Proof) {
		t.Fatal("the proof does not depend on the secret")
	}
	if os.Getenv("AKR_WRITE_VECTORS") == "1" {
		raw, _ := proto.Marshal(joining)
		if err := os.WriteFile(vectors+"go-join.pb", raw, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestARefusalIsTheSameInGoAndSwift(t *testing.T) {
	secret := make([]byte, 32)
	for i := range secret {
		secret[i] = 1
	}
	refusal := &pb.JoinRefusal{JoinerId: "machine-id", Key: RefusalKey(secret, "machine-id"), Reply: "Not this one.",
		ReplyProof: RefusalReplyProof(secret, "machine-id", "Not this one.")}
	if string(RefusalReplyProof(secret, "machine-id", "Something else.")) == string(refusal.ReplyProof) || string(RefusalKey(secret[:31], "machine-id")) == string(refusal.Key) {
		t.Fatal("the refusal does not depend on its words and the secret")
	}
	if os.Getenv("AKR_WRITE_VECTORS") == "1" {
		raw, _ := proto.Marshal(refusal)
		if err := os.WriteFile(vectors+"go-refusal.pb", raw, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// The relay lets a Mac answer its own agents' requests and a Watch post
// answers, by kind; the members list keeps each device's kind.
func TestAMacCannotBecomeAnIPhone(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	public := elliptic.Marshal(elliptic.P256(), key.X, key.Y) //nolint:staticcheck // X9.63, as the devices write it.
	mac := &pb.Device{KeyId: KeyID(public), Kind: pb.DeviceKind_DEVICE_KIND_MAC, Label: "MacBook Pro", SigningPublicKey: public}
	sign := func(members *pb.Members) *pb.Signed {
		raw, _ := proto.Marshal(members)
		signed, err := Sign(raw, mac.KeyId, SoftwareSigner(key))
		if err != nil {
			t.Fatal(err)
		}
		return signed
	}
	current, err := VerifiedMembers(sign(&pb.Members{Domain: MembersDomain, Revision: 1, Devices: []*pb.Device{mac}}), nil)
	if err != nil {
		t.Fatal(err)
	}
	asIPhone := proto.Clone(mac).(*pb.Device)
	asIPhone.Kind = pb.DeviceKind_DEVICE_KIND_IPHONE
	if _, err := VerifiedMembers(sign(&pb.Members{Domain: MembersDomain, Revision: 2, Devices: []*pb.Device{asIPhone}}), current); err == nil {
		t.Fatal("a Mac re-listed itself as an iPhone")
	}
	renamed := proto.Clone(mac).(*pb.Device)
	renamed.Label = "Work MacBook"
	if _, err := VerifiedMembers(sign(&pb.Members{Domain: MembersDomain, Revision: 2, Devices: []*pb.Device{renamed}}), current); err != nil {
		t.Fatalf("an ordinary change was refused: %v", err)
	}
}
