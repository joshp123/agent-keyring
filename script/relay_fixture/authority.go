// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package main

import (
	"crypto/ecdsa"
	"fmt"
	"path/filepath"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func (p *proof) automaticDecision(record []byte, key *ecdsa.PrivateKey, revision uint64) *pb.RelayWireRequest {
	decision := p.decision(record, false)
	statement := new(pb.DecisionStatement)
	must(proto.Unmarshal(decision.GetDecide().Statement, statement))
	statement.Authority = pb.DecisionAuthority_DECISION_AUTHORITY_AUTOMATIC_RULE
	statement.ConfigurationRevision = revision
	decision.GetDecide().Statement = encoded(statement)
	decision.GetDecide().ApproverKeyId = p.configuration.AutomaticKeyId
	decision.GetDecide().Signature = sign(key, decision.GetDecide().Statement)
	return decision
}
func (p *proof) delegationProof() {
	automatic, rotated := signingKey(), signingKey()
	firstClient := p.client
	keys := new(pb.ApproverKeySet)
	must(proto.Unmarshal(p.keys.KeySet, keys))
	keys.Revision++
	keys.Keys = append(keys.Keys, &pb.ApproverKey{KeyId: "fixture-automatic", PublicKey: public(automatic), Role: pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY}, &pb.ApproverKey{KeyId: "fixture-rotated", PublicKey: public(rotated), Role: pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY})
	raw := encoded(keys)
	p.keys = &pb.SignedApproverKeySet{KeySet: raw, Signature: sign(p.signer, raw), SignerKeyId: p.key.KeyId}
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: p.keys}}))
	p.configuration.AutomaticKeyId, p.configuration.AutomaticSigningPublicKey = "fixture-automatic", public(automatic)
	p.publishIndex(pb.AccessRule_ACCESS_RULE_AUTOMATIC)
	refused := good(p.client.call(leaseRequest("auto-refused", "task-auto-refused", p.enrolled.RecipientId))).GetClient().GetLease()
	require(p.approver.call(p.automaticDecision(p.nextRequest(), automatic, p.configuration.Revision)).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "Automatic bypassed machine default-off permission")
	good(p.client.call(endRequest(refused.LeaseId)))
	p.client = wireClient{address: p.address, certificate: identity(filepath.Join(p.directory, "automatic-receiver")), pin: p.approver.pin}
	p.enrol(true)
	human := good(p.client.call(leaseRequest("human-automatic-rule", "human-automatic-rule-task", p.enrolled.RecipientId))).GetClient().GetLease()
	good(p.approver.call(p.decision(p.nextRequest(), false)))
	activate := func(id string) (*pb.Lease, *pb.RelayWireRequest) {
		lease := good(p.client.call(leaseRequest(id, id, p.enrolled.RecipientId))).GetClient().GetLease()
		decision := p.automaticDecision(p.nextRequest(), automatic, p.configuration.Revision)
		require(good(p.approver.call(decision)).GetDecision().Accepted, "valid Automatic decision refused")
		return lease, decision
	}
	lease, decision := activate("auto-approved")
	p.configuration.MirrorRefreshedUnixSeconds = time.Now().Unix()
	p.publishConfiguration()
	require(good(p.client.call(deliverRequest(lease.LeaseId))).GetClient().GetDelivery().GetSealed() != nil, "unrelated configuration change revoked Automatic lease")
	require(good(p.approver.call(decision)).GetDecision().Accepted, "unrelated revision lost decision retry")
	require(firstClient.call(deliverRequest(lease.LeaseId)).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "different receiver used lease")
	p.configuration.Machines[len(p.configuration.Machines)-1].AutomaticAllowed = false
	p.publishConfiguration()
	require(p.client.call(deliverRequest(lease.LeaseId)).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "removed Automatic permission did not revoke lease")
	require(good(p.client.call(deliverRequest(human.LeaseId))).GetClient().GetDelivery().GetSealed() != nil, "Automatic permission change revoked HUMAN lease")
	p.configuration.Machines[len(p.configuration.Machines)-1].AutomaticAllowed = true
	p.publishConfiguration()
	lease, _ = activate("auto-key-rotation")
	p.configuration.AutomaticKeyId, p.configuration.AutomaticSigningPublicKey = "fixture-rotated", public(rotated)
	p.publishConfiguration()
	require(p.client.call(deliverRequest(lease.LeaseId)).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "retired Automatic key did not revoke lease")
	p.configuration.AutomaticKeyId, p.configuration.AutomaticSigningPublicKey = "fixture-automatic", public(automatic)
	p.publishConfiguration()
	lease, _ = activate("auto-rule-change")
	p.publishIndex(pb.AccessRule_ACCESS_RULE_ASK)
	require(p.client.call(deliverRequest(lease.LeaseId)).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "Automatic to Ask did not revoke Automatic lease")
	require(good(p.client.call(deliverRequest(human.LeaseId))).GetClient().GetDelivery().GetSealed() != nil, "Automatic to Ask revoked HUMAN lease")
	good(p.client.call(endRequest(human.LeaseId)))
	fmt.Println("PASS atomic configuration: unrelated revision preserves leases; permission, key and rule withdrawal revoke only affected leases")
	// Removing a machine in the same snapshot changes both authentication and leases.
	p.configuration.Machines = []*pb.EnrolledMachine{p.enrolledMachine(true)}
	p.publishConfiguration()
	require(firstClient.call(find()).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "configuration omission did not revoke machine")
	publication := &pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishConfiguration{PublishConfiguration: &pb.ConfigurationPublication{Configuration: p.signedConfiguration}}}
	good(p.approver.call(publication))
	altered := proto.Clone(publication).(*pb.RelayWireRequest)
	config := proto.Clone(p.configuration).(*pb.Configuration)
	config.MirrorRefreshedUnixSeconds++
	altered.GetPublishConfiguration().Configuration.Configuration = encoded(config)
	altered.GetPublishConfiguration().Configuration.Signature = sign(p.signer, encoded(config))
	require(p.approver.call(altered).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_CONFLICT, "same revision accepted different configuration")
	nextClient := wireClient{address: p.address, certificate: identity(filepath.Join(p.directory, "second-approver")), pin: p.approver.pin}
	spki, err := relaycrypto.CertificateSPKI(nextClient.certificate)
	must(err)
	nextSigner := signingKey()
	nextKey := &pb.ApproverKey{KeyId: "fixture-second-approver", Label: "Fixture second approver", Role: pb.ApproverRole_APPROVER_ROLE_MAC, TlsPublicKey: spki, PublicKey: public(nextSigner)}
	pending := nextClient.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PairApprover{PairApprover: &pb.PairApproverRequest{Key: nextKey, TlsPublicKey: spki}}})
	defer pending.Close()
	require(good(receive(pending)).GetEnrolStatus().State == pb.EnrolState_ENROL_STATE_PENDING, "added approver activated without confirmation")
	keys.Revision++
	keys.Keys = append(keys.Keys, nextKey)
	keys.ConfigurationRevision = p.configuration.Revision
	keys.ConfigurationSha256 = relaycrypto.Hash(p.signedConfiguration.Configuration)
	keys.PairingTranscriptSha256 = relaycrypto.Hash(relaycrypto.PairTranscript(p.approver.pin, spki, nextKey.PublicKey, p.keys.KeySet))
	nextBytes := encoded(keys)
	next := &pb.SignedApproverKeySet{KeySet: nextBytes, Signature: sign(p.signer, nextBytes), SignerKeyId: p.key.KeyId}
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: next}}))
	require(good(receive(pending)).GetEnrolStatus().State == pb.EnrolState_ENROL_STATE_APPROVED, "pair stream missed key update")
	chain := good(p.client.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetApproverKeyChain{GetApproverKeyChain: &pb.GetApproverKeyChainRequest{FromRevision: 2}}})).GetApproverKeyChain().KeySets
	require(len(chain) == 1 && proto.Equal(chain[0], next), "offline receiver lost exact key chain")
	require(good(nextClient.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetConfiguration{GetConfiguration: &pb.GetConfigurationRequest{}}})).GetConfiguration() != nil, "paired approver cannot fetch configuration")
	unauthorized := proto.Clone(publication).(*pb.RelayWireRequest)
	config.Revision++
	unauthorized.GetPublishConfiguration().Configuration = &pb.SignedConfiguration{Configuration: encoded(config), Signature: sign(nextSigner, encoded(config)), ApproverKeyId: nextKey.KeyId}
	require(nextClient.call(unauthorized).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "non-owner changed configuration")
	p.keys = next
	fmt.Println("PASS configuration resend, revision conflict, machine revocation, owner-only publication and configuration-bound second approver pairing")
}

