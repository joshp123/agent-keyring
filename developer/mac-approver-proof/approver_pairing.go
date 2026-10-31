// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"fmt"
	"os"
	"path/filepath"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func (p *proof) addApprover() {
	phone := client{address: p.receiver.address, cert: identity()}
	signing, e := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	must(e)
	public := elliptic.Marshal(elliptic.P256(), signing.X, signing.Y)
	spki, e := relaycrypto.CertificateSPKI(phone.cert)
	must(e)
	key := &pb.ApproverKey{KeyId: fmt.Sprintf("%x", relaycrypto.Hash(public)), PublicKey: public, TlsPublicKey: spki, Label: "Dummy phone approver"}
	conn := phone.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PairApprover{PairApprover: &pb.PairApproverRequest{Key: key, TlsPublicKey: spki}}})
	defer conn.Close()
	pending := receive(conn).GetEnrolStatus()
	require(pending.State == pb.EnrolState_ENROL_STATE_PENDING, "added approver activated before comparison")
	phone.pin = conn.ConnectionState().PeerCertificates[0].RawSubjectPublicKeyInfo
	transcript := relaycrypto.PairTranscript(phone.pin, spki, public, pending.ApproverKeySet.KeySet)
	fingerprint := relaycrypto.Fingerprint(transcript)
	work := p.owner.wait(func(e []string) bool { return e[0] == "APPROVER" && e[1] == key.KeyId })
	require(work[2] == fingerprint, "phone and Swift Mac compared different transcripts")
	p.owner.status()
	before := p.owner.authorizations
	p.owner.action("confirm-approver", key.KeyId, fingerprint)
	approved := receive(conn).GetEnrolStatus()
	require(approved.State == pb.EnrolState_ENROL_STATE_APPROVED, "added approver was not activated")
	var previous, next pb.ApproverKeySet
	must(proto.Unmarshal(pending.ApproverKeySet.KeySet, &previous))
	must(proto.Unmarshal(approved.ApproverKeySet.KeySet, &next))
	require(next.Revision == previous.Revision+1 && next.RuleOwnerKeyId == previous.RuleOwnerKeyId, "pairing changed owner or reset revision")
	must(relaycrypto.Verify(previous.Keys[0].PublicKey, approved.ApproverKeySet.KeySet, approved.ApproverKeySet.Signature))
	require(bytes.Equal(next.PairingTranscriptSha256, relaycrypto.Hash(transcript)), "added key set omitted compared transcript")
	found := false
	for _, candidate := range next.Keys {
		if proto.Equal(candidate, key) {
			found = true
		}
	}
	require(found, "signed key set omitted phone keys")
	roster := phone.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetEnrolmentSet{GetEnrolmentSet: &pb.GetEnrolmentSetRequest{}}}).GetEnrolmentSet()
	var machines pb.EnrolmentSet
	must(proto.Unmarshal(roster.EnrolmentSet, &machines))
	require(machines.Revision == next.EnrolmentSetRevision && bytes.Equal(relaycrypto.Hash(roster.EnrolmentSet), next.EnrolmentSetSha256), "added key set did not bind exact published machine roster")
	must(relaycrypto.Verify(previous.Keys[0].PublicKey, roster.EnrolmentSet, roster.Signature))
	p.owner.status()
	require(p.owner.authorizations == before+1, "adding approver needed another authorization")
	if p.cli != "" {
		must(p.cliCommand("find", "example.com").Run())
		data, e := os.ReadFile(filepath.Join(p.root, "cli/state.pb"))
		must(e)
		var saved clientstate.State
		must(proto.Unmarshal(data, &saved))
		require(bytes.Equal(saved.Approvers.KeySet, approved.ApproverKeySet.KeySet), "real CLI failed to advance pinned approver chain")
	}
	fmt.Println("PASS added approver: independent fingerprint, one approval, signed next key set binds exact roster")
	if p.cli != "" {
		fmt.Println("PASS actual CLI advances its pinned approver chain")
	}
}
