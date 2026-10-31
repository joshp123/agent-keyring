// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package relaycrypto

import (
	"bytes"
	"errors"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"google.golang.org/protobuf/proto"
)

// Legacy unspecified roles are MAC only for the already pinned rule owner.
func Role(set *pb.ApproverKeySet, key *pb.ApproverKey) pb.ApproverRole {
	if key == nil {
		return pb.ApproverRole_APPROVER_ROLE_UNSPECIFIED
	}
	if key.Role == pb.ApproverRole_APPROVER_ROLE_UNSPECIFIED && key.KeyId == set.RuleOwnerKeyId {
		return pb.ApproverRole_APPROVER_ROLE_MAC
	}
	return key.Role
}
func KeyForRole(set *pb.ApproverKeySet, id string, role pb.ApproverRole) ([]byte, error) {
	for _, key := range set.GetKeys() {
		if key.KeyId == id {
			if Role(set, key) != role {
				return nil, errors.New("Signer does not have the required approver role.")
			}
			return key.PublicKey, nil
		}
	}
	return nil, errors.New("The delivery was signed by an unknown approver. No value was opened.")
}
func HumanKey(set *pb.ApproverKeySet, id string) ([]byte, error) {
	for _, key := range set.GetKeys() {
		if key.KeyId == id {
			role := Role(set, key)
			if role == pb.ApproverRole_APPROVER_ROLE_MAC || role == pb.ApproverRole_APPROVER_ROLE_PHONE {
				return key.PublicKey, nil
			}
		}
	}
	return nil, errors.New("Human decisions require a current Mac or phone approver.")
}
func ValidateRoles(set *pb.ApproverKeySet, legacyOwner string) error {
	for _, key := range set.GetKeys() {
		if len(key.EncryptionPublicKey) > 0 {
			if Role(set, key) != pb.ApproverRole_APPROVER_ROLE_PHONE {
				return errors.New("Only phone approvers have copy encryption keys.")
			}
			if _, err := PublicKey(key.EncryptionPublicKey); err != nil {
				return err
			}
		}
		if key.Role == pb.ApproverRole_APPROVER_ROLE_UNSPECIFIED && (key.KeyId != legacyOwner || key.KeyId != set.RuleOwnerKeyId) {
			return errors.New("New approver keys require an explicit role.")
		}
		switch Role(set, key) {
		case pb.ApproverRole_APPROVER_ROLE_MAC, pb.ApproverRole_APPROVER_ROLE_PHONE:
			continue
		case pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY:
			if len(key.TlsPublicKey) != 0 {
				return errors.New("Delivery keys have no TLS identity.")
			}
		default:
			return errors.New("Unknown approver role.")
		}
	}
	_, err := KeyForRole(set, set.RuleOwnerKeyId, pb.ApproverRole_APPROVER_ROLE_MAC)
	return err
}

// VerifyPhoneDelivery checks both exact signed byte strings and all consent
// fields. Scope, current policy, request lifetime and ciphertext are checked by
// the caller against its retained request. Denial history has no approval TTL.
func VerifyPhoneDelivery(set *pb.ApproverKeySet, signed *pb.SignedDecision, statement *pb.DecisionStatement) error {
	if signed == nil || signed.PhoneDecision == nil || statement.Authority != pb.DecisionAuthority_DECISION_AUTHORITY_PHONE || statement.ConfigurationRevision != 0 {
		return errors.New("Missing phone consent.")
	}
	deliveryKey, err := KeyForRole(set, signed.ApproverKeyId, pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY)
	if err != nil {
		return err
	}
	if err = Verify(deliveryKey, signed.Statement, signed.Signature); err != nil {
		return err
	}
	phone := signed.PhoneDecision
	phoneKey, err := KeyForRole(set, phone.PhoneKeyId, pb.ApproverRole_APPROVER_ROLE_PHONE)
	if err != nil {
		return err
	}
	if err = Verify(phoneKey, phone.Decision, phone.Signature); err != nil {
		return err
	}
	decision := new(pb.PhoneDecision)
	if proto.Unmarshal(phone.Decision, decision) != nil || decision.Domain != "agentkeyring.phonedecision.v1" || !bytes.Equal(decision.RequestDigest, statement.RequestDigest) || decision.LeaseId != statement.LeaseId || decision.Choice != statement.Choice || decision.DecidedUnixSeconds != statement.ApprovedAtUnixSeconds || decision.NotAfterUnixSeconds != statement.NotAfterUnixSeconds || !bytes.Equal(decision.ReplySha256, statement.ReplySha256) || phone.Reply != signed.Reply || !bytes.Equal(decision.ReplySha256, Hash([]byte(phone.Reply))) {
		return errors.New("Phone consent does not match the delivered decision.")
	}
	if decision.Choice == pb.DecisionChoice_DECISION_CHOICE_APPROVE {
		if decision.DecidedUnixSeconds <= 0 || decision.NotAfterUnixSeconds <= decision.DecidedUnixSeconds || decision.NotAfterUnixSeconds > decision.DecidedUnixSeconds+1800 {
			return errors.New("Invalid phone approval lifetime.")
		}
	} else if decision.Choice != pb.DecisionChoice_DECISION_CHOICE_DENY || decision.NotAfterUnixSeconds != 0 {
		return errors.New("Invalid phone decision choice or deadline.")
	}
	return nil
}
