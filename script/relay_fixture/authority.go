// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package main

import (
	"crypto/ecdsa"
	"fmt"
	"path/filepath"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func (p *proof) grant(key *ecdsa.PrivateKey, revision uint64, recipients []string) {
	data := encoded(&pb.AutomaticGrant{Domain: "agentkeyring.automatic.v1", Revision: revision, AutomaticSigningPublicKey: public(key), AutomaticKeyId: "fixture-automatic", LoginIds: []string{"fixture-login"}, RecipientIds: recipients})
	require(good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishAutomaticGrant{PublishAutomaticGrant: &pb.SignedAutomaticGrant{Grant: data, Signature: sign(p.signer, data), ApproverKeyId: p.key.KeyId}}})).GetPublish().Accepted, "Automatic grant refused")
}
func (p *proof) automaticDecision(record []byte, key *ecdsa.PrivateKey, revision uint64) *pb.RelayWireRequest {
	decision := p.decision(record, false)
	statement := new(pb.DecisionStatement)
	must(proto.Unmarshal(decision.GetDecide().Statement, statement))
	statement.Authority = pb.DecisionAuthority_DECISION_AUTHORITY_AUTOMATIC_RULE
	statement.AutomaticGrantRevision = revision
	decision.GetDecide().Statement = encoded(statement)
	decision.GetDecide().ApproverKeyId = "fixture-automatic"
	decision.GetDecide().Signature = sign(key, decision.GetDecide().Statement)
	return decision
}
func (p *proof) delegationProof() {
	automatic := signingKey()
	firstClient := p.client
	keys := new(pb.ApproverKeySet)
	must(proto.Unmarshal(p.keys.KeySet, keys))
	keys.Revision++
	keys.Keys = append(keys.Keys, &pb.ApproverKey{KeyId: "fixture-automatic", PublicKey: public(automatic), Role: pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY})
	raw := encoded(keys)
	p.keys = &pb.SignedApproverKeySet{KeySet: raw, Signature: sign(p.signer, raw), SignerKeyId: p.key.KeyId}
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: p.keys}}))
	p.publishIndex(pb.AccessRule_ACCESS_RULE_AUTOMATIC)
	p.grant(automatic, 1, []string{p.enrolled.RecipientId})
	refused := good(p.client.call(leaseRequest("auto-refused", "task-auto-refused", p.enrolled.RecipientId))).GetClient().GetLease()
	require(p.approver.call(p.automaticDecision(p.nextRequest(), automatic, 1)).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "Automatic grant bypassed machine default-off permission")
	good(p.client.call(endRequest(refused.LeaseId)))
	p.client = wireClient{address: p.address, certificate: identity(filepath.Join(p.directory, "automatic-receiver")), pin: p.approver.pin}
	p.enrol(true)
	p.grant(automatic, 2, []string{p.enrolled.RecipientId})
	lease := good(p.client.call(leaseRequest("auto-approved", "task-auto-approved", p.enrolled.RecipientId))).GetClient().GetLease()
	decision := p.automaticDecision(p.nextRequest(), automatic, 2)
	require(good(p.approver.call(decision)).GetDecision().Accepted, "valid Automatic decision refused")
	require(good(p.client.call(beginRequest(lease.LeaseId, "auto-operation"))).GetClient().GetBeginOperation().GetSealed() != nil, "Automatic lease did not deliver")
	require(firstClient.call(beginRequest(lease.LeaseId, "wrong-recipient")).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "different enrolled machine used lease")
	p.grant(automatic, 3, nil)
	require(p.client.call(beginRequest(lease.LeaseId, "after-grant-change")).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "changed Automatic grant did not revoke lease")
	p.publishIndex(pb.AccessRule_ACCESS_RULE_ASK)
	fmt.Println("PASS", "Automatic grant scope, machine opt-in, wrong recipient and grant revocation")
	// Publish the current full signed roster and intentionally omit the first
	// machine. A stale enrolment approval must never reactivate it.
	rosterBytes := encoded(&pb.EnrolmentSet{Domain: "agentkeyring.enrolments.v1", Revision: 1, Machines: []*pb.EnrolledMachine{{RecipientId: p.enrolled.RecipientId, MachineLabel: p.enrolled.MachineLabel, ClientLabel: p.enrolled.ClientLabel, TailscaleNodeId: p.enrolled.TailscaleNodeId, TlsPublicKey: p.enrolled.TlsPublicKey, ReceiverPublicKey: p.enrolled.ReceiverPublicKey, ReceiverKeyId: p.enrolled.ReceiverKeyId, AutomaticAllowed: true}}})
	roster := &pb.SignedEnrolmentSet{EnrolmentSet: rosterBytes, Signature: sign(p.signer, rosterBytes), ApproverKeyId: p.key.KeyId}
	require(good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishEnrolmentSet{PublishEnrolmentSet: roster}})).GetPublish().Accepted, "signed roster refused")
	require(firstClient.call(find()).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "omission from roster did not revoke machine")
	nextClient := wireClient{address: p.address, certificate: identity(filepath.Join(p.directory, "second-approver")), pin: p.approver.pin}
	spki, err := relaycrypto.CertificateSPKI(nextClient.certificate)
	must(err)
	nextSigner := signingKey()
	nextKey := &pb.ApproverKey{KeyId: "fixture-second-approver", Label: "Fixture second approver", Role: pb.ApproverRole_APPROVER_ROLE_MAC, TlsPublicKey: spki, PublicKey: public(nextSigner)}
	pending := nextClient.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PairApprover{PairApprover: &pb.PairApproverRequest{Key: nextKey, TlsPublicKey: spki}}})
	defer pending.Close()
	require(good(receive(pending)).GetEnrolStatus().State == pb.EnrolState_ENROL_STATE_PENDING, "added approver activated without confirmation")
	nextBytes := encoded(&pb.ApproverKeySet{Domain: "agentkeyring.approvers.v1", Revision: 3, Keys: []*pb.ApproverKey{p.key, nextKey, keys.Keys[1]}, RuleOwnerKeyId: p.key.KeyId, EnrolmentSetRevision: 1, EnrolmentSetSha256: relaycrypto.Hash(rosterBytes), PairingTranscriptSha256: relaycrypto.Hash(relaycrypto.PairTranscript(p.approver.pin, spki, nextKey.PublicKey, p.keys.KeySet))})
	next := &pb.SignedApproverKeySet{KeySet: nextBytes, Signature: sign(p.signer, nextBytes), SignerKeyId: p.key.KeyId}
	require(good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: next}})).GetPublish().Accepted, "added signed approver set refused")
	require(good(receive(pending)).GetEnrolStatus().State == pb.EnrolState_ENROL_STATE_APPROVED, "pairing stream missed signed key update")
	chainKeys := good(p.client.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetApproverKeyChain{GetApproverKeyChain: &pb.GetApproverKeyChainRequest{FromRevision: 2}}})).GetApproverKeyChain().KeySets
	require(len(chainKeys) == 1 && proto.Equal(chainKeys[0], next), "offline receiver could not fetch exact key chain")
	must(relaycrypto.Verify(p.key.PublicKey, chainKeys[0].KeySet, chainKeys[0].Signature))
	require(good(nextClient.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetIndex{GetIndex: &pb.GetIndexRequest{}}})).GetIndex() != nil, "new pinned approver cannot fetch index")
	p.keys = next
	fmt.Println("PASS", "signed roster revocation, second approver pairing and offline receiver key chain")
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
	require(p.client.call(beginRequest(fresh.LeaseId, "before-approval")).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "clear granted access")
	require(good(p.approver.call(p.decision(p.nextRequest(), false))).GetDecision().Accepted, "fresh request could not be approved")
	require(good(p.client.call(beginRequest(fresh.LeaseId, "after-approval"))).GetClient().GetBeginOperation().GetSealed() != nil, "new approval did not permit begin")
	good(p.client.call(endRequest(fresh.LeaseId)))
	p.publishIndex(pb.AccessRule_ACCESS_RULE_BLOCKED)
	good(p.approver.call(clear))
	require(good(p.client.call(leaseRequest("blocked-after-clear", "blocked-after-clear-task", p.enrolled.RecipientId))).GetClient().GetLease().State == pb.LeaseState_LEASE_STATE_DENIED, "clear bypassed Blocked policy")
	fmt.Println("PASS approver-only ClearDenial, scoped and idempotent, durable across restart; fresh request needs approval")
}
