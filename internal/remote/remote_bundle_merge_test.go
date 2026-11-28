// Written by AI on 2026.11.24 by model gemini-4-neon.
package remote

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"path/filepath"
	"strings"
	"testing"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"github.com/opentrawl/agent-keyring/internal/keyring"
	"google.golang.org/protobuf/proto"
)

func testSign(t *testing.T, key *ecdsa.PrivateKey, msg proto.Message) *pb.Signed {
	t.Helper()
	payload, err := proto.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	pub := testPublicKey(t, key)
	signed, err := keyring.SignKeyringDocument(payload, keyring.DeriveKeyID(pub), keyring.NewSoftwarePayloadSigner(key))
	if err != nil {
		t.Fatal(err)
	}
	return signed
}

func testPublicKey(t *testing.T, key *ecdsa.PrivateKey) []byte {
	t.Helper()
	public, err := key.PublicKey.Bytes()
	if err != nil {
		t.Fatal(err)
	}
	return public
}

func testDevice(t *testing.T, label string) (*ecdsa.PrivateKey, *ecdsa.PrivateKey, *pb.Device) {
	t.Helper()
	signing, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	reply, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signPub := testPublicKey(t, signing)
	replyPub := testPublicKey(t, reply)
	return signing, reply, &pb.Device{
		KeyId:            keyring.DeriveKeyID(signPub),
		Label:            label,
		SigningPublicKey: signPub,
		ReplyKeyId:       keyring.DeriveKeyID(replyPub),
		ReplyPublicKey:   replyPub,
	}
}

