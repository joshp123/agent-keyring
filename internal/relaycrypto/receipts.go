// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package relaycrypto

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/x509"
	"errors"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"google.golang.org/protobuf/proto"
)

func UpdateTarget(update *pb.TrustUpdate) (*pb.UpdateReceiptQuery, error) {
	target := new(pb.UpdateReceiptQuery)
	var raw []byte
	switch value := update.GetUpdate().(type) {
	case *pb.TrustUpdate_ApproverKeys:
		set := new(pb.ApproverKeySet)
		if proto.Unmarshal(value.ApproverKeys.KeySet, set) != nil {
			return nil, errors.New("Invalid approver update.")
		}
		target.Kind, target.Revision, raw = pb.UpdateKind_UPDATE_KIND_APPROVER_KEYS, set.Revision, value.ApproverKeys.KeySet
	case *pb.TrustUpdate_Configuration:
		config := new(pb.Configuration)
		if proto.Unmarshal(value.Configuration.Configuration, config) != nil {
			return nil, errors.New("Invalid configuration update.")
		}
		target.Kind, target.Revision, raw = pb.UpdateKind_UPDATE_KIND_CONFIGURATION, config.Revision, value.Configuration.Configuration
	default:
		return nil, errors.New("Missing signed trust update.")
	}
	if target.Revision == 0 {
		return nil, errors.New("Update revision must be positive.")
	}
	target.UpdateSha256 = Hash(raw)
	return target, nil
}

func SignUpdateReceipt(key crypto.Signer, target *pb.UpdateReceiptQuery) (*pb.SignedUpdateReceipt, error) {
	spki, err := x509.MarshalPKIXPublicKey(key.Public())
	if err != nil {
		return nil, err
	}
	statement, err := proto.Marshal(&pb.UpdateReceipt{Domain: "agentkeyring.update-receipt.v1", DeviceSpkiSha256: Hash(spki), Kind: target.Kind, Revision: target.Revision, UpdateSha256: target.UpdateSha256})
	if err != nil {
		return nil, err
	}
	signature, err := key.Sign(rand.Reader, Hash(statement), crypto.SHA256)
	if err != nil {
		return nil, err
	}
	return &pb.SignedUpdateReceipt{Receipt: statement, Signature: signature}, nil
}

func VerifyUpdateReceipt(spki []byte, signed *pb.SignedUpdateReceipt, target *pb.UpdateReceiptQuery) error {
	receipt := new(pb.UpdateReceipt)
	if signed == nil || target == nil || proto.Unmarshal(signed.Receipt, receipt) != nil || receipt.Domain != "agentkeyring.update-receipt.v1" || receipt.Revision == 0 || len(receipt.UpdateSha256) != 32 || !bytes.Equal(receipt.DeviceSpkiSha256, Hash(spki)) || receipt.Kind != target.Kind || receipt.Revision != target.Revision || !bytes.Equal(receipt.UpdateSha256, target.UpdateSha256) {
		return errors.New("Receipt does not name this device and exact update.")
	}
	public, err := x509.ParsePKIXPublicKey(spki)
	if err != nil {
		return err
	}
	key, ok := public.(*ecdsa.PublicKey)
	if !ok || key.Curve.Params().Name != "P-256" || !ecdsa.VerifyASN1(key, Hash(signed.Receipt), signed.Signature) {
		return errors.New("Invalid device TLS-key receipt signature.")
	}
	return nil
}

func ConfigurationWithdraws(old, next *pb.Configuration) bool {
	for _, before := range old.GetMachines() {
		var after *pb.EnrolledMachine
		for _, candidate := range next.GetMachines() {
			if candidate.RecipientId == before.RecipientId {
				after = candidate
				break
			}
		}
		if after == nil || !bytes.Equal(before.TlsPublicKey, after.TlsPublicKey) || !bytes.Equal(before.ReceiverPublicKey, after.ReceiverPublicKey) || before.ReceiverKeyId != after.ReceiverKeyId || before.TailscaleNodeId != after.TailscaleNodeId || (before.AutomaticAllowed && !after.AutomaticAllowed) {
			return true
		}
	}
	for _, before := range old.GetLogins() {
		var after *pb.Login
		for _, candidate := range next.GetLogins() {
			if candidate.LoginId == before.LoginId {
				after = candidate
				break
			}
		}
		if after == nil || (before.Rule != pb.AccessRule_ACCESS_RULE_BLOCKED && after.Rule == pb.AccessRule_ACCESS_RULE_BLOCKED) || (before.Rule == pb.AccessRule_ACCESS_RULE_AUTOMATIC && after.Rule != before.Rule) {
			return true
		}
		for _, site := range before.Sites {
			found := false
			for _, current := range after.Sites {
				if site == current {
					found = true
					break
				}
			}
			if !found {
				return true
			}
		}
	}
	return old != nil && (old.AutomaticKeyId != next.AutomaticKeyId || !bytes.Equal(old.AutomaticSigningPublicKey, next.AutomaticSigningPublicKey) || !bytes.Equal(old.RelayEncryptionPublicKey, next.RelayEncryptionPublicKey)) && old.AutomaticKeyId != ""
}
func ApproverKeysWithdraw(old, next *pb.ApproverKeySet) bool {
	for _, before := range old.GetKeys() {
		found := false
		for _, after := range next.GetKeys() {
			if proto.Equal(before, after) {
				found = true
				break
			}
		}
		if !found {
			return true
		}
	}
	return old != nil && old.RuleOwnerKeyId != next.RuleOwnerKeyId
}
