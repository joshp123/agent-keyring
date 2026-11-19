// Written by AI on 2026.11.19 by model claude opus 5.5.
package relay

import (
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"slices"
	"strings"
	"testing"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/keyring"
	"google.golang.org/protobuf/proto"
)

// Another computer that claims to have answered its own request as the Mac
// would must not be shown as approved on the iPhone; only the Mac may.
func TestOnlyTheMacAnswersItsOwnRequest(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{Store: store}
	linux := &pb.Machine{MachineId: "linux", Label: "Linux server"}
	mac := &pb.Machine{MachineId: "mac", Label: "MacBook Pro"}
	macDevice := &pb.Device{KeyId: "mac-device", Kind: pb.DeviceKind_DEVICE_KIND_MAC, Label: "MacBook Pro"}
	store.update(func(data *saved) error {
		data.Requests["from-linux"] = &request{MachineID: "linux", State: pb.LeaseState_LEASE_STATE_WAITING}
		data.Requests["from-mac"] = &request{MachineID: "mac", State: pb.LeaseState_LEASE_STATE_WAITING}
		return nil
	})
	lease, err := s.end(context.Background(), caller{machine: linux}, "from-linux", "approved")
	if err != nil || lease.State != pb.LeaseState_LEASE_STATE_CANCELLED || lease.AnsweredBy != "" {
		t.Fatalf("another computer marked its own request approved: %v %v", lease, err)
	}
	lease, err = s.end(context.Background(), caller{machine: mac, device: macDevice}, "from-mac", "approved")
	if err != nil || lease.State != pb.LeaseState_LEASE_STATE_APPROVED || lease.AnsweredBy != "MacBook Pro" {
		t.Fatalf("the Mac's own answer was not recorded: %v %v", lease, err)
	}
}

// Josh sets a login to Blocked: every copy of it leaves the relay, and the
// Mac's next export does not put one back while it stays Blocked.
func TestABlockedLoginHasNoCopyOnTheRelay(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{Store: store}
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	mac := &pb.Device{KeyId: "mac", Kind: pb.DeviceKind_DEVICE_KIND_MAC, SigningPublicKey: elliptic.Marshal(elliptic.P256(), key.X, key.Y)}
	iphone := &pb.Device{KeyId: "iphone", Kind: pb.DeviceKind_DEVICE_KIND_IPHONE}
	store.members = &pb.Members{Devices: []*pb.Device{mac, iphone}, Machines: []*pb.Machine{{MachineId: "mini"}}}
	publish := func(revision uint64, rule pb.Rule) {
		t.Helper()
		payload, _ := proto.Marshal(&pb.Catalogue{Domain: keyring.CatalogueDomain, Revision: revision,
			Logins: []*pb.Login{{LoginId: "shop", Rule: rule}, {LoginId: "mail", Rule: pb.Rule_RULE_ASK}}})
		signed, _ := keyring.Sign(payload, "mac", keyring.SoftwareSigner(key))
		if err := s.publishCatalogue(signed); err != nil {
			t.Fatal(err)
		}
	}
	export := func() {
		t.Helper()
		batch := &pb.SealedLogins{Logins: []*pb.SealedLogin{
			{LoginId: "shop", OpenerId: "iphone"}, {LoginId: "shop", OpenerId: "mini"}, {LoginId: "mail", OpenerId: "iphone"}}}
		if err := s.publishSealedLogins(batch); err != nil {
			t.Fatal(err)
		}
	}
	held := func(opener string) []string {
		var ids []string
		for _, sealed := range s.sealedFor(opener).Logins {
			ids = append(ids, sealed.LoginId)
		}
		return ids
	}
	publish(1, pb.Rule_RULE_AUTOMATIC)
	export()
	if len(held("iphone")) != 2 || len(held("mini")) != 1 {
		t.Fatalf("before blocking: iPhone holds %v, mini holds %v", held("iphone"), held("mini"))
	}
	publish(2, pb.Rule_RULE_BLOCKED)
	if !slices.Equal(held("iphone"), []string{"mail"}) || len(held("mini")) != 0 {
		t.Fatalf("after blocking: iPhone holds %v, mini holds %v", held("iphone"), held("mini"))
	}
	export()
	if !slices.Equal(held("iphone"), []string{"mail"}) || len(held("mini")) != 0 {
		t.Fatalf("a later export put a Blocked login back: iPhone holds %v, mini holds %v", held("iphone"), held("mini"))
	}
}

// A request at every size limit the relay allows, signed, with a sealed copy
// and its login, still fits in the 4096 bytes Apple carries.
func TestTheLargestRequestFitsInAPush(t *testing.T) {
	long := func(n int) string { return strings.Repeat("x", n) }
	machineKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	request, _ := keyring.SignRequest(&pb.Request{Domain: keyring.RequestDomain, RequestId: long(32), LoginId: long(36), MachineId: long(64),
		Reason: long(400), Agent: long(100), Project: long(100), Task: long(100), AskedUnixSeconds: 1 << 40, AnswerByUnixSeconds: 1 << 40},
		keyring.SoftwareSigner(machineKey))
	opening, _ := ecdh.P256().GenerateKey(rand.Reader)
	sealed, _ := keyring.SealLogin(&pb.LoginSecret{LoginId: long(36), Username: long(100), Password: long(128), TotpSeed: make([]byte, 64),
		Title: long(100), Sites: []string{long(100), long(100)}}, 1<<62, opening.PublicKey().Bytes(), long(64), long(64), keyring.SoftwareSigner(machineKey))
	work := &pb.Work{Request: request.Payload, RequestSignature: request.Signature, SealedLogin: sealed,
		Login: &pb.Login{LoginId: long(36), Title: long(100), Sites: []string{long(100), long(100)}, Account: long(100), Rule: pb.Rule_RULE_ASK, Version: 1 << 62}}
	notice, _ := ecdh.P256().GenerateKey(rand.Reader)
	sealedNotice, err := keyring.SealNotice(work, notice.PublicKey().Bytes(), long(64))
	if err != nil {
		t.Fatal(err)
	}
	if size := len(pushPayload(long(32), sealedNotice)); size > 4096 {
		t.Fatalf("the push is %d bytes; Apple carries 4096", size)
	} else {
		t.Logf("largest push: %d bytes", size)
	}
}
