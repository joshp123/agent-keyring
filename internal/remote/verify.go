// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package remote

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/hpke"
	"encoding/hex"
	"errors"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func keySet(signed *pb.SignedApproverKeySet) (*pb.ApproverKeySet, error) {
	set := new(pb.ApproverKeySet)
	if signed == nil || proto.Unmarshal(signed.KeySet, set) != nil || set.Domain != "agentkeyring.approvers.v1" || set.Revision == 0 {
		return nil, errors.New("The approver key set is invalid.")
	}
	seen := map[string]bool{}
	for _, key := range set.Keys {
		if key.KeyId == "" || seen[key.KeyId] {
			return nil, errors.New("The approver key set repeats a key identity.")
		}
		seen[key.KeyId] = true
		if _, err := relaycrypto.PublicKey(key.PublicKey); err != nil {
			return nil, err
		}
	}
	if !seen[set.RuleOwnerKeyId] {
		return nil, errors.New("The approver key set has no rule owner.")
	}
	if err := relaycrypto.ValidateRoles(set, set.RuleOwnerKeyId); err != nil {
		return nil, err
	}
	return set, nil
}
func advanceKeys(state *clientstate.State, chain *pb.ApproverKeyChain) error {
	current, err := keySet(state.Approvers)
	if err != nil {
		return err
	}
	for _, signed := range chain.GetKeySets() {
		next, err := keySet(signed)
		if err != nil {
			return err
		}
		if next.Revision <= current.Revision {
			return errors.New("The relay returned an older or repeated approver key set.")
		}
		public, err := relaycrypto.KeyForRole(current, signed.SignerKeyId, pb.ApproverRole_APPROVER_ROLE_MAC)
		if err != nil {
			return err
		}
		if relaycrypto.Verify(public, signed.KeySet, signed.Signature) != nil {
			return errors.New("The approver key chain has an invalid signature.")
		}
		if err := relaycrypto.ValidateRoles(next, current.RuleOwnerKeyId); err != nil {
			return err
		}
		state.Approvers = proto.Clone(signed).(*pb.SignedApproverKeySet)
		current = next
	}
	return nil
}
func verifyConfiguration(state *clientstate.State, signed *pb.SignedConfiguration) (*pb.Configuration, error) {
	set, err := keySet(state.Approvers)
	if err != nil {
		return nil, err
	}
	if signed == nil || signed.ApproverKeyId != set.RuleOwnerKeyId {
		return nil, errors.New("The configuration is not signed by the current rule owner.")
	}
	key, err := relaycrypto.KeyForRole(set, signed.ApproverKeyId, pb.ApproverRole_APPROVER_ROLE_MAC)
	if err != nil {
		return nil, err
	}
	if relaycrypto.Verify(key, signed.Configuration, signed.Signature) != nil {
		return nil, errors.New("The configuration's signature is invalid.")
	}
	configuration := new(pb.Configuration)
	if proto.Unmarshal(signed.Configuration, configuration) != nil || configuration.Domain != "agentkeyring.configuration.v1" || configuration.Revision == 0 {
		return nil, errors.New("The signed configuration is invalid.")
	}
	if state.Configuration != nil {
		previous := new(pb.Configuration)
		if proto.Unmarshal(state.Configuration.Configuration, previous) != nil {
			return nil, errors.New("The saved configuration is invalid.")
		}
		if configuration.Revision < previous.Revision {
			return nil, errors.New("The relay returned an older configuration.")
		}
		if configuration.Revision == previous.Revision && (!bytes.Equal(signed.Configuration, state.Configuration.Configuration) || signed.ApproverKeyId != state.Configuration.ApproverKeyId) {
			return nil, errors.New("The relay changed the configuration without advancing its revision.")
		}
	}
	return configuration, nil
}
func machine(configuration *pb.Configuration, recipient string) *pb.EnrolledMachine {
	for _, enrolled := range configuration.Machines {
		if enrolled.RecipientId == recipient {
			return enrolled
		}
	}
	return nil
}
func automaticLogin(configuration *pb.Configuration, loginID string) bool {
	for _, login := range configuration.Logins {
		if login.LoginId == loginID {
			return login.Rule == pb.AccessRule_ACCESS_RULE_AUTOMATIC
		}
	}
	return false
}
func expected(state *clientstate.State, lease string) (*pb.RequestLeaseRequest, error) {
	for _, saved := range state.Requests {
		if saved.LeaseId == lease && lease != "" {
			return saved.Scope, nil
		}
	}
	return nil, errors.New("This machine has no saved request for that lease. Rejoin the original request on the machine that made it.")
}
func scopeMatches(request *pb.RequestLeaseRequest, record *pb.RequestRecord) bool {
	return request.LoginId == record.LoginId && request.TaskRef == record.TaskRef && request.Purpose == record.Purpose && request.Reason == record.Reason && request.RecipientId == record.RecipientId && proto.Equal(request.Program, record.Program)
}
func (c *Client) open(ctx context.Context, lease string, delivery *pb.SealedDelivery) (*pb.BundleContents, error) {
	if delivery == nil || delivery.Decision == nil || delivery.Bundle == nil {
		return nil, errors.New("The relay did not return a sealed delivery.")
	}
	if err := c.refreshKeys(ctx); err != nil {
		return nil, err
	}
	statement := new(pb.DecisionStatement)
	if proto.Unmarshal(delivery.Decision.Statement, statement) != nil || statement.Domain != "agentkeyring.decision.v1" {
		return nil, errors.New("The delivery has an invalid decision statement.")
	}
	if statement.Authority == pb.DecisionAuthority_DECISION_AUTHORITY_AUTOMATIC_RULE {
		if err := c.refreshConfiguration(ctx); err != nil {
			return nil, err
		}
	}
	state, err := c.Store.Load(ctx)
	if err != nil {
		return nil, err
	}
	request, err := expected(state, lease)
	if err != nil {
		return nil, err
	}
	record := new(pb.RequestRecord)
	if proto.Unmarshal(delivery.RequestRecord, record) != nil {
		return nil, errors.New("The delivery's approved request is unreadable.")
	}
	if record.LeaseId != lease || statement.LeaseId != lease {
		return nil, errors.New("The delivery belongs to a different lease. No value was opened.")
	}
	if statement.RecipientId != state.RecipientId || record.RecipientId != state.RecipientId {
		return nil, errors.New("The delivery belongs to a different recipient. No value was opened.")
	}
	if statement.ReceiverKeyId != state.ReceiverKeyId || delivery.Bundle.ReceiverKeyId != state.ReceiverKeyId {
		return nil, errors.New("The delivery was sealed to a different receiver key.")
	}
	if !scopeMatches(request, record) {
		return nil, errors.New("The approved request does not match this machine's saved login, task or program. No value was opened.")
	}
	if !bytes.Equal(statement.RequestDigest, relaycrypto.Digest("agentkeyring.request.v1", delivery.RequestRecord)) {
		return nil, errors.New("The approved request was changed after signing.")
	}
	set, err := keySet(state.Approvers)
	if err != nil {
		return nil, err
	}
	var key []byte
	switch statement.Authority {
	case pb.DecisionAuthority_DECISION_AUTHORITY_HUMAN:
		if statement.ConfigurationRevision != 0 {
			return nil, errors.New("A human decision incorrectly names a configuration revision.")
		}
		key, err = relaycrypto.KeyForRole(set, delivery.Decision.ApproverKeyId, pb.ApproverRole_APPROVER_ROLE_MAC)
	case pb.DecisionAuthority_DECISION_AUTHORITY_PHONE:
		if err = relaycrypto.VerifyPhoneDelivery(set, delivery.Decision, statement); err != nil {
			return nil, err
		}
		if statement.ApprovedAtUnixSeconds < record.CreatedUnixSeconds || statement.ApprovedAtUnixSeconds >= record.PendingUntilUnixSeconds {
			return nil, errors.New("Phone decision was outside this request's pending lifetime.")
		}
		key, err = relaycrypto.KeyForRole(set, delivery.Decision.ApproverKeyId, pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY)
	case pb.DecisionAuthority_DECISION_AUTHORITY_AUTOMATIC_RULE:
		var configuration *pb.Configuration
		configuration, err = verifyConfiguration(state, state.Configuration)
		if err == nil {
			enrolled := machine(configuration, state.RecipientId)
			if statement.ConfigurationRevision == 0 || configuration.Revision < statement.ConfigurationRevision || !record.Automatic || configuration.AutomaticKeyId != delivery.Decision.ApproverKeyId || !automaticLogin(configuration, record.LoginId) || enrolled == nil || !enrolled.AutomaticAllowed || enrolled.ReceiverKeyId != state.ReceiverKeyId {
				return nil, errors.New("The current configuration does not allow this Automatic login for this machine.")
			}
			key = configuration.AutomaticSigningPublicKey
		}

	default:
		return nil, errors.New("The delivery has no recognised approval authority.")
	}
	if err != nil {
		return nil, err
	}
	if relaycrypto.Verify(key, delivery.Decision.Statement, delivery.Decision.Signature) != nil {
		return nil, errors.New("The delivery's signature is invalid. No value was opened.")
	}
	if !bytes.Equal(statement.ReplySha256, relaycrypto.Hash([]byte(delivery.Decision.Reply))) {
		return nil, errors.New("The signed approval reply was changed.")
	}
	if statement.Choice != pb.DecisionChoice_DECISION_CHOICE_APPROVE {
		return nil, errors.New("This request was not approved.")
	}
	now := time.Now().Unix()
	if statement.NotAfterUnixSeconds <= now {
		return nil, errors.New("The signed delivery deadline has expired. Request a new lease if the task still needs it.")
	}
	if statement.ApprovedAtUnixSeconds > now || statement.ApprovedAtUnixSeconds <= 0 || statement.NotAfterUnixSeconds <= statement.ApprovedAtUnixSeconds || statement.NotAfterUnixSeconds-statement.ApprovedAtUnixSeconds > 1800 {
		return nil, errors.New("The delivery's signed deadline is invalid; approval lasts at most 30 minutes.")
	}
	if !bytes.Equal(statement.BundleCiphertextSha256, relaycrypto.Hash(delivery.Bundle.Ciphertext)) {
		return nil, errors.New("The sealed ciphertext was changed after approval. No value was opened.")
	}
	receiver, err := ecdh.P256().NewPrivateKey(c.Keys.ReceiverPrivateKey)
	if err != nil {
		return nil, err
	}
	if hex.EncodeToString(relaycrypto.Hash(receiver.PublicKey().Bytes())) != state.ReceiverKeyId {
		return nil, errors.New("The saved receiver key does not match this enrolment.")
	}
	private, err := hpke.NewDHKEMPrivateKey(receiver)
	if err != nil {
		return nil, err
	}
	opener, err := hpke.NewRecipient(delivery.Bundle.EncapsulatedKey, private, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte("agentkeyring.bundle.v1"))
	if err != nil {
		return nil, errors.New("The sealed delivery has an invalid encapsulated key.")
	}
	plaintext, err := opener.Open(statement.RequestDigest, delivery.Bundle.Ciphertext)
	if err != nil {
		return nil, errors.New("Cannot open this sealed delivery. Its ciphertext, recipient key or approved request does not match.")
	}
	defer clear(plaintext)
	bundle := new(pb.BundleContents)
	if proto.Unmarshal(plaintext, bundle) != nil {
		return nil, errors.New("The opened delivery is unreadable.")
	}
	if bundle.LeaseId != lease || bundle.LoginId != request.LoginId || bundle.NotAfterUnixSeconds != statement.NotAfterUnixSeconds {
		clearBundle(bundle)
		return nil, errors.New("The opened login does not match the signed lease or deadline.")
	}
	for _, code := range bundle.OneTimeCodes {
		if code.ValidFromUnixSeconds >= code.ValidUntilUnixSeconds || code.ValidUntilUnixSeconds > bundle.NotAfterUnixSeconds {
			clearBundle(bundle)
			return nil, errors.New("The opened delivery contains a code outside its approved deadline.")
		}
	}
	return bundle, nil
}
func clearBundle(bundle *pb.BundleContents) {
	bundle.Username = ""
	bundle.Password = ""
	for _, code := range bundle.OneTimeCodes {
		code.Code = ""
	}
}
func (c *Client) OpenValues(ctx context.Context, lease *pb.Lease, response *pb.Delivery) (*pb.CredentialValues, []string, error) {
	bundle, err := c.open(ctx, lease.LeaseId, response.GetSealed())
	if err != nil {
		return nil, nil, err
	}
	defer clearBundle(bundle)
	values := &pb.CredentialValues{Username: bundle.Username, Password: bundle.Password}
	now := time.Now().Unix()
	for _, code := range bundle.OneTimeCodes {
		if code.ValidFromUnixSeconds <= now && now < code.ValidUntilUnixSeconds {
			if values.OneTimeCode != "" {
				return nil, nil, errors.New("The delivery contains overlapping one-time codes.")
			}
			values.OneTimeCode = code.Code
		}
	}
	return values, bundle.Sites, nil
}

