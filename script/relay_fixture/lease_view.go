// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package main

import (
	"crypto/tls"
	"fmt"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"google.golang.org/protobuf/proto"
)

func (p *proof) watchWork() *tls.Conn {
	return p.approver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: p.key.KeyId}}})
}
func nextLease(conn *tls.Conn, id string, state pb.LeaseState) *pb.Lease {
	for {
		lease := good(receive(conn)).GetWork().GetLease()
		if lease != nil && lease.LeaseId == id {
			require(lease.State == state, "approver saw unexpected lease state: "+lease.State.String())
			return lease
		}
	}
}
func revokeLeaseRequest(id string) *pb.RelayWireRequest {
	return &pb.RelayWireRequest{Request: &pb.RelayWireRequest_RevokeLease{RevokeLease: &pb.LeaseReference{LeaseId: id}}}
}

func (p *proof) approverLeaseProof() {
	active := good(p.client.call(leaseRequest("view-active", "view-active-task", p.enrolled.RecipientId))).GetClient().GetLease()
	approval := p.decision(p.nextRequest(), false)
	require(good(p.approver.call(approval)).GetDecision().Accepted, "view lease approval failed")
	require(good(p.client.call(deliverRequest(active.LeaseId, "before-revocation"))).GetClient().GetDelivery().GetSealed() != nil, "active view lease could not begin")
	pending := good(p.client.call(leaseRequest("view-pending", "view-pending-task", p.enrolled.RecipientId))).GetClient().GetLease()
	lateApproval := p.decision(p.nextRequest(), false)
	view := p.watchWork()
	nextLease(view, active.LeaseId, pb.LeaseState_LEASE_STATE_ACTIVE)
	nextLease(view, pending.LeaseId, pb.LeaseState_LEASE_STATE_PENDING)
	require(p.client.call(revokeLeaseRequest(active.LeaseId)).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "receiver could revoke a lease")
	require(p.client.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: p.key.KeyId}}}).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "receiver could watch approver leases")
	revokedActive := good(p.approver.call(revokeLeaseRequest(active.LeaseId))).GetLease()
	require(revokedActive.State == pb.LeaseState_LEASE_STATE_REVOKED && revokedActive.EndedAtUnixSeconds > 0, "active revocation failed")
	nextLease(view, active.LeaseId, pb.LeaseState_LEASE_STATE_REVOKED)
	require(proto.Equal(revokedActive, good(p.approver.call(revokeLeaseRequest(active.LeaseId))).GetLease()), "repeated revocation changed the lease")
	replayed := good(p.approver.call(approval)).GetDecision()
	require(replayed.Accepted && replayed.Lease.State == pb.LeaseState_LEASE_STATE_REVOKED, "accepted approval replay reactivated a revoked lease")
	require(p.client.call(deliverRequest(active.LeaseId, "after-revocation")).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "revoked lease delivered again")
	revokedPending := good(p.approver.call(revokeLeaseRequest(pending.LeaseId))).GetLease()
	require(revokedPending.State == pb.LeaseState_LEASE_STATE_REVOKED, "pending revocation failed")
	nextLease(view, pending.LeaseId, pb.LeaseState_LEASE_STATE_REVOKED)
	late := good(p.approver.call(lateApproval)).GetDecision()
	require(!late.Accepted && late.Lease.State == pb.LeaseState_LEASE_STATE_REVOKED, "late approval reactivated a revoked pending lease")
	view.Close()
	p.work.Close()
	p.stop()
	p.start()
	p.work = p.watchWork()
	require(proto.Equal(revokedActive, good(p.approver.call(revokeLeaseRequest(active.LeaseId))).GetLease()), "restart lost active revocation")
	require(proto.Equal(revokedPending, good(p.approver.call(revokeLeaseRequest(pending.LeaseId))).GetLease()), "restart lost pending revocation")
	late = good(p.approver.call(lateApproval)).GetDecision()
	require(!late.Accepted && late.Lease.State == pb.LeaseState_LEASE_STATE_REVOKED, "restart allowed a late approval")
	require(p.client.call(deliverRequest(pending.LeaseId, "late-delivery")).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "revoked pending lease delivered after restart")
	fresh := good(p.client.call(leaseRequest("view-fresh", "view-fresh-task", p.enrolled.RecipientId))).GetClient().GetLease()
	record := p.nextRequest()
	view = p.watchWork()
	for {
		lease := good(receive(view)).GetWork().GetLease()
		if lease != nil {
			require(lease.LeaseId == fresh.LeaseId && lease.State == pb.LeaseState_LEASE_STATE_PENDING, "reconnected backlog included terminal history")
			break
		}
	}
	require(good(p.approver.call(p.decision(record, false))).GetDecision().Accepted, "fresh view lease approval failed")
	nextLease(view, fresh.LeaseId, pb.LeaseState_LEASE_STATE_ACTIVE)
	released := good(p.client.call(endRequest(fresh.LeaseId))).GetClient().GetLease()
	nextLease(view, fresh.LeaseId, pb.LeaseState_LEASE_STATE_RELEASED)
	require(proto.Equal(released, good(p.approver.call(revokeLeaseRequest(fresh.LeaseId))).GetLease()), "revocation changed a released lease")
	view.Close()
	fmt.Println("PASS approver pending/active backlog, updates and reconnect; durable idempotent revocation prevents late/replayed approvals and delivery")
}
