// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package main

import (
	"bytes"
	"crypto/ecdsa"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func (p *proof) swiftReplacementProof(phone *phoneProcess, oldKey *pb.ApproverKey, oldSigner *ecdsa.PrivateKey, directory, port string) (*phoneProcess, *pb.ApproverKey) {
	require(len(oldKey.EncryptionPublicKey) == 0, "replacement did not start with an old approval-only pairing")
	oldPeer := wireClient{address: p.address, certificate: identity(directory), pin: p.approver.pin}
	oldSealing, err := os.ReadFile(filepath.Join(directory, "sealing.raw"))
	must(err)
	countPath := filepath.Join(directory, "authorization-count")
	before, err := os.ReadFile(countPath)
	must(err)
	replacementTLS := identity(filepath.Join(directory, "replacement-tls"))
	tlsKey := replacementTLS.PrivateKey.(*ecdsa.PrivateKey)
	must(os.WriteFile(filepath.Join(directory, "replacement-tls-cert.der"), replacementTLS.Certificate[0], 0600))
	must(os.WriteFile(filepath.Join(directory, "replacement-tls-private.x963"), append(public(tlsKey), tlsKey.D.FillBytes(make([]byte, 32))...), 0600))
	comparison := phone.command("replace-pairing")
	require(strings.HasPrefix(comparison, "PAIR\t"), "old paired phone could not start replacement")
	require(phone.command("requests") == "REQUESTS\t", "old requests survived replacement")
	var pair *pb.PairApproverRequest
	for pair == nil || pair.Key.KeyId == oldKey.KeyId {
		pair = good(receive(p.work)).GetWork().GetPairing()
	}
	require(pair.Key.KeyId != oldKey.KeyId && !bytes.Equal(pair.TlsPublicKey, oldKey.TlsPublicKey) && len(pair.Key.EncryptionPublicKey) == 65, "replacement reused a signing or TLS key, or has no copy key")
	newSealing, err := os.ReadFile(filepath.Join(directory, "sealing.raw"))
	must(err)
	require(!bytes.Equal(newSealing, oldSealing), "replacement reused the sealing key")
	transcript := relaycrypto.PairTranscript(p.approver.pin, pair.TlsPublicKey, pair.Key.PublicKey, p.keys.KeySet, pair.Key.EncryptionPublicKey)
	require(comparison == "PAIR\t"+relaycrypto.Fingerprint(transcript), "replacement comparisons differ")
	// Cancel and reopen the new comparison without reviving the old identity.
	phone.command("cancel-pairing")
	phone.stop()
	phone = startPhone(phone.cmd.Path, directory)
	require(phone.command("pair\t"+port) == comparison, "cancel/reopen rotated or lost the replacement comparison")
	set := new(pb.ApproverKeySet)
	must(proto.Unmarshal(p.keys.KeySet, set))
	set.Revision++
	var retained []*pb.ApproverKey
	for _, key := range set.Keys {
		if key.KeyId != oldKey.KeyId {
			retained = append(retained, key)
		}
	}
	set.Keys = append(retained, pair.Key)
	set.ConfigurationRevision = p.configuration.Revision
	set.ConfigurationSha256 = relaycrypto.Hash(p.signedConfiguration.Configuration)
	set.PairingTranscriptSha256 = relaycrypto.Hash(transcript)
	raw := encoded(set)
	p.keys = &pb.SignedApproverKeySet{KeySet: raw, Signature: sign(p.signer, raw), SignerKeyId: p.key.KeyId}
	require(good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: p.keys}})).GetPublish().Accepted, "Mac-signed phone replacement refused")
	phone.wait("status", "paired")
	after, err := os.ReadFile(countPath)
	must(err)
	require(bytes.Equal(before, after), "replacement requested phone authorization")
	fetch := &pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetCopyUpdate{GetCopyUpdate: &pb.GetCopyUpdateRequest{}}}
	require(oldPeer.call(fetch).GetError() != nil, "retired phone can still fetch copies")
	require(oldPeer.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_RegisterPush{RegisterPush: &pb.PushRegistration{ApproverKeyId: oldKey.KeyId, ApnsDeviceToken: []byte("retired-token")}}}).GetError() != nil, "retired phone can still register push")
	lease := good(p.client.call(leaseRequest("retired-phone", "retired-phone", p.enrolled.RecipientId))).GetClient().GetLease()
	record := p.phoneRequest(lease.LeaseId)
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_EscalateToPhone{EscalateToPhone: &pb.PhoneEscalation{LeaseId: lease.LeaseId, Record: record}}}))
	oldDecision := p.directPhoneDecision(record, oldKey, oldSigner, nil)
	require(oldPeer.call(oldDecision).GetError() != nil, "retired phone can still decide")
	id := hex.EncodeToString(relaycrypto.Digest("agentkeyring.request.v1", record))
	phone.wait("requests", id+"=waitingForYou")
	require(strings.Contains(phone.command("deny\t"+id), "denied"), "fresh phone could not deny")
	phone.command("clear\t" + id)
	fmt.Println("PASS old approval-only Swift pairing upgrades through fresh signing/TLS/sealing keys and matching comparison; cancel/reopen recovers; Mac-signed replacement retires old copy/push/decision access")
	return phone, pair.Key
}