func (p *proof) connectionDenialProof() {
	p.publishIndex(pb.AccessRule_ACCESS_RULE_ASK)
	p.client = wireClient{address: p.address, certificate: identity(filepath.Join(p.directory, "plain-deny-receiver")), pin: p.approver.pin}
	p.enrol()
	lease := good(p.client.call(leaseRequest("plain-deny", "plain-deny-task", p.enrolled.RecipientId))).GetClient().GetLease()
	record := p.nextRequest()
	denial := p.decision(record, true)
	statement := new(pb.DecisionStatement)
	must(proto.Unmarshal(denial.GetDecide().Statement, statement))
	statement.Authority = pb.DecisionAuthority_DECISION_AUTHORITY_APPROVER_CONNECTION
	statement.ReplySha256 = relaycrypto.Hash(nil)
	denial.GetDecide().Statement = encoded(statement)
	denial.GetDecide().Reply = ""
	denial.GetDecide().Signature = nil
	require(p.client.call(denial).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "receiver could issue connection-authority denial")
	forgedApproval := p.decision(record, false)
	forgedStatement := new(pb.DecisionStatement)
	must(proto.Unmarshal(forgedApproval.GetDecide().Statement, forgedStatement))
	forgedStatement.Authority = pb.DecisionAuthority_DECISION_AUTHORITY_APPROVER_CONNECTION
	forgedApproval.GetDecide().Statement = encoded(forgedStatement)
	forgedApproval.GetDecide().Signature = nil
	require(p.approver.call(forgedApproval).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "connection authority could approve")
	replyDenial := proto.Clone(denial).(*pb.RelayWireRequest)
	replyDenial.GetDecide().Reply = "Unsigned instruction"
	replyStatement := proto.Clone(statement).(*pb.DecisionStatement)
	replyStatement.ReplySha256 = relaycrypto.Hash([]byte(replyDenial.GetDecide().Reply))
	replyDenial.GetDecide().Statement = encoded(replyStatement)
	require(p.approver.call(replyDenial).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "connection authority could send reply")
	result := good(p.approver.call(denial)).GetDecision()
	require(result.Accepted && result.Lease.State == pb.LeaseState_LEASE_STATE_DENIED && result.Lease.LeaseId == lease.LeaseId && result.Lease.Reply == "" && result.Lease.SignedDenial == nil, "plain connection denial failed")
	require(good(p.approver.call(denial)).GetDecision().Accepted, "plain denial resend failed")
	suppressed := good(p.client.call(leaseRequest("plain-deny-next", "new-task", p.enrolled.RecipientId))).GetClient().GetLease()
	require(suppressed.State == pb.LeaseState_LEASE_STATE_DENIED && suppressed.RetryNotBeforeUnixSeconds > 0, "plain denial did not suppress")
	fmt.Println("PASS pinned-connection plain Deny; receiver, approval and unsigned reply refused")
	clear := &pb.RelayWireRequest{Request: &pb.RelayWireRequest_ClearDenial{ClearDenial: &pb.ClearDenialRequest{RecipientId: p.enrolled.RecipientId, LoginId: "fixture-login"}}}
	require(p.client.call(clear).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "receiver could clear denial")
	wrongScope := proto.Clone(clear).(*pb.RelayWireRequest)
	wrongScope.GetClearDenial().LoginId = "another-login"
	good(p.approver.call(wrongScope))
	require(good(p.client.call(leaseRequest("still-suppressed", "another-task", p.enrolled.RecipientId))).GetClient().GetLease().State == pb.LeaseState_LEASE_STATE_DENIED, "clear affected a different login")
	require(good(p.approver.call(clear)).GetPublish().Accepted, "clear denial refused")
	require(good(p.approver.call(clear)).GetPublish().Accepted, "repeated clear denial refused")
	p.work.Close()
	p.stop()
	p.start()
	p.work = p.approver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: p.key.KeyId}}})
	old := good(p.client.call(leaseRequest("plain-deny", "plain-deny-task", p.enrolled.RecipientId))).GetClient().GetLease()
	require(old.State == pb.LeaseState_LEASE_STATE_DENIED && old.RetryNotBeforeUnixSeconds == 0, "clear rewrote denial or restart lost clearance")
	fresh := good(p.client.call(leaseRequest("after-clear", "after-clear-task", p.enrolled.RecipientId))).GetClient().GetLease()
	require(fresh.State == pb.LeaseState_LEASE_STATE_PENDING, "fresh request could not ask after clear")
	require(p.client.call(deliverRequest(fresh.LeaseId, "before-approval")).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "clear granted access")
	require(good(p.approver.call(p.decision(p.nextRequest(), false))).GetDecision().Accepted, "fresh request could not be approved")
	require(good(p.client.call(deliverRequest(fresh.LeaseId, "after-approval"))).GetClient().GetDelivery().GetSealed() != nil, "new approval did not permit begin")
	good(p.client.call(endRequest(fresh.LeaseId)))
	p.publishIndex(pb.AccessRule_ACCESS_RULE_BLOCKED)
	good(p.approver.call(clear))
	require(good(p.client.call(leaseRequest("blocked-after-clear", "blocked-after-clear-task", p.enrolled.RecipientId))).GetClient().GetLease().State == pb.LeaseState_LEASE_STATE_DENIED, "clear bypassed Blocked policy")
	fmt.Println("PASS approver-only ClearDenial, scoped and idempotent, durable across restart; fresh request needs approval")
}