// An invalid or missing denial signature grants nothing and shows no reply.
func denialReply(state *clientstate.State, lease *pb.Lease) string {
	delivery := lease.SignedDenial
	if lease.State != pb.LeaseState_LEASE_STATE_DENIED || delivery == nil || delivery.Decision == nil || delivery.Bundle != nil {
		return ""
	}
	signed := delivery.Decision
	if signed.Bundle != nil {
		return ""
	}
	statement := new(pb.DecisionStatement)
	record := new(pb.RequestRecord)
	if proto.Unmarshal(signed.Statement, statement) != nil || proto.Unmarshal(delivery.RequestRecord, record) != nil {
		return ""
	}
	scope, err := expected(state, lease.LeaseId)
	if err != nil {
		return ""
	}
	if statement.Domain != "agentkeyring.decision.v1" || statement.Choice != pb.DecisionChoice_DECISION_CHOICE_DENY || (statement.Authority != pb.DecisionAuthority_DECISION_AUTHORITY_HUMAN && statement.Authority != pb.DecisionAuthority_DECISION_AUTHORITY_PHONE) || statement.ConfigurationRevision != 0 || len(statement.BundleCiphertextSha256) != 0 {
		return ""
	}
	if statement.LeaseId != lease.LeaseId || record.LeaseId != lease.LeaseId || statement.RecipientId != state.RecipientId || statement.ReceiverKeyId != state.ReceiverKeyId || !scopeMatches(scope, record) {
		return ""
	}
	if !bytes.Equal(statement.RequestDigest, relaycrypto.Digest("agentkeyring.request.v1", delivery.RequestRecord)) || !bytes.Equal(statement.ReplySha256, relaycrypto.Hash([]byte(signed.Reply))) {
		return ""
	}
	set, err := keySet(state.Approvers)
	if err != nil {
		return ""
	}
	var key []byte
	if statement.Authority == pb.DecisionAuthority_DECISION_AUTHORITY_PHONE {
		if relaycrypto.VerifyPhoneDelivery(set, signed, statement) != nil || statement.ApprovedAtUnixSeconds < record.CreatedUnixSeconds || statement.ApprovedAtUnixSeconds >= record.PendingUntilUnixSeconds {
			return ""
		}
		key, err = relaycrypto.KeyForRole(set, signed.ApproverKeyId, pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY)
	} else {
		key, err = relaycrypto.KeyForRole(set, signed.ApproverKeyId, pb.ApproverRole_APPROVER_ROLE_MAC)
	}
	if err != nil {
		return ""
	}
	if relaycrypto.Verify(key, signed.Statement, signed.Signature) != nil {
		return ""
	}
	return signed.Reply
}