// Removing the device that last signed the catalogue must not stop an existing
// computer from renewing Freshness when a later bundle still carries that same
// catalogue, while a forged or altered catalogue from the removed device must
// still be refused.
func TestKeepBundleAfterCatalogueSignerRemovedAndConflictingMembers(t *testing.T) {
	macSign, _, macDev := testDevice(t, "Mac")
	phoneSign, phoneReply, phoneDev := testDevice(t, "iPhone")

	machineID := "machine-vps"
	members1 := &pb.Members{
		Domain:   "agentkeyring.members.v2",
		Revision: 1,
		Devices:  []*pb.Device{macDev, phoneDev},
		Machines: []*pb.Machine{{MachineId: machineID, Label: "VPS"}},
	}
	signedMembers1 := testSign(t, macSign, members1)
	cat1 := &pb.Catalogue{
		Domain:   "agentkeyring.catalogue.v2",
		Revision: 1,
		Logins:   []*pb.Login{{LoginId: "login-1", Title: "Example", Rule: pb.Rule_RULE_AUTOMATIC, Version: 1}},
	}
	signedCat1 := testSign(t, macSign, cat1)

	store := clientstate.ClientStateStore{Directory: filepath.Join(t.TempDir(), "state")}
	if err := store.UpdateClientState(context.Background(), func(st *clientstate.State) error {
		st.RecipientId = machineID
		st.Members, _ = proto.Marshal(signedMembers1)
		st.Bundle, _ = proto.Marshal(&pb.Bundle{Catalogue: signedCat1})
		st.CatalogueRevision = 1
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	client := &RemoteKeyringClient{Store: store}

	// iPhone removes Mac in Members rev 2, then sends a mailbox bundle carrying
	// the unchanged rev 1 catalogue (signed by Mac) plus a Freshness signed by iPhone.
	members2 := &pb.Members{
		Domain:   "agentkeyring.members.v2",
		Revision: 2,
		Devices:  []*pb.Device{phoneDev},
		Machines: []*pb.Machine{{MachineId: machineID, Label: "VPS"}},
	}
	signedMembers2 := testSign(t, phoneSign, members2)
	fresh := &pb.Freshness{
		Domain:                "agentkeyring.fresh.v2",
		MachineId:             machineID,
		MembersRevision:       2,
		CatalogueRevision:     1,
		ValidUntilUnixSeconds: time.Now().Unix() + 7*24*3600,
	}
	signedFresh := testSign(t, phoneReply, fresh)

	if err := client.keepBundle(context.Background(), &pb.Bundle{
		Members:   signedMembers2,
		Catalogue: signedCat1,
		Freshness: signedFresh,
	}, true); err != nil {
		t.Fatalf("bundle with unchanged catalogue from removed signer failed: %v", err)
	}
	st, err := store.LoadClientState(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if st.FreshUntilUnixSeconds != fresh.ValidUntilUnixSeconds {
		t.Fatalf("FreshUntilUnixSeconds = %d, want %d", st.FreshUntilUnixSeconds, fresh.ValidUntilUnixSeconds)
	}

	// A new catalogue (rev 2) signed by the removed Mac must still be refused.
	cat2Removed := &pb.Catalogue{
		Domain:   "agentkeyring.catalogue.v2",
		Revision: 2,
		Logins:   []*pb.Login{{LoginId: "login-1", Title: "Forged", Rule: pb.Rule_RULE_AUTOMATIC, Version: 2}},
	}
	if err := client.keepBundle(context.Background(), &pb.Bundle{
		Catalogue: testSign(t, macSign, cat2Removed),
	}, true); err == nil || !strings.Contains(err.Error(), "catalogue refused") {
		t.Fatalf("new catalogue from removed signer was not refused: %v", err)
	}

	checkConflictingMembers(t, client, phoneSign, phoneDev, machineID)
}

func checkConflictingMembers(t *testing.T, client *RemoteKeyringClient, phoneSign *ecdsa.PrivateKey, phoneDev *pb.Device, machineID string) {
	t.Helper()
	// A conflicting Members list with the same revision (2) must be refused when no newer revision supersedes it.
	conflictingMembers2 := &pb.Members{
		Domain:   "agentkeyring.members.v2",
		Revision: 2,
		Devices:  []*pb.Device{phoneDev},
		Machines: []*pb.Machine{{MachineId: machineID, Label: "Other"}},
	}
	signedConflicting2 := testSign(t, phoneSign, conflictingMembers2)
	if err := client.keepBundle(context.Background(), &pb.Bundle{
		Members: signedConflicting2,
	}, true); err == nil || !strings.Contains(err.Error(), "another list of the same revision") {
		t.Fatalf("conflicting same-revision Members was not refused: %v", err)
	}

	// If a mailbox carries a conflicting historical revision 2 adding a branch-only device,
	// an intervening revision 3 signed only by that untrusted device, and a valid revision 4
	// signed by a device in our trusted membership removing this computer, the removal must apply.
	branchSign, _, branchDev := testDevice(t, "BranchDevice")
	conflictingBranch2 := &pb.Members{
		Domain:   "agentkeyring.members.v2",
		Revision: 2,
		Devices:  []*pb.Device{phoneDev, branchDev},
		Machines: []*pb.Machine{{MachineId: machineID, Label: "VPS"}},
	}
	interveningBranch3 := &pb.Members{
		Domain:   "agentkeyring.members.v2",
		Revision: 3,
		Devices:  []*pb.Device{phoneDev, branchDev},
		Machines: []*pb.Machine{{MachineId: machineID, Label: "VPS"}},
	}
	members4Remove := &pb.Members{
		Domain:   "agentkeyring.members.v2",
		Revision: 4,
		Devices:  []*pb.Device{phoneDev},
		Machines: nil,
	}
	if err := client.keepBundle(context.Background(), &pb.Bundle{
		MembersSince: []*pb.Signed{
			testSign(t, phoneSign, conflictingBranch2),
			testSign(t, branchSign, interveningBranch3),
		},
		Members: testSign(t, phoneSign, members4Remove),
	}, true); err != nil {
		t.Fatalf("valid rev 4 removal after conflicting branch rev 2 + untrusted rev 3 failed: %v", err)
	}
	st, err := client.Store.LoadClientState(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !st.Removed {
		t.Fatalf("expected computer to be marked removed after rev 4")
	}
}
